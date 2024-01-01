// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

interface ISwapper {
    function swap(uint256 _amountIn) external returns (uint256 _amountOut);
    function collateral() external view returns (address);
}
