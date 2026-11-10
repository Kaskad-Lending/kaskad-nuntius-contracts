// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {KaskadRouter} from "./KaskadRouter.sol";

interface IHemiAddressesProvider {
    function getPriceOracle() external view returns (address);
}

interface IHemiPriceOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

/// @title HemiKaskadRouter
/// @notice KaskadRouter for markets without a price-oracle sentinel. The
///         borrowed asset is fresh when the pool's price oracle returns a
///         non-zero price; Hemi price sources revert once a price goes stale.
contract HemiKaskadRouter is KaskadRouter {
    constructor(address _oracle, address _pool, address _weth) KaskadRouter(_oracle, _pool, _weth) {}

    function _requireFreshAsset(address asset) internal view override {
        address priceOracle = IHemiAddressesProvider(pool.ADDRESSES_PROVIDER()).getPriceOracle();
        try IHemiPriceOracle(priceOracle).getAssetPrice(asset) returns (uint256 price) {
            if (price == 0) revert StaleAsset(asset);
        } catch {
            revert StaleAsset(asset);
        }
    }
}
