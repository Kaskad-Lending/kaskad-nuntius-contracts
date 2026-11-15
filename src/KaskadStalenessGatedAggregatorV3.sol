// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IKaskadPriceOracleRead} from "./IKaskadPriceOracleRead.sol";

/// @notice Read surface of the lending market's staleness checker.
interface IStalenessWindow {
    function maxStaleness() external view returns (uint256);
}

/// @title KaskadStalenessGatedAggregatorV3
/// @notice KaskadAggregatorV3 whose `latestAnswer()` reverts once the price is
///         older than the checker's `maxStaleness`. AaveOracle reads only
///         `latestAnswer()`, so a stale feed cannot price a withdraw or borrow.
/// @dev `latestRoundData()` and the historical reads stay ungated: the staleness
///      checker reads `updatedAt` from them for its own freshness verdict.
contract KaskadStalenessGatedAggregatorV3 {
    error RoundIdOverflow(uint256 roundId);
    error StalePrice(uint256 updatedAt, uint256 maxStaleness);

    IKaskadPriceOracleRead public immutable oracle;
    IStalenessWindow public immutable stalenessChecker;
    bytes32 public immutable assetId;
    string public description;
    uint8 public constant decimals = 8;
    uint256 public constant version = 1;

    constructor(address _oracle, bytes32 _assetId, string memory _desc, address _checker) {
        oracle = IKaskadPriceOracleRead(_oracle);
        stalenessChecker = IStalenessWindow(_checker);
        assetId = _assetId;
        description = _desc;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint256 price, uint256 ts,, uint80 round) = oracle.getLatestPrice(assetId);
        return (round, int256(price), ts, ts, round);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint256 price, uint256 ts,) = oracle.getRoundData(assetId, _roundId);
        return (_roundId, int256(price), ts, ts, _roundId);
    }

    /// @notice Latest price; reverts `StalePrice` past the checker's window.
    function latestAnswer() external view returns (int256) {
        (uint256 price, uint256 ts,,) = oracle.getLatestPrice(assetId);
        uint256 maxStale = stalenessChecker.maxStaleness();
        if (block.timestamp > ts + maxStale) revert StalePrice(ts, maxStale);
        return int256(price);
    }

    function latestRound() external view returns (uint256) {
        (,,, uint80 round) = oracle.getLatestPrice(assetId);
        return uint256(round);
    }

    function latestTimestamp() external view returns (uint256) {
        (, uint256 ts,,) = oracle.getLatestPrice(assetId);
        return ts;
    }

    function getAnswer(uint256 _roundId) external view returns (int256) {
        if (_roundId > type(uint80).max) revert RoundIdOverflow(_roundId);
        (uint256 price,,) = oracle.getRoundData(assetId, uint80(_roundId));
        return int256(price);
    }

    function getTimestamp(uint256 _roundId) external view returns (uint256) {
        if (_roundId > type(uint80).max) revert RoundIdOverflow(_roundId);
        (, uint256 ts,) = oracle.getRoundData(assetId, uint80(_roundId));
        return ts;
    }
}
