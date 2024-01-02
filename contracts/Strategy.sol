// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPrismaVault} from "./interfaces/prisma/IPrismaVault.sol";
import {IStabilityPool} from "./interfaces/prisma/IStabilityPool.sol";

import {ISwapper} from "./interfaces/ISwapper.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */



// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

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
        // By this point, we've already processed the _amount value and
        // can safely assume it all needs to be withdrawn.
        stabilityPool.withdrawFromSP(_amount);
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
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

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * The TokenizedStrategy contract will do all needed debt and idle updates
     * after this has finished and will have no effect on PPS of the strategy
     * till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
    */

    function _tend(uint256 _totalIdle) internal override {}

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    function _tendTrigger() internal view override returns (bool) {}
    */

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
    */
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        return getTotalAssets();
    }
    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
    */

    /** 
        @param _amount The amount of asset to attempt to free.
    */
    function _emergencyWithdraw(uint256 _amount) internal override {
        uint256 total = stabilityPool.getCompoundedDebtDeposit(address(this));
        _amount = Math.min(_amount, total);
        _freeFunds(_amount);
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
