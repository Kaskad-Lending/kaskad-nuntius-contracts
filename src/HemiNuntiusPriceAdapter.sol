// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IHemiNuntiusFeed {
    function oracle() external view returns (address);
    function assetId() external view returns (bytes32);
    function decimals() external view returns (uint8);
}

interface IHemiNuntiusRegistry {
    function latestPrices(bytes32 assetId) external view returns (uint256, uint256, uint256, uint8, bytes32, uint80);
    function assetParams(bytes32 assetId) external view returns (uint8, uint16, uint16);
}

contract HemiNuntiusPriceAdapter {
    uint8 public constant decimals = 8;
    uint256 public constant MAX_PUBLICATION_AGE = 180;
    uint256 public constant MAX_OBSERVATION_AGE = 300;
    uint256 public constant MAX_FUTURE_SKEW = 30;

    address public immutable source;
    IHemiNuntiusRegistry public immutable registry;
    bytes32 public immutable assetId;

    error InvalidSource();
    error InvalidPrice();
    error StalePublication();
    error StaleObservation();
    error InsufficientSources();

    constructor(address source_, address expectedRegistry, bytes32 expectedAssetId) {
        if (source_.code.length == 0 || expectedRegistry.code.length == 0) revert InvalidSource();
        IHemiNuntiusFeed feed = IHemiNuntiusFeed(source_);
        if (feed.oracle() != expectedRegistry || feed.assetId() != expectedAssetId || feed.decimals() != decimals) {
            revert InvalidSource();
        }
        source = source_;
        registry = IHemiNuntiusRegistry(expectedRegistry);
        assetId = expectedAssetId;
    }

    function latestAnswer() external view returns (int256 answer) {
        (, answer,,,) = latestRoundData();
    }

    function latestRoundData() public view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 price, uint256 publishedAt, uint256 signedAt, uint8 count,, uint80 round) =
            registry.latestPrices(assetId);
        (uint8 minimum,,) = registry.assetParams(assetId);
        if (price == 0 || price > uint256(type(int256).max) || round == 0) revert InvalidPrice();
        if (minimum == 0 || count < minimum) revert InsufficientSources();
        if (publishedAt == 0 || publishedAt > block.timestamp || block.timestamp - publishedAt > MAX_PUBLICATION_AGE) {
            revert StalePublication();
        }
        if (
            signedAt == 0 || signedAt > block.timestamp + MAX_FUTURE_SKEW
                || (signedAt < block.timestamp && block.timestamp - signedAt > MAX_OBSERVATION_AGE)
        ) revert StaleObservation();
        return (round, int256(price), signedAt, signedAt, round);
    }
}
