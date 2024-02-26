// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3Interface} from "./interfaces/chainlink/IAggregatorV3Interface.sol";
import {IPriceFeed} from "./interfaces/prisma/IPriceFeed.sol";

contract OraclePricer {

    uint constant TARGET_DIGITS = 1e18;

    IPriceFeed public immutable priceFeed; // 0xC105CeAcAeD23cad3E9607666FEF0b773BC86aac
    // Responses are considered stale this many seconds after the oracle's heartbeat
    uint256 public constant RESPONSE_TIMEOUT_BUFFER = 1 hours;

    event Debug(address oracle, int a, uint answer);
    constructor (address _priceFeed) {
        priceFeed = IPriceFeed(_priceFeed);
    }

    function _fetchPrice(address _token) internal returns (uint256) {

        (
            address chainLinkOracle,
            uint8 decimals,
            uint32 heartbeat,
            bytes4 sharePriceSignature,
            uint8 sharePriceDecimals,
            ,
            bool isEthIndexed
        ) = priceFeed.oracleRecords(_token);

        require(chainLinkOracle != address(0));

        (, int256 answer, , uint256 updated,) = IAggregatorV3Interface(chainLinkOracle).latestRoundData();

        require(!_isPriceStale(updated, heartbeat), "stale price");

        uint256 scaledPrice = _scalePriceByDigits(uint256(answer), decimals);
        if (sharePriceSignature != 0) {
            (bool success, bytes memory returnData) = _token.staticcall(abi.encode(sharePriceSignature));
            require(success, "Share price not available");
            scaledPrice = (scaledPrice * abi.decode(returnData, (uint256))) / (10 ** sharePriceDecimals);
        }

        if (isEthIndexed) {
            uint256 ethPrice = _fetchPrice(address(0));
            return (ethPrice * scaledPrice) / 1 ether;
        }

        return scaledPrice;
    }

    function _isPriceStale(uint256 _priceTimestamp, uint256 _heartbeat) internal view returns (bool) {
        return block.timestamp - _priceTimestamp > _heartbeat + RESPONSE_TIMEOUT_BUFFER;
    }

    function _scalePriceByDigits(uint256 _price, uint256 _answerDigits) internal pure returns (uint256) {
        if (_answerDigits == TARGET_DIGITS) {
            return _price;
        } else if (_answerDigits < TARGET_DIGITS) {
            // Scale the returned price value up to target precision
            return _price * (10 ** (TARGET_DIGITS - _answerDigits));
        } else {
            // Scale the returned price value down to target precision
            return _price / (10 ** (_answerDigits - TARGET_DIGITS));
        }
    }
}