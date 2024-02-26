// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    // Events
    event CollateralsSynced(address[] collaterals);

    // Function signatures
    function syncCollaterals() external;
    function getTotalAssets() external view returns (uint);
    function getAssetBalance() external view returns (uint);
    function availableWithdrawLimit(address _owner) external view returns (uint);
    function prismaReceiver() external view returns (address);
    function setForceClaimOnce(bool _forceClaimOnce) external;
    function claimRewards(address _boostDelegate, uint _maxFee) external;
    function claimsAreMaxBoosted() external view returns (bool);
    function collaterals(uint idx) external view returns (address collateral);
    function lastSyncIndex() external view returns (uint);
    function getOraclePrice2(address collateral) external view returns (int256);
    function getOraclePrice(address collateral) external view returns (uint response);
}