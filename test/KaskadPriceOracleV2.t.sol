// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {KaskadPriceOracleV2} from "../src/KaskadPriceOracleV2.sol";
import {KaskadAggregatorV3} from "../src/KaskadAggregatorV3.sol";
import {MockVerifierV2} from "./mocks/MockVerifiersV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract KaskadPriceOracleV2Test is Test {
    KaskadPriceOracleV2 oracle;
    MockVerifierV2 verifier;

    bytes32 internal constant PCR0_A = bytes32(uint256(0xA11));
    bytes32 internal constant PCR0_B = bytes32(uint256(0xB22));

    bytes32 internal constant ETH_USD = keccak256("ETH/USD");
    bytes32 internal constant TSLA_USD = keccak256("TSLA/USD");

    address internal owner = address(0xAD31);
    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    event ExpectedPcr0Set(bytes32 pcr0);
    event EnclaveRegistered(address indexed signer, bytes32 pcr0, uint256 timestamp);

    function setUp() public {
        vm.warp(1710000000);
        signer = vm.addr(signerKey);
        verifier = new MockVerifierV2(PCR0_A);
        oracle = new KaskadPriceOracleV2(PCR0_A, address(verifier), owner);
        _register(signer);
        _registerDefaultAssets();
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _register(address s) internal {
        vm.prank(owner);
        oracle.registerEnclave(abi.encode(s));
    }

    function _cfg(bytes32 id, uint8 minSources, uint16 maxBps, uint16 resumeBps)
        internal
        pure
        returns (KaskadPriceOracleV2.AssetConfig memory)
    {
        return KaskadPriceOracleV2.AssetConfig(id, minSources, maxBps, resumeBps);
    }

    /// @dev Two assets with deliberately different breaker bounds; sorted by id.
    function _registerDefaultAssets() internal {
        KaskadPriceOracleV2.AssetConfig[] memory c = new KaskadPriceOracleV2.AssetConfig[](2);
        (bytes32 lo, bytes32 hi) = ETH_USD < TSLA_USD ? (ETH_USD, TSLA_USD) : (TSLA_USD, ETH_USD);
        c[0] = lo == ETH_USD ? _cfg(ETH_USD, 3, 1500, 3000) : _cfg(TSLA_USD, 3, 2500, 5000);
        c[1] = hi == ETH_USD ? _cfg(ETH_USD, 3, 1500, 3000) : _cfg(TSLA_USD, 3, 2500, 5000);
        vm.prank(owner);
        oracle.registerAssets(c);
    }

    function _sign(bytes32 id, uint256 price, uint256 ts, uint8 n, bytes32 srcHash)
        internal
        view
        returns (bytes memory)
    {
        bytes32 h = keccak256(abi.encodePacked(id, price, ts, n, srcHash));
        bytes32 eth = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, eth);
        return abi.encodePacked(r, s, v);
    }

    function _push(bytes32 id, uint256 price, uint256 ts) internal {
        oracle.updatePrice(id, price, ts, 3, bytes32(uint256(1)), _sign(id, price, ts, 3, bytes32(uint256(1))));
    }

    // ─── PCR0 rotation ───────────────────────────────────────────────────

    /// A zero measurement would accept every image; the constructor refuses it.
    function test_ConstructorRejectsZeroPcr0() public {
        vm.expectRevert(KaskadPriceOracleV2.ZeroPCR0.selector);
        new KaskadPriceOracleV2(bytes32(0), address(verifier), owner);
    }

    function test_ConstructorPinsAndEmitsPcr0() public {
        vm.expectEmit(false, false, false, true);
        emit ExpectedPcr0Set(PCR0_B);
        KaskadPriceOracleV2 o = new KaskadPriceOracleV2(PCR0_B, address(verifier), owner);
        assertEq(o.expectedPcr0(), PCR0_B);
    }

    function test_SetExpectedPcr0OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        oracle.setExpectedPcr0(PCR0_B);
    }

    function test_SetExpectedPcr0RejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(KaskadPriceOracleV2.ZeroPCR0.selector);
        oracle.setExpectedPcr0(bytes32(0));
    }

    function test_SetExpectedPcr0StoresAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit ExpectedPcr0Set(PCR0_B);
        vm.prank(owner);
        oracle.setExpectedPcr0(PCR0_B);
        assertEq(oracle.expectedPcr0(), PCR0_B);
    }

    /// A rebuilt image is admitted without redeploying, and the live signer keeps working.
    function test_RotationAdmitsNewImageAndOverlapsTheOldSigner() public {
        address newSigner = address(0xBEEF);
        vm.prank(owner);
        oracle.setExpectedPcr0(PCR0_B);
        verifier.setPcr0(PCR0_B);

        _register(newSigner);

        assertTrue(oracle.isValidSigner(signer));
        assertTrue(oracle.isValidSigner(newSigner));
        assertEq(oracle.signerCount(), 2);

        vm.prank(owner);
        oracle.removeSigner(signer);
        assertFalse(oracle.isValidSigner(signer));
        assertEq(oracle.signerCount(), 1);
    }

    function test_RegisterEnclaveRejectsThePreviousImageAfterRotation() public {
        vm.prank(owner);
        oracle.setExpectedPcr0(PCR0_B);
        // verifier still reports PCR0_A — the old image.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaskadPriceOracleV2.PCR0Mismatch.selector, PCR0_A, PCR0_B));
        oracle.registerEnclave(abi.encode(address(0xBEEF)));
    }

    function test_RegisterEnclaveStaysOwnerGated() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        oracle.registerEnclave(abi.encode(address(0xBEEF)));
    }

    function test_RegisterEnclaveRejectsAnInvalidAttestation() public {
        verifier.setOk(false);
        vm.prank(owner);
        vm.expectRevert(KaskadPriceOracleV2.InvalidAttestation.selector);
        oracle.registerEnclave(abi.encode(address(0xBEEF)));
    }

    function test_ReRegisteringAKnownSignerIsANoOp() public {
        _register(signer);
        assertEq(oracle.signerCount(), 1);
    }

    // ─── per-asset circuit breaker ───────────────────────────────────────

    /// The same move passes on the equity bound and reverts on the major bound.
    function test_BreakerBoundIsPerAsset() public {
        _push(ETH_USD, 2000e8, block.timestamp);
        _push(TSLA_USD, 400e8, block.timestamp);

        vm.warp(block.timestamp + 60);
        // +20%: inside TSLA's 2500 bps, outside ETH's 1500 bps.
        _push(TSLA_USD, 480e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(KaskadPriceOracleV2.PriceChangeExceedsLimit.selector, 2000, 1500));
        _push(ETH_USD, 2400e8, block.timestamp);
    }

    function test_ResumeBoundAppliesOnlyAfterSilence() public {
        _push(TSLA_USD, 400e8, block.timestamp);

        vm.warp(block.timestamp + 60);
        // +40% while fresh: over the 2500 bps normal bound.
        vm.expectRevert(abi.encodeWithSelector(KaskadPriceOracleV2.PriceChangeExceedsLimit.selector, 4000, 2500));
        _push(TSLA_USD, 560e8, block.timestamp);

        vm.warp(block.timestamp + 1 hours);
        _push(TSLA_USD, 560e8, block.timestamp);
        (uint256 price,,,) = oracle.getLatestPrice(TSLA_USD);
        assertEq(price, 560e8);
    }

    function test_ResumeBoundIsStillBounded() public {
        _push(TSLA_USD, 400e8, block.timestamp);
        vm.warp(block.timestamp + 2 hours);
        // +60%: over TSLA's 5000 bps resume bound.
        vm.expectRevert(abi.encodeWithSelector(KaskadPriceOracleV2.PriceChangeExceedsLimit.selector, 6000, 5000));
        _push(TSLA_USD, 640e8, block.timestamp);
    }

    function test_FirstPriceIsNotBreakerBound() public {
        _push(ETH_USD, 1e8, block.timestamp);
        (uint256 price,,,) = oracle.getLatestPrice(ETH_USD);
        assertEq(price, 1e8);
    }

    // ─── registerAssets validation ───────────────────────────────────────

    function _one(bytes32 id, uint8 m, uint16 a, uint16 b)
        internal
        pure
        returns (KaskadPriceOracleV2.AssetConfig[] memory c)
    {
        c = new KaskadPriceOracleV2.AssetConfig[](1);
        c[0] = KaskadPriceOracleV2.AssetConfig(id, m, a, b);
    }

    function test_RegisterAssetsRejectsZeroMinSources() public {
        vm.prank(owner);
        vm.expectRevert(KaskadPriceOracleV2.InvalidMinSources.selector);
        oracle.registerAssets(_one(ETH_USD, 0, 1500, 3000));
    }

    function test_RegisterAssetsRejectsZeroMaxChange() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaskadPriceOracleV2.InvalidChangeBps.selector, uint16(0), uint16(3000)));
        oracle.registerAssets(_one(ETH_USD, 3, 0, 3000));
    }

    function test_RegisterAssetsRejectsResumeBelowNormal() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaskadPriceOracleV2.InvalidChangeBps.selector, uint16(3000), uint16(1500)));
        oracle.registerAssets(_one(ETH_USD, 3, 3000, 1500));
    }

    function test_RegisterAssetsRejectsAboveCeiling() public {
        uint16 over = oracle.MAX_CHANGE_BPS_CEILING() + 1;
        bytes memory err = abi.encodeWithSelector(KaskadPriceOracleV2.InvalidChangeBps.selector, uint16(1500), over);
        vm.prank(owner);
        vm.expectRevert(err);
        oracle.registerAssets(_one(ETH_USD, 3, 1500, over));
    }

    function test_RegisterAssetsRejectsUnsorted() public {
        KaskadPriceOracleV2.AssetConfig[] memory c = new KaskadPriceOracleV2.AssetConfig[](2);
        (bytes32 lo, bytes32 hi) = ETH_USD < TSLA_USD ? (ETH_USD, TSLA_USD) : (TSLA_USD, ETH_USD);
        c[0] = _cfg(hi, 3, 1500, 3000);
        c[1] = _cfg(lo, 3, 1500, 3000);
        vm.prank(owner);
        vm.expectRevert(KaskadPriceOracleV2.AssetsUnsorted.selector);
        oracle.registerAssets(c);
    }

    function test_RegisterAssetsRejectsDuplicates() public {
        KaskadPriceOracleV2.AssetConfig[] memory c = new KaskadPriceOracleV2.AssetConfig[](2);
        c[0] = _cfg(ETH_USD, 3, 1500, 3000);
        c[1] = _cfg(ETH_USD, 3, 1500, 3000);
        vm.prank(owner);
        vm.expectRevert(KaskadPriceOracleV2.AssetsUnsorted.selector);
        oracle.registerAssets(c);
    }

    function test_RegisterAssetsRejectsEmpty() public {
        vm.prank(owner);
        vm.expectRevert(KaskadPriceOracleV2.AssetsEmpty.selector);
        oracle.registerAssets(new KaskadPriceOracleV2.AssetConfig[](0));
    }

    function test_RegisterAssetsRejectsAboveMaxAssets() public {
        uint256 max = oracle.MAX_ASSETS();
        uint256 n = max + 1;
        KaskadPriceOracleV2.AssetConfig[] memory c = new KaskadPriceOracleV2.AssetConfig[](n);
        for (uint256 i = 0; i < n; i++) c[i] = _cfg(bytes32(i + 1), 3, 1500, 3000);
        bytes memory err = abi.encodeWithSelector(KaskadPriceOracleV2.TooManyAssets.selector, n, max);
        vm.prank(owner);
        vm.expectRevert(err);
        oracle.registerAssets(c);
    }

    function test_RegisterAssetsNeedsASigner() public {
        KaskadPriceOracleV2 fresh = new KaskadPriceOracleV2(PCR0_A, address(verifier), owner);
        vm.prank(owner);
        vm.expectRevert(KaskadPriceOracleV2.NoEnclaveRegistered.selector);
        fresh.registerAssets(_one(ETH_USD, 3, 1500, 3000));
    }

    function test_RegisterAssetsOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        oracle.registerAssets(_one(ETH_USD, 3, 1500, 3000));
    }

    /// A rewrite drops the assets it omits, so the old quorum cannot linger.
    function test_RegisterAssetsWipesThePreviousSet() public {
        assertEq(oracle.registeredAssetIds().length, 2);
        vm.prank(owner);
        oracle.registerAssets(_one(ETH_USD, 4, 2000, 4000));

        assertEq(oracle.registeredAssetIds().length, 1);
        (uint8 minSources, uint16 maxBps, uint16 resumeBps) = oracle.assetParams(ETH_USD);
        assertEq(minSources, 4);
        assertEq(maxBps, 2000);
        assertEq(resumeBps, 4000);

        (uint8 goneMin,,) = oracle.assetParams(TSLA_USD);
        assertEq(goneMin, 0);
        vm.expectRevert(abi.encodeWithSelector(KaskadPriceOracleV2.AssetNotRegistered.selector, TSLA_USD));
        _push(TSLA_USD, 400e8, block.timestamp);
    }

    // ─── price path ──────────────────────────────────────────────────────

    /// A zero price would read as "no price" downstream while passing every other gate.
    function test_ZeroPriceIsRejected() public {
        vm.expectRevert(KaskadPriceOracleV2.ZeroPrice.selector);
        _push(ETH_USD, 0, block.timestamp);
    }

    function test_UpdateStoresAndTheAggregatorReadsIt() public {
        KaskadAggregatorV3 agg = new KaskadAggregatorV3(address(oracle), ETH_USD, "ETH / USD");
        _push(ETH_USD, 2000e8, block.timestamp);

        (uint80 round, int256 answer,, uint256 updatedAt,) = agg.latestRoundData();
        assertEq(round, 1);
        assertEq(answer, 2000e8);
        assertEq(updatedAt, block.timestamp);
        assertEq(agg.decimals(), oracle.DECIMALS());
    }

    function test_ReplayedSignedTimestampIsRejected() public {
        uint256 ts = block.timestamp;
        _push(ETH_USD, 2000e8, ts);
        vm.expectRevert(abi.encodeWithSelector(KaskadPriceOracleV2.StalePrice.selector, ts, ts));
        _push(ETH_USD, 2001e8, ts);
    }

    function test_FutureTimestampIsRejected() public {
        uint256 ts = block.timestamp + 2 hours + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                KaskadPriceOracleV2.FutureTimestamp.selector, ts, block.timestamp + oracle.MAX_FUTURE_SKEW()
            )
        );
        _push(ETH_USD, 2000e8, ts);
    }

    function test_BelowQuorumIsRejected() public {
        uint256 ts = block.timestamp;
        vm.expectRevert(KaskadPriceOracleV2.InsufficientSources.selector);
        oracle.updatePrice(ETH_USD, 2000e8, ts, 2, bytes32(uint256(1)), _sign(ETH_USD, 2000e8, ts, 2, bytes32(uint256(1))));
    }

    function test_UnknownSignerIsRejected() public {
        uint256 ts = block.timestamp;
        bytes32 h = keccak256(abi.encodePacked(ETH_USD, uint256(2000e8), ts, uint8(3), bytes32(uint256(1))));
        bytes32 eth = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(0xBAD), eth);
        vm.expectRevert(KaskadPriceOracleV2.InvalidSignature.selector);
        oracle.updatePrice(ETH_USD, 2000e8, ts, 3, bytes32(uint256(1)), abi.encodePacked(r, s, v));
    }

    function test_UpdateNeedsASigner() public {
        vm.prank(owner);
        oracle.removeSigner(signer);
        vm.expectRevert(KaskadPriceOracleV2.NoEnclaveRegistered.selector);
        _push(ETH_USD, 2000e8, block.timestamp);
    }
}
