// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KaskadAggregatorV3} from "./KaskadAggregatorV3.sol";
import {HemiNuntiusPriceAdapter} from "./HemiNuntiusPriceAdapter.sol";

contract HemiPriceSources {
    KaskadAggregatorV3 public immutable btcAggregator;
    KaskadAggregatorV3 public immutable usdcAggregator;
    HemiNuntiusPriceAdapter public immutable hbtcSource;
    HemiNuntiusPriceAdapter public immutable hemiSource;
    HemiNuntiusPriceAdapter public immutable usdcSource;

    constructor(address registry, address existingHemiAggregator) {
        btcAggregator = new KaskadAggregatorV3(registry, keccak256("BTC/USD"), "BTC/USD");
        usdcAggregator = new KaskadAggregatorV3(registry, keccak256("USDC/USD"), "USDC/USD");
        hbtcSource = new HemiNuntiusPriceAdapter(address(btcAggregator), registry, keccak256("BTC/USD"));
        hemiSource = new HemiNuntiusPriceAdapter(existingHemiAggregator, registry, keccak256("HEMI/USD"));
        usdcSource = new HemiNuntiusPriceAdapter(address(usdcAggregator), registry, keccak256("USDC/USD"));
    }
}
