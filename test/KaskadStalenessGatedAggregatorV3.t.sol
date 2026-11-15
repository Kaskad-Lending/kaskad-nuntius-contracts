// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {KaskadPriceOracleV2} from "../src/KaskadPriceOracleV2.sol";
import {KaskadAggregatorV3} from "../src/KaskadAggregatorV3.sol";
import {KaskadStalenessGatedAggregatorV3} from "../src/KaskadStalenessGatedAggregatorV3.sol";
import {MockVerifierV2} from "./mocks/MockVerifiersV2.sol";

/// @notice Staleness checker stand-in with a settable window.
contract MockStalenessWindow {
    uint256 public maxStaleness;

    constructor(uint256 _maxStaleness) {
        maxStaleness = _maxStaleness;
    }

    function setMaxStaleness(uint256 _maxStaleness) external {
        maxStaleness = _maxStaleness;
    }
}

contract KaskadStalenessGatedAggregatorV3Test is Test {
    KaskadPriceOracleV2 oracle;
    MockStalenessWindow checker;
    KaskadStalenessGatedAggregatorV3 gated;
    KaskadAggregatorV3 plain;

    bytes32 internal constant PCR0 = bytes32(uint256(0xA11));
    bytes32 internal constant ETH_USD = keccak256("ETH/USD");
    uint256 internal constant WINDOW = 3600;

    address internal owner = address(0xAD31);
    uint256 internal signerKey = 0xA11CE;

    function setUp() public {
        vm.warp(1710000000);
        oracle = new KaskadPriceOracleV2(PCR0, address(new MockVerifierV2(PCR0)), owner);
        vm.prank(owner);
        oracle.registerEnclave(abi.encode(vm.addr(signerKey)));

        KaskadPriceOracleV2.AssetConfig[] memory c = new KaskadPriceOracleV2.AssetConfig[](1);
        c[0] = KaskadPriceOracleV2.AssetConfig(ETH_USD, 3, 1500, 3000);
        vm.prank(owner);
        oracle.registerAssets(c);

        checker = new MockStalenessWindow(WINDOW);
        gated = new KaskadStalenessGatedAggregatorV3(address(oracle), ETH_USD, "ETH / USD", address(checker));
        plain = new KaskadAggregatorV3(address(oracle), ETH_USD, "ETH / USD");
    }

    function _push(uint256 price) internal {
        uint256 ts = block.timestamp;
        bytes32 h = keccak256(abi.encodePacked(ETH_USD, price, ts, uint8(3), bytes32(uint256(1))));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)));
        oracle.updatePrice(ETH_USD, price, ts, 3, bytes32(uint256(1)), abi.encodePacked(r, s, v));
    }

    /// A fresh price passes through unchanged.
    function test_FreshPriceIsReturned() public {
        _push(2000e8);
        assertEq(gated.latestAnswer(), 2000e8);
    }

    /// The price is still served exactly at the window edge.
    function test_PriceAtWindowEdgeIsReturned() public {
        _push(2000e8);
        vm.warp(block.timestamp + WINDOW);
        assertEq(gated.latestAnswer(), 2000e8);
    }

    /// One second past the window `latestAnswer` reverts with the stored timestamp and window.
    function test_StalePriceReverts() public {
        _push(2000e8);
        uint256 ts = block.timestamp;
        vm.warp(ts + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(KaskadStalenessGatedAggregatorV3.StalePrice.selector, ts, WINDOW));
        gated.latestAnswer();
    }

    /// The window is read from the checker at call time, not cached.
    function test_WindowFollowsTheChecker() public {
        _push(2000e8);
        vm.warp(block.timestamp + 600);
        assertEq(gated.latestAnswer(), 2000e8);
        checker.setMaxStaleness(300);
        vm.expectRevert(
            abi.encodeWithSelector(KaskadStalenessGatedAggregatorV3.StalePrice.selector, block.timestamp - 600, 300)
        );
        gated.latestAnswer();
    }

    /// A new push after the window has passed reopens the feed.
    function test_RepushAfterStaleWindowRestoresTheAnswer() public {
        _push(2000e8);
        vm.warp(block.timestamp + WINDOW + 1);
        _push(2100e8);
        assertEq(gated.latestAnswer(), 2100e8);
    }

    /// An asset that was never priced reverts instead of reading as zero.
    function test_UnpricedAssetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(KaskadPriceOracleV2.NoPriceData.selector, ETH_USD));
        gated.latestAnswer();
    }

    /// Round reads stay ungated and match KaskadAggregatorV3 even when stale.
    function test_RoundReadsMatchThePlainAggregator() public {
        _push(2000e8);
        vm.warp(block.timestamp + 100);
        _push(2050e8);
        vm.warp(block.timestamp + WINDOW + 1);

        (uint80 r0, int256 a0, uint256 s0, uint256 u0, uint80 q0) = gated.latestRoundData();
        (uint80 r1, int256 a1, uint256 s1, uint256 u1, uint80 q1) = plain.latestRoundData();
        assertEq(abi.encode(r0, a0, s0, u0, q0), abi.encode(r1, a1, s1, u1, q1));
        assertEq(r0, 2);
        assertEq(a0, 2050e8);

        for (uint80 i = 1; i <= 2; i++) {
            (r0, a0, s0, u0, q0) = gated.getRoundData(i);
            (r1, a1, s1, u1, q1) = plain.getRoundData(i);
            assertEq(abi.encode(r0, a0, s0, u0, q0), abi.encode(r1, a1, s1, u1, q1));
            assertEq(gated.getAnswer(i), plain.getAnswer(i));
            assertEq(gated.getTimestamp(i), plain.getTimestamp(i));
        }
        assertEq(gated.latestRound(), plain.latestRound());
        assertEq(gated.latestTimestamp(), plain.latestTimestamp());
        assertEq(gated.decimals(), plain.decimals());
        assertEq(gated.version(), plain.version());
        assertEq(gated.description(), plain.description());
        assertEq(gated.assetId(), plain.assetId());
        assertEq(address(gated.oracle()), address(plain.oracle()));
        assertEq(address(gated.stalenessChecker()), address(checker));
    }

    /// Round ids above uint80 are rejected rather than truncated.
    function test_RoundIdOverflowReverts() public {
        uint256 big = uint256(type(uint80).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(KaskadStalenessGatedAggregatorV3.RoundIdOverflow.selector, big));
        gated.getAnswer(big);
        vm.expectRevert(abi.encodeWithSelector(KaskadStalenessGatedAggregatorV3.RoundIdOverflow.selector, big));
        gated.getTimestamp(big);
    }
}
