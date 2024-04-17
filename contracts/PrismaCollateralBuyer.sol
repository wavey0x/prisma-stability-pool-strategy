pragma solidity 0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IStrategy {
    function getClaimableIndices() external view returns (uint[] memory claimIndices);
    function asset() external view returns (ERC20);
    function getPriceForAvailableSellTokens(uint[] memory collateralIndices) external view returns (uint);
    function buyCollateral(uint[] memory collateralIndices, uint maxCost) external;
}


/**
 * This contract is used to permissionlessly buy collateral tokens from any stability pool strategy in exchange for the debt token.
 */
contract PrismaCollateralBuyer {
    using SafeERC20 for ERC20;

    address public constant owner = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;
    uint public MAX_BPS = 10_000;
    uint public slippageTolerance = 300;
    
    mapping(address strategy => bool approved) public approvedStrategies;


    function buyCollateral(IStrategy _strategy, uint[] memory claimIndices, uint maxCost) external {
        _strategy.buyCollateral(claimIndices, maxCost);
    }

    function calcMaxBuyParameters(IStrategy _strategy) external view returns (uint[] memory claimableIndices, uint maxCost) {
        claimableIndices = _strategy.getClaimableIndices();
        ERC20 asset = IStrategy(_strategy).asset();
        uint cash = asset.balanceOf(address(this));
        uint[] memory targetIndices;
        uint price;
        uint pendingPrice;
        for (uint i=0; i < claimableIndices.length; i++){
            targetIndices[i] = claimableIndices[i];
            pendingPrice = _strategy.getPriceForAvailableSellTokens(targetIndices);
            if (pendingPrice > cash) {
                assembly {
                    mstore(targetIndices, i) // Trim any excess array length.
                }
                break;
            }
            price = pendingPrice;
        }
        return (targetIndices, price + (price * slippageTolerance / MAX_BPS)); // Allow 3%
    }

    function setSlippageTolerance(uint _tolerance) external {
        require(msg.sender == owner);
        require(_tolerance <= 5_000, "Too high");
        slippageTolerance = _tolerance;
    }
    
    function approveStrategy(address _strategy, bool _approved) external {
        require(msg.sender == owner, "!authorized");
        require(approvedStrategies[_strategy] != _approved, "Already set");

        approvedStrategies[_strategy] = _approved;
        ERC20 asset = IStrategy(_strategy).asset();

        if (_approved) {
            asset.approve(_strategy, type(uint).max);
        }
        else {
            asset.approve(_strategy, 0);
        }
    }

    /// @notice Sweep token, only owner can call it
    function sweep(address _token) external {
        require(msg.sender == owner, "!authorized");
        ERC20(_token).safeTransfer(owner, ERC20(_token).balanceOf(address(this)));
    }
}