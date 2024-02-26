// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPrismaVault} from "./interfaces/prisma/IPrismaVault.sol";
import {IStabilityPool} from "./interfaces/prisma/IStabilityPool.sol";
import {ITroveManager} from "./interfaces/prisma/ITroveManager.sol";
import {IFactory} from "./interfaces/prisma/IFactory.sol";
import {OraclePricer} from "./OraclePricer.sol";
import {IAggregatorV3Interface} from "./interfaces/chainlink/IAggregatorV3Interface.sol";


contract Strategy is BaseStrategy, OraclePricer {
    using SafeERC20 for ERC20;

    uint constant FEE_DENOMINATOR = 10_000;

    /// @notice Yearn's Prisma locker contract.
    address public constant YEARN_LOCKER = 0x90be6DFEa8C80c184C442a36e17cB2439AAE25a7;

    /// @notice The address of the yPrisma token. This is minted to us as an alternative to creating a lock.
    ERC20 public constant yPrisma = ERC20(0xe3668873D944E4A949DA05fc8bDE419eFF543882);

    IStabilityPool public immutable stabilityPool; // 0xed8B26D99834540C5013701bB3715faFD39993Ba
    
    IFactory public immutable factory; // 0x70b66E20766b775B2E9cE5B718bbD285Af59b7E1

    /// @notice Where we claim emissions as yPRISMA
    IPrismaVault public immutable prismaVault; // 0x06bDF212C290473dCACea9793890C5024c7Eb02c

    /// @notice The percentage of yPRISMA from each harvest that we send to our voter (out of 10,000).
    uint public localKeepYPrisma;

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

    mapping(address collateral => ITroveManager troveManager) public troveManagers;

    struct ClaimParams {
        /// @notice We use this flag to signal a desire to claim even if Yearns locker cant provide max boost.
        bool forceClaimOnce;
        /// @notice Defaults to true, set to false to skip reward claiming altogether.
        bool shouldClaimRewards;
    }

    event CollateralSynced(address collateral);
    event CollateralSold(address indexed buyer, uint price, uint[] collateralIndices);

    constructor(
        address _asset,
        string memory _name,
        address _factory,
        address _stabilityPool,
        address _prismaVault,
        address _priceFeed
    ) BaseStrategy(_asset, _name) OraclePricer(_priceFeed) {
        stabilityPool = IStabilityPool(_stabilityPool);
        factory = IFactory(_factory);
        prismaVault = IPrismaVault(_prismaVault);
        syncCollaterals();
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
        _totalAssets = asset.balanceOf(address(this));
        if(!TokenizedStrategy.isShutdown()) {
            if (claimParams.shouldClaimRewards) {
                _claimRewards(claimParams.forceClaimOnce, YEARN_LOCKER, 10_000);
            }

            // deposit any loose funds
            uint looseAsset = ERC20(asset).balanceOf(address(this));
            if (looseAsset > 0) {
                stabilityPool.provideToSP(looseAsset);
            }
        }

        _totalAssets = getTotalAssets();
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

    function getTotalAssets() public view returns (uint) {
        return getAssetBalance() + stabilityPool.getCompoundedDebtDeposit(address(this));
    }

    function getAssetBalance() public view returns (uint) {
        return asset.balanceOf(address(this));
    }


    function _tend(uint _totalIdle) internal override {
        _deployFunds(_totalIdle);
    }

    function _tendTrigger() internal view override virtual returns (bool) {

    }

    /**
        @notice Helper function to help discover which indexes can be claimed from.
    */
    function getClaimableIndices() external view returns (uint[] memory claimIndices) {
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
            mstore(claimIndices, claimCount)
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
        return totalPrice;
    }

    function buyCollateral(uint[] memory _collateralIndices, uint _maxAmount) external {
        uint price = getPriceForAvailableSellTokens(_collateralIndices);
        require(price <= _maxAmount, "Price too high");
        asset.transferFrom(msg.sender, address(this), price);
        stabilityPool.withdrawFromSP(0); // Trigger rewards accrual
        stabilityPool.claimCollateralGains(msg.sender, _collateralIndices);
        emit CollateralSold(msg.sender, price, _collateralIndices);
    }

    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint) {
        return getTotalAssets();
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
    ) internal {
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
        }
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

    /**
        * @notice Force a rewards claim from the receiver regardless of max boost.
    */
    function getOraclePrice(address collateral) external view returns (uint price) {
        price = _fetchPrice(collateral);
        require(price > 0, "OracleZero");
    }

    function getCollateralCount() external view returns (uint) {
        return collaterals.length;
    }
}
