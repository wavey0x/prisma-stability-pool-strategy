// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SwapperWsteth is Swapper {
    using SafeERC20 for ERC20;

    /** 
     TODO: 
        1. Seasolver
        2. Sweep
        3. Trigger
    */

    address public immutable collateral;
    address public immutable targetToken;
    address public immutable strategy;

    address public constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant steth = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant stethPool = 0xdc24316b9ae028f1497c275eb9192a3ea0f67022;
    address public constant tricryptoUsdcPool = 0x7f86bf177dd4f3494b841a37e810a34dd56c829b;
    address public constant mkusdUsdcPool = 0xf980b4a4194694913af231de69ab4593f5e0fcdc;
    
    constructor(address _targetToken, address _collateral, address _strategy) {
        targetToken = _targetToken;
        collateral = _collateral;
        stETH.approve(curve, type(uint).max);
        weth.approve(curve, type(uint).max);
        usdc.approve(curve, type(uint).max);
        strategy = _strategy;
    }

    function swap(uint _amount) external {
        require(msg.sender == strategy, "!authorized");

        ERC20(collateral).transferFrom(strategy, address(this), _amount);

        _amount = _unwrap(_amount);
        _amount = _tradeToEth(_amount);
        _amount = _tradeToUsdc(_amount);
        return _tradeToTargetToken(_amount);
    }

    function _unwrap(uint _amount) internal returns (uint) {
        return wstETH.unwrap(_amount);
    }

    function _tradeToEth(uint _amount) internal returns (uint) {
        return curve.exchange(1, 0, _amount, min);
    }

    function _tradeToUsdc(uint _amount) internal returns (uint) {
        IWETH(WETH).deposit{value: _amount}();
        return curve.exchange(1, 0, _amount, min);
    }

    function _tradeToTargetToken(uint _amount) internal returns (uint) {
        return curve.exchange(1, 0, _amount, strategy, min);
    }

    function receive() external payable;
}