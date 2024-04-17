// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPrismaVault} from "./interfaces/prisma/IPrismaVault.sol";
import {IStabilityPool} from "./interfaces/prisma/IStabilityPool.sol";
import {ICurvePool} from "./interfaces/curve/ICurvePool.sol";
import {ITroveManager} from "./interfaces/prisma/ITroveManager.sol";
import {IFactory} from "./interfaces/prisma/IFactory.sol";
import {OraclePricer} from "./OraclePricer.sol";
import {IAggregatorV3Interface} from "./interfaces/chainlink/IAggregatorV3Interface.sol";


contract Strategy is BaseStrategy, OraclePricer {
    using SafeERC20 for ERC20;

    uint constant MAX_BPS = 10_000;

    /// @notice Yearn's Prisma locker contract.
    address public constant YEARN_LOCKER = 0x90be6DFEa8C80c184C442a36e17cB2439AAE25a7;

    ICurvePool public constant yprismaPool = ICurvePool(0x69833361991ed76f9e8DBBcdf9ea1520fEbFb4a7); // 0 is PRISMA, 1 is yPRISMA

    ICurvePool public constant mkusdPool = ICurvePool(0x9D8108DDD8aD1Ee89d527C0C9e928Cb9D2BBa2d3); // 0 is mkUSD, 1 is PRISMA

    /// @notice The address of the yPrisma token. This is minted to us as an alternative to creating a lock.
    ERC20 public constant yPrisma = ERC20(0xe3668873D944E4A949DA05fc8bDE419eFF543882);
    ERC20 public constant PRISMA = ERC20(0xdA47862a83dac0c112BA89c6abC2159b95afd71C);

    IStabilityPool public immutable stabilityPool; // 0xed8B26D99834540C5013701bB3715faFD39993Ba
    
    IFactory public immutable factory; // 0x70b66E20766b775B2E9cE5B718bbD285Af59b7E1

    /// @notice Where we claim emissions as yPRISMA
    IPrismaVault public immutable prismaVault; // 0x06bDF212C290473dCACea9793890C5024c7Eb02c

    uint public dustThreshold = 100e18;

    uint16 public discount;

    /// @notice The percentage of yPRISMA from each harvest that we send to our voter (out of 10,000).
    uint16 public keepYPrisma = 1_000;

    uint16 public slippageTolerance0 = 200;

    uint16 public slippageTolerance1 = 200;

    uint public lastSyncIndex;

    address[] public collaterals;

    /// @notice Struct containing bools for forceClaimOnce and shouldClaimRewards. Determines if we allow claiming
    ///  rewards without max boost for one harvest, and/or if we should skip claiming rewards entirely.
    ClaimParams public claimParams;

    /// @notice List of unique collateral tokens
    ERC20[] public collateralTokens;

    /// @notice Determines whether collateral gains will be claimed during reports.
    bool public claimCollateralGains;

    /// @notice If true, will temporarily override requirement that all claims be max boosted.
    bool public forceClaimOnce;

    address immutable GOV;

    mapping(address collateral => ITroveManager troveManager) public troveManagers;

    struct ClaimParams {
        /// @notice We use this flag to signal a desire to claim even if Yearns locker cant provide max boost.
        bool forceClaimOnce;
        /// @notice Defaults to true, set to false to skip reward claiming altogether.
        bool shouldClaimRewards;
    }

    event CollateralSynced(address collateral);
    event CollateralSold(address indexed buyer, uint totalCost, uint[] collateralIndices);
    event DiscountSet(uint discount);
    event ParametersUpdated(uint slippageTolerance0, uint slippageTolerance1, uint keepYPrisma, uint dustThreshold);

    constructor(
        address _asset,
        string memory _name,
        address _factory,
        address _stabilityPool,
        address _prismaVault,
        address _priceFeed,
        uint _discount,
        address _gov
    ) BaseStrategy(_asset, _name) OraclePricer(_priceFeed) {
        stabilityPool = IStabilityPool(_stabilityPool);
        factory = IFactory(_factory);
        prismaVault = IPrismaVault(_prismaVault);
        syncCollaterals();
        require(_discount <= 500, "Discount too high");
        _setDiscount(_discount);
        GOV = _gov;

        yPrisma.approve(address(yprismaPool), type(uint256).max);
        PRISMA.approve(address(mkusdPool), type(uint256).max);
    }


    function _deployFunds(uint _amount) internal override {
        stabilityPool.provideToSP(_amount);
    }

    function _freeFunds(uint _amount) internal override {
        stabilityPool.withdrawFromSP(_amount);
    }

    function _harvestAndReport()
        internal
        override
        returns (uint _totalAssets)
    {
        if(!TokenizedStrategy.isShutdown()) {
            if (claimParams.shouldClaimRewards) {
                _claimRewards(claimParams.forceClaimOnce, YEARN_LOCKER, 10_000);
            }

            // deposit any loose funds
            uint looseAssets = ERC20(asset).balanceOf(address(this));
            if (looseAssets > 0) {
                _deployFunds(looseAssets);
            }
        }

        // get array of any collaterals our position has claimable.
        uint[] memory claimIndices = getClaimableIndices();

        
        if (claimIndices.length > 0){
            // If we have any collaterals to sell, pause PnL reporting.
            return TokenizedStrategy.totalAssets();
        }
        
        return estimatedTotalAssets();
    }

    /**
     * @notice Syncs collaterals with the Stability Pool
     * @dev Must be called to fetch the latest list of collaterals.
     */
    function syncCollaterals() public {
        uint length = factory.troveManagerCount();
        uint _lastSyncIndex = lastSyncIndex;
        if (_lastSyncIndex >= length) return;
        lastSyncIndex = length;
        uint collateralCount = collaterals.length;
        bool skip;
        for (uint i = _lastSyncIndex; i < length; i++) {
            address troveManager = factory.troveManagers(i);
            address collateral = ITroveManager(troveManager).collateralToken();
            for (uint x = 0; x < collateralCount; x++) {
                if (collaterals[x] == collateral) {
                    skip = true;
                    break;
                }
            }
            if (!skip) {
                collaterals.push(collateral);
                collateralCount++;
                emit CollateralSynced(collateral);
            }
            else {
                skip = false;
            }
        }
    }

    function estimatedTotalAssets() public view returns (uint) {
        // Does not account for pending collateral reward value
        return getAssetBalance() + stabilityPool.getCompoundedDebtDeposit(address(this));
    }

    function getAssetBalance() public view returns (uint) {
        return asset.balanceOf(address(this));
    }

    /**
        @notice Helper function to help discover which indexes can be claimed from.
    */
    function getClaimableIndices() public view returns (uint[] memory claimIndices) {
        uint claimCount;
        uint[] memory collateralGains = stabilityPool.getDepositorCollateralGain(address(this));
        uint collateralCount = collateralGains.length;
        claimIndices = new uint[](collateralCount);
        for (uint i = 0; i < collateralCount; i++) {
            if (collateralGains[i] > 0) {
                claimIndices[claimCount++] = i;
            }
        }
        assembly {
            mstore(claimIndices, claimCount) // Trim any excess array length.
        }
    }

    /**
        @notice Amount needed to purchase the specified collateral.
    */
    function getPriceForAvailableSellTokens(uint[] memory _collateralIndices) public view returns (uint) {
        uint collateralCount = collaterals.length;
        require(_collateralIndices.length <= collateralCount, "too many indices");
        uint prev;
        uint idx;
        uint totalPrice;
        uint[] memory collateralGains = stabilityPool.getDepositorCollateralGain(address(this));
        for (uint i=0; i < _collateralIndices.length; i++) {
            idx = _collateralIndices[i];
            require(i == 0 || idx > prev, "Unsorted Order");
            prev = idx;
            uint sellAmount = collateralGains[idx];
            if (sellAmount == 0) {
                continue;
            }
            uint oraclePrice = _fetchPrice(collaterals[_collateralIndices[i]]);
            totalPrice += (sellAmount * oraclePrice / 1e18);
        }
        return totalPrice * (MAX_BPS - discount) / MAX_BPS;
    }

    /**
        @notice Anybody can buy collaterals earned by strategy deposits.
        @dev Must buy full amount of specified collateral token(s).
    */
    function buyCollateral(uint[] memory _collateralIndices, uint _maxCost) external {
        syncCollaterals();
        uint cost = getPriceForAvailableSellTokens(_collateralIndices);
        require(cost <= _maxCost, "Cost too high");
        asset.transferFrom(msg.sender, address(this), cost);
        stabilityPool.provideToSP(cost); // Trigger collateral accrual
        stabilityPool.claimCollateralGains(msg.sender, _collateralIndices);
        emit CollateralSold(msg.sender, cost, _collateralIndices);
    }

    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint) {
        return estimatedTotalAssets(); // token balance + sp deposits.
    }

    function _emergencyWithdraw(uint _amount) internal override {
        // Pull full amount. Stability pool scales down to actual balance for us.
        _freeFunds(type(uint).max);
    }

    // @dev: to comply with standard interface for yearn strategies that farm Prisma
    function prismaReceiver() external view returns (address) {
        return address(stabilityPool);
    }

    function _claimRewards(
        bool _forceClaimOnce,
        address _boostDelegate,
        uint _maxFee
    ) internal returns (uint) {
        // By default, we only allow claims if max boosted. Force claim once if needed.
        if (claimsAreMaxBoosted() || _forceClaimOnce) {
            address[] memory rewardContracts = new address[](1);
            rewardContracts[0] = address(stabilityPool);
            
            prismaVault.batchClaimRewards(
                YEARN_LOCKER,       // receiver
                _boostDelegate,     // delegate
                rewardContracts,    // rewards contracts
                _maxFee             // maxFee
            );

            // reset if we forced this one
            if (_forceClaimOnce) {
                claimParams.forceClaimOnce = false;
            }

            return _sellRewards();
        }

        return 0;
    }

    function _sellRewards() internal returns (uint) {
        uint rewardBalance = yPrisma.balanceOf(address(this));
        if (rewardBalance < dustThreshold) {
            return 0;
        }
        uint _keepYPrisma = uint(keepYPrisma);
        if (_keepYPrisma > 0) {
            uint keep = _keepYPrisma * rewardBalance / MAX_BPS;
            rewardBalance = rewardBalance - keep;
            yPrisma.transfer(YEARN_LOCKER, keep);
        }

        uint price = yprismaPool.ema_price();
        uint amountOut = yprismaPool.exchange(
            int128(1), // yPRISMA idx
            int128(0), // PRISMA idx
            rewardBalance,
            0
            // rewardBalance * price * (MAX_BPS - uint(slippageTolerance0)) / MAX_BPS / 1e18
        );

        price = mkusdPool.price_scale();
        amountOut = mkusdPool.exchange(
            uint(1), // PRISMA idx
            uint(0), // mkUSD idx
            amountOut,
            0
            // amountOut * price * (MAX_BPS - uint(slippageTolerance1)) / MAX_BPS / 1e18
        );

        return amountOut;
    }

    /**
     * @notice
     *  Here we force a claim of yPRISMA on our next harvest, even if not fully boosted.
     @param _forceClaimOnce True if we want to allow claims that are not max boosted.
     */
    function setForceClaimOnce(
        bool _forceClaimOnce
    ) external onlyManagement {
        forceClaimOnce = _forceClaimOnce;
    }

    /**
     * @notice Force a rewards claim from the receiver regardless of max boost.
     * @dev Can only be called by managers.
     * @param _boostDelegate Address of the boost delegate to use.
     * @param _maxFee Max we fee are willing to pay for boost rental.
     */
    function claimRewards(
        address _boostDelegate,
        uint _maxFee
    ) external onlyManagement {
        require(_boostDelegate != address(0));
        _claimRewards(true, _boostDelegate, _maxFee);
    }

    function claimsAreMaxBoosted() public view returns (bool) {
        uint claimable = stabilityPool.claimableReward(address(this));
        (uint maxBoostable, ) = prismaVault.getClaimableWithBoost(
            YEARN_LOCKER
        );
        return maxBoostable >= claimable;
    }

    /// @notice Sweep token, only governance can call it
    function sweep(address _token) external {
        require(msg.sender == GOV, "!GOV");
        require(_token != address(asset), "!asset");
        ERC20(_token).safeTransfer(GOV, ERC20(_token).balanceOf(address(this)));
    }

    /**
        * @notice Force a rewards claim from the receiver regardless of max boost.
    */
    function getOraclePrice(address _collateral) external view returns (uint price) {
        price = _fetchPrice(_collateral);
        require(price > 0, "OracleZero");
    }

    function setDiscount(uint _discount) external onlyManagement {
        _setDiscount(_discount);
    }

    function _setDiscount(uint _discount) internal {
        require(_discount <= 1_000); // 10%
        discount = uint16(_discount);
        emit DiscountSet(_discount);
    }

    /**
     * @notice Here we set params to determine if we claim PRISMA emissions.
     # @param _forceClaimOnce True if we want to allow claims that are not max boosted. Reset to false on rewards claim.
     # @param _shouldClaimRewards Default value true. Set to false if we want to skip reward claims during harvests.
     */
    function setClaimParams(
        bool _forceClaimOnce,
        bool _shouldClaimRewards
    ) external onlyManagement {
        claimParams.forceClaimOnce = _forceClaimOnce;
        claimParams.shouldClaimRewards = _shouldClaimRewards;
    }

    function setParameters(uint _keepYPrisma, uint _dustThreshold, uint _slippageTolerance0, uint _slippageTolerance1) external onlyManagement {
        require(_slippageTolerance0 < 10_000, "Slip too high");
        require(_slippageTolerance1 < 10_000, "Slip too high");
        require(_keepYPrisma < 5_000, "Keep too high");
        slippageTolerance0 = uint16(_slippageTolerance0);
        slippageTolerance1 = uint16(_slippageTolerance1);
        keepYPrisma = uint16(_keepYPrisma);
        dustThreshold = _dustThreshold;
        emit ParametersUpdated(_slippageTolerance0, _slippageTolerance1, keepYPrisma, dustThreshold);
    }
    

    function getCollateralCount() external view returns (uint) {
        return collaterals.length;
    }
}
