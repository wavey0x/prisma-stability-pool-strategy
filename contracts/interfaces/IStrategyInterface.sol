// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    // Events
    event CollateralsSynced(address[] collaterals);
    event CollateralSold(address indexed buyer, uint totalCost, uint[] collateralIndices);
    event DiscountSet(uint discount);

    // Struct
    struct ClaimParams {
        bool forceClaimOnce;
        bool shouldClaimRewards;
    }

    // Function signatures
    function syncCollaterals() external;
    function estimatedTotalAssets() external view returns (uint);
    function getAssetBalance() external view returns (uint);
    function availableWithdrawLimit(address _owner) external view returns (uint);
    function prismaReceiver() external view returns (address);
    function setForceClaimOnce(bool _forceClaimOnce) external;
    function claimRewards(address _boostDelegate, uint _maxFee) external;
    function claimsAreMaxBoosted() external view returns (bool);
    function collaterals(uint idx) external view returns (address collateral);
    function lastSyncIndex() external view returns (uint);
    function getOraclePrice(address collateral) external view returns (uint);
    function getPriceForAvailableSellTokens(uint[] memory _collateralIndices) external view returns (uint);
    function buyCollateral(uint[] memory _collateralIndices, uint _maxAmount) external;
    function getClaimableIndices() external view returns (uint[] memory claimIndices);
    function getCollateralCount() external view returns (uint);
    function setParameters(uint _keepYPrisma, uint _dustThreshold, uint _slippageTolerance0, uint _slippageTolerance1) external;
    function setDiscount(uint _discount) external;
    function claimParams() external view returns (ClaimParams memory);
    function setClaimParams(bool _forceClaimOnce, bool _shouldClaimRewards) external;
}