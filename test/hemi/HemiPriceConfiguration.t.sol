// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KaskadPriceOracleV2} from "../../src/KaskadPriceOracleV2.sol";
import {HemiPriceSources} from "../../src/HemiPriceSources.sol";
import {HemiNuntiusPriceAdapter} from "../../src/HemiNuntiusPriceAdapter.sol";

interface IHemiAaveOracle {
    function setAssetSources(address[] calldata assets, address[] calldata sources) external;
    function getAssetPrice(address asset) external view returns (uint256);
    function getSourceOfAsset(address asset) external view returns (address);
}

interface IHemiPoolConfiguration {
    function getConfiguration(address asset) external view returns (uint256);
}

contract HemiPriceConfigurationTest is Test {
    KaskadPriceOracleV2 private constant REGISTRY = KaskadPriceOracleV2(0xaa756d70edea36F834B982E03A79EE59835d0d1A);
    IHemiAaveOracle private constant AAVE = IHemiAaveOracle(0xa210FB1F6AF21066675e208e57F282eb770Ac70e);
    IHemiPoolConfiguration private constant POOL = IHemiPoolConfiguration(0xf3E62b03e8DEd32B7000A1800460C92803f9E798);
    address private constant HEMI_AGGREGATOR = 0x4f61dB806724259e3fcf8f3d2496B66d736bE111;
    address private constant HBTC = 0x36Ab5Dba83d5d470F670BC4c06d7Da685d9afAe7;
    address private constant HEMI = 0x258D1550a149D13e05599e484D1658032aEE01Cc;
    address private constant USDC = 0xD47971C7F5B1067d25cd45d30b2c9eb60de96443;
    address private constant WETH = 0x0C8aFD1b58aa2A5bAd2414B861D8A7fF898eDC3A;
    address private constant USDT = 0x3Adf21A6cbc9ce6D5a3ea401E7Bae9499d391298;

    struct SignedUpdate {
        bytes32 assetId;
        uint256 price;
        uint256 timestamp;
        uint8 sources;
        bytes32 sourcesHash;
        bytes signature;
    }

    HemiPriceSources private bundle;
    SignedUpdate[] private updates;
    uint256[5] private originalConfigurations;
    address[5] private tokens = [WETH, USDT, HBTC, HEMI, USDC];
    address private owner;

    function setUp() public {
        vm.createSelectFork(vm.envOr("HEMI_RPC_URL", string("https://testnet.rpc.hemi.network/rpc")));
        assertEq(block.chainid, 743111);
        owner = REGISTRY.owner();
        for (uint256 i; i < tokens.length; ++i) {
            originalConfigurations[i] = POOL.getConfiguration(tokens[i]);
        }
        string memory fixture = vm.readFile("../scratchpad/hemi-prices/signed-prices.json");
        for (uint256 i; i < 4; ++i) {
            string memory path = string.concat(".updates[", vm.toString(i), "]");
            updates.push(
                SignedUpdate({
                    assetId: vm.parseJsonBytes32(fixture, string.concat(path, ".asset_id")),
                    price: vm.parseUint(vm.parseJsonString(fixture, string.concat(path, ".price"))),
                    timestamp: vm.parseJsonUint(fixture, string.concat(path, ".timestamp")),
                    sources: uint8(vm.parseJsonUint(fixture, string.concat(path, ".num_sources"))),
                    sourcesHash: vm.parseJsonBytes32(fixture, string.concat(path, ".sources_hash")),
                    signature: vm.parseJsonBytes(fixture, string.concat(path, ".signature"))
                })
            );
            assertLe(updates[i].timestamp, block.timestamp + 30);
            assertGe(updates[i].timestamp + 120, block.timestamp);
        }
        vm.prank(owner);
        REGISTRY.registerAssets(_configs());
        bundle = new HemiPriceSources(address(REGISTRY), HEMI_AGGREGATOR);
        address[] memory assets = new address[](3);
        address[] memory sources = new address[](3);
        (assets[0], assets[1], assets[2]) = (HBTC, HEMI, USDC);
        (sources[0], sources[1], sources[2]) =
        (address(bundle.hbtcSource()), address(bundle.hemiSource()), address(bundle.usdcSource()));
        vm.prank(owner);
        AAVE.setAssetSources(assets, sources);
    }

    function testPermissionlessPullUpdatesReadThroughAave() public {
        _publishAll();
        assertEq(AAVE.getAssetPrice(WETH), updates[0].price);
        assertEq(AAVE.getAssetPrice(USDT), updates[1].price);
        assertEq(AAVE.getAssetPrice(HBTC), updates[2].price);
        assertEq(AAVE.getAssetPrice(USDC), updates[3].price);
    }

    function testHemiWithoutSignedFeedFailsClosed() public {
        vm.expectRevert(HemiNuntiusPriceAdapter.InvalidPrice.selector);
        AAVE.getAssetPrice(HEMI);
    }

    function testStalePublicationIsRejected() public {
        _publishAll();
        vm.warp(block.timestamp + 181);
        vm.expectRevert(HemiNuntiusPriceAdapter.StalePublication.selector);
        AAVE.getAssetPrice(HBTC);
    }

    function testOldObservationCannotBeRefreshedByRepublishing() public {
        vm.warp(block.timestamp + 301);
        _publishAll();
        vm.expectRevert(HemiNuntiusPriceAdapter.StaleObservation.selector);
        AAVE.getAssetPrice(HBTC);
    }

    function testInsufficientSourceQuorumIsRejected() public {
        SignedUpdate memory update = updates[2];
        vm.expectRevert(KaskadPriceOracleV2.InsufficientSources.selector);
        REGISTRY.updatePrice(update.assetId, update.price, update.timestamp, 1, update.sourcesHash, update.signature);
    }

    function testAllReserveRiskParametersAndPauseFlagsArePreserved() public view {
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(POOL.getConfiguration(tokens[i]), originalConfigurations[i]);
        }
        assertEq(AAVE.getSourceOfAsset(WETH), 0xF1CF3d9C48a5c73DD2c13F9d8b35C8FE69740391);
        assertEq(AAVE.getSourceOfAsset(USDT), 0x46229635c5Cb502AB03DD29F2283EfE0312937cD);
    }

    function testExistingFeedsRemainRegistered() public view {
        (uint8 ethSources, uint16 ethChange, uint16 ethResume) = REGISTRY.assetParams(keccak256("ETH/USD"));
        (uint8 usdtSources, uint16 usdtChange, uint16 usdtResume) = REGISTRY.assetParams(keccak256("USDT/USD"));
        assertEq(ethSources, 3);
        assertEq(ethChange, 1000);
        assertEq(ethResume, 2500);
        assertEq(usdtSources, 2);
        assertEq(usdtChange, 200);
        assertEq(usdtResume, 1000);
        assertEq(REGISTRY.registeredAssetIds().length, 5);
    }

    function testDeploymentAddressPredictionsMatchCreatedContracts() public view {
        assertEq(address(bundle.btcAggregator()), vm.computeCreateAddress(address(bundle), 1));
        assertEq(address(bundle.usdcAggregator()), vm.computeCreateAddress(address(bundle), 2));
        assertEq(address(bundle.hbtcSource()), vm.computeCreateAddress(address(bundle), 3));
        assertEq(address(bundle.hemiSource()), vm.computeCreateAddress(address(bundle), 4));
        assertEq(address(bundle.usdcSource()), vm.computeCreateAddress(address(bundle), 5));
    }

    function testMismatchedHemiAggregatorIsRejected() public {
        address wrongAggregator = address(bundle.btcAggregator());
        vm.expectRevert(HemiNuntiusPriceAdapter.InvalidSource.selector);
        new HemiPriceSources(address(REGISTRY), wrongAggregator);
    }

    function testUnauthorizedAssetRegistrationIsRejected() public {
        vm.expectRevert();
        REGISTRY.registerAssets(_configs());
    }

    function _publishAll() private {
        for (uint256 i; i < updates.length; ++i) {
            SignedUpdate memory update = updates[i];
            vm.prank(address(0xBEEF));
            REGISTRY.updatePrice(
                update.assetId, update.price, update.timestamp, update.sources, update.sourcesHash, update.signature
            );
        }
    }

    function _configs() private pure returns (KaskadPriceOracleV2.AssetConfig[] memory configs) {
        configs = new KaskadPriceOracleV2.AssetConfig[](5);
        configs[0] = KaskadPriceOracleV2.AssetConfig(keccak256("ETH/USD"), 3, 1000, 2500);
        configs[1] = KaskadPriceOracleV2.AssetConfig(keccak256("USDT/USD"), 2, 200, 1000);
        configs[2] = KaskadPriceOracleV2.AssetConfig(keccak256("BTC/USD"), 3, 1000, 2500);
        configs[3] = KaskadPriceOracleV2.AssetConfig(keccak256("USDC/USD"), 2, 200, 1000);
        configs[4] = KaskadPriceOracleV2.AssetConfig(keccak256("HEMI/USD"), 3, 3000, 5000);
        for (uint256 i; i < configs.length; ++i) {
            for (uint256 j = i + 1; j < configs.length; ++j) {
                if (configs[j].id < configs[i].id) (configs[i], configs[j]) = (configs[j], configs[i]);
            }
        }
    }
}
