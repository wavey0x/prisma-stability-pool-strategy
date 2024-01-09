// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPrismaVault} from "./interfaces/prisma/IPrismaVault.sol";
import {IStabilityPool} from "./interfaces/prisma/IStabilityPool.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for ERC20;

    uint256 constant FEE_DENOMINATOR = 10_000;
    /// @notice Yearn's Prisma locker contract.
    address public constant YEARN_LOCKER = 0x90be6DFEa8C80c184C442a36e17cB2439AAE25a7;

    /// @notice The address of the yPrisma token. This is minted to us as an alternative to creating a lock.
    ERC20 public constant yPrisma = ERC20(0xe3668873D944E4A949DA05fc8bDE419eFF543882);

    IStabilityPool public constant stabilityPool = IStabilityPool(0xed8B26D99834540C5013701bB3715faFD39993Ba);

    /// @notice Where we claim emissions as yPRISMA
    IPrismaVault public prismaVault;

    /// @notice The percentage of yPRISMA from each harvest that we send to our voter (out of 10,000).
    uint256 public localKeepYPrisma;

    /// @notice Determines whether collateral gains will be claimed during reports.
    bool public claimCollateralGains;

    /// @notice If true, will temporarily override requirement that all claims be max boosted.
    bool public forceClaimOnce;

    mapping(address collateral => SwapData swapData) swappers;

    /// @notice Swapper struct uses packed storage.
    struct SwapData {
        address swapper;
        uint96 sellThreshold;
    }

    constructor(
        address _asset,
        string memory _name
    ) BaseStrategy(_asset, _name) {}


    function _deployFunds(uint256 _amount) internal override {
        stabilityPool.provideToSP(_amount);
    }

    function _freeFunds(uint256 _amount) internal override {
        stabilityPool.withdrawFromSP(_amount);
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        _totalAssets = asset.balanceOf(address(this));
        if(!TokenizedStrategy.isShutdown()) {
            if (claimCollateralGains) _claimAndSellCollateralGains();

            // deposit any loose funds
            uint256 looseAsset = ERC20(asset).balanceOf(address(this));
            if (looseAsset > 0) {
                stabilityPool.provideToSP(looseAsset);
            }
        }

        _totalAssets = getTotalAssets();
    }

    function _claimAndSellCollateralGains() internal returns (uint256 amount) {
        
        uint256[] memory collateralIndexes;
        address[] memory collaterals;
        uint256 i;
        
        while (true) {
            // This reverts when index doesn't exist.
            try stabilityPool.collateralTokens(i) returns (address coll) {
                collateralIndexes[i] = i;
                collaterals[i] = coll;
                i++;
            } catch {
                break;
            }
        }

        // Claim all our gains
        stabilityPool.claimCollateralGains(address(this), collateralIndexes);

        for (i = 0; i < collateralIndexes.length; i++){
            address coll = collaterals[i];
            uint256 balance = ERC20(coll).balanceOf(address(this));
            SwapData memory s = swappers[coll];
            if (balance >= s.sellThreshold){
                if (s.swapper == address(0)) continue;
                amount += ISwapper(s.swapper).swap(balance);
            }
        }
    }

    function setSwapData(address _swapper, address _collateral, uint96 _sellThreshold) external onlyManagement returns (bool) {
        require(_sellThreshold > 0, "must set threshold");
        address oldSwapper = swappers[_collateral].swapper;

        if (oldSwapper != _swapper) {
            ERC20(_collateral).approve(oldSwapper, 0);
        }

        if (_swapper != address(0)){
            require(ISwapper(_swapper).collateral() == _collateral, "collateral does not match");
            require(ISwapper(_swapper).targetToken() == address(asset), "target token does not match");
            ERC20(_collateral).approve(_swapper, type(uint).max);
        }

        swappers[_collateral] = SwapData(_swapper, _sellThreshold);
    }

    function getTotalAssets() public view returns (uint256) {
        return getAssetBalance() + stabilityPool.getCompoundedDebtDeposit(address(this));
    }

    function getAssetBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }


    function _tend(uint256 _totalIdle) internal override {
        _totalIdle += _claimAndSellCollateralGains();
        _deployFunds(_totalIdle);
    }

    function _tendTrigger() internal view override virtual returns (bool) {
        uint256[] memory collateralGains = stabilityPool.getDepositorCollateralGain(address(this));
        for (uint i = 0; i < collateralGains.length; i++) {
            address coll = stabilityPool.collateralTokens(i);
            SwapData memory s = swappers[coll];
            if (collateralGains[i] > s.sellThreshold) {
                return true;
            }
        }
        return false;
    }

    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        return getTotalAssets();
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        // Pull full amount. Stability pool scales down to actual balance for us.
        _freeFunds(type(uint).max);
    }

    function _claimRewards() internal {
        // By default, we only claim if max boosted. Force claim once if needed.
        bool _forceClaimOnce = forceClaimOnce;

        if (claimsAreMaxBoosted() || _forceClaimOnce) {
            address[] memory rewardContracts = new address[](1);
            rewardContracts[0] = address(stabilityPool);
            prismaVault.batchClaimRewards(
                YEARN_LOCKER,       // receiver
                YEARN_LOCKER,       // delegate
                rewardContracts,    // rewards contracts
                FEE_DENOMINATOR     // maxFee
            );

            // reset if we forced this one
            if (_forceClaimOnce) {
                forceClaimOnce = false;
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

    function claimRewards() external onlyManagement {
        _claimRewards();
    }

    function claimsAreMaxBoosted() public view returns (bool) {
        uint256 claimable = stabilityPool.claimableReward(address(this));
        (uint256 maxBoostable, ) = prismaVault.getClaimableWithBoost(
            YEARN_LOCKER
        );
        return maxBoostable >= claimable;
    }
}
