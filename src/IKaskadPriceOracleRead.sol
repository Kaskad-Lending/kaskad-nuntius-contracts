// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title IKaskadPriceOracleRead
/// @notice Read surface shared by every KaskadPriceOracle version, so one
///         aggregator wraps any of them.
interface IKaskadPriceOracleRead {
    function getLatestPrice(bytes32 assetId)
        external
        view
        returns (uint256 price, uint256 timestamp, uint8 numSources, uint80 roundId);

    function getRoundData(bytes32 assetId, uint80 roundId)
        external
        view
        returns (uint256 price, uint256 timestamp, uint8 numSources);
}
