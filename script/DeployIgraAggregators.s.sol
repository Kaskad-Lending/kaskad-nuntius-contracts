// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {KaskadStalenessGatedAggregatorV3} from "../src/KaskadStalenessGatedAggregatorV3.sol";

interface IAaveOracleSources {
    function setAssetSources(address[] calldata assets, address[] calldata sources) external;
}

/// @notice Deploy the five staleness-gated aggregators for the Igra reserves over a
///         KaskadPriceOracleV2 and print the Safe's `AaveOracle.setAssetSources` calldata.
///
/// Env:
///   KASKAD_PRICE_ORACLE — address of the V2 oracle the aggregators read.
///   STALENESS_CHECKER   — address (optional; defaults to the live KaskadStalenessChecker).
///   DEPLOYER_KEY        — uint256 (optional if --private-key / --sender).
contract DeployIgraAggregators is Script {
    error WrongChain(uint256 chainid);

    uint256 internal constant IGRA_CHAIN_ID = 38833;
    address internal constant AAVE_ORACLE = 0xcf5C2E2509e28a225115FD51Fad1a45c7E91A08A;
    address internal constant STALENESS_CHECKER = 0xA1Ac7719C916e554588cD05d3A8f1700C1b48Ca8;

    address internal constant WETH = 0x69790024D44504F05973E127197E6df17e283859;
    address internal constant CBBTC = 0xF2B48b6e560af8834622203a8EEff6960d6172De;
    address internal constant WIKAS = 0x17Ec7E1768c813E2a3a9b0f94A35605CA520C242;
    address internal constant USDC = 0xA5b8BF902b2844dA17d4506cc827F7F1681735E7;
    address internal constant USDT = 0x46346F49b4fe8c640c5FCdbed2d6741056FEB959;

    struct Feed {
        address asset;
        bytes32 assetId;
        string description;
    }

    function run() external returns (address[] memory assets, address[] memory sources) {
        if (block.chainid != IGRA_CHAIN_ID) revert WrongChain(block.chainid);

        address oracle = vm.envAddress("KASKAD_PRICE_ORACLE");
        address checker = vm.envOr("STALENESS_CHECKER", STALENESS_CHECKER);
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));

        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }
        (assets, sources) = deploy(oracle, checker);
        vm.stopBroadcast();

        console.log("Safe tx setAssetSources -> AaveOracle:", AAVE_ORACLE);
        console.log(vm.toString(abi.encodeCall(IAaveOracleSources.setAssetSources, (assets, sources))));
    }

    /// @notice Deploys and checks one aggregator per reserve; callers own the broadcast scope.
    function deploy(address oracle, address checker)
        public
        returns (address[] memory assets, address[] memory sources)
    {
        require(oracle != address(0), "KASKAD_PRICE_ORACLE == 0");
        require(checker != address(0), "STALENESS_CHECKER == 0");

        Feed[] memory feeds = feedsList();
        assets = new address[](feeds.length);
        sources = new address[](feeds.length);
        for (uint256 i = 0; i < feeds.length; i++) {
            KaskadStalenessGatedAggregatorV3 agg =
                new KaskadStalenessGatedAggregatorV3(oracle, feeds[i].assetId, feeds[i].description, checker);
            require(address(agg.oracle()) == oracle, "oracle not bound");
            require(address(agg.stalenessChecker()) == checker, "checker not bound");
            require(agg.assetId() == feeds[i].assetId, "assetId not bound");
            console.log(feeds[i].description, address(agg));
            assets[i] = feeds[i].asset;
            sources[i] = address(agg);
        }
    }

    /// @notice Reserve -> feed map; ids are keccak256 of the nuntius symbol, descriptions match the live feeds.
    function feedsList() public pure returns (Feed[] memory feeds) {
        feeds = new Feed[](5);
        feeds[0] = Feed(WETH, keccak256("ETH/USD"), "ETH / USD");
        feeds[1] = Feed(CBBTC, keccak256("BTC/USD"), "BTC / USD");
        feeds[2] = Feed(WIKAS, keccak256("KAS/USD"), "KAS / USD");
        feeds[3] = Feed(USDC, keccak256("USDC/USD"), "USDC / USD");
        feeds[4] = Feed(USDT, keccak256("USDT/USD"), "USDT / USD");
    }
}
