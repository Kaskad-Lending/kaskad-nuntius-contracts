// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/KaskadPriceOracle.sol";
import "../src/KaskadAggregatorV3.sol";
import "./mocks/MockVerifiers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract KaskadPriceOracleTest is Test {
    KaskadPriceOracle oracle;
    KaskadAggregatorV3 ethAggregator;
    MockAttestationVerifier mockVerifier;

    bytes32 internal constant LOCAL_PCR0 = bytes32(uint256(0xDEADBEEF));

    uint256 internal signerPrivateKey;
    address internal signer;
    address internal owner = address(0xAD31);

    bytes32 internal constant ETH_USD = keccak256("ETH/USD");
    bytes32 internal constant BTC_USD = keccak256("BTC/USD");

    function setUp() public {
        vm.warp(1710000000);

        signerPrivateKey = 0xA11CE;
        signer = vm.addr(signerPrivateKey);

        mockVerifier = new MockAttestationVerifier(LOCAL_PCR0);
        oracle = new KaskadPriceOracle(LOCAL_PCR0, address(mockVerifier), owner);

        _registerEnclave(oracle, signer);

        bytes32[] memory ids = new bytes32[](2);
        uint8[] memory mins = new uint8[](2);
        ids[0] = ETH_USD; mins[0] = 3;
        ids[1] = BTC_USD; mins[1] = 3;
        _registerAssets(oracle, ids, mins);

        ethAggregator = new KaskadAggregatorV3(address(oracle), ETH_USD, "ETH / USD");
    }

    function _newOracle() internal returns (KaskadPriceOracle) {
        return new KaskadPriceOracle(LOCAL_PCR0, address(mockVerifier), owner);
    }

    function _registerEnclave(KaskadPriceOracle o, address s) internal {
        vm.prank(owner);
        o.registerEnclave(abi.encode(s));
    }

    function _registerAssets(
        KaskadPriceOracle o,
        bytes32[] memory ids,
        uint8[] memory mins
    ) internal {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j + 1 < n - i; j++) {
                if (uint256(ids[j]) > uint256(ids[j + 1])) {
                    (ids[j], ids[j + 1]) = (ids[j + 1], ids[j]);
                    (mins[j], mins[j + 1]) = (mins[j + 1], mins[j]);
                }
            }
        }
        vm.prank(owner);
        o.registerAssets(ids, mins);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _signUpdate(
        bytes32 assetId,
        uint256 price,
        uint256 timestamp,
        uint8 numSources,
        bytes32 sourcesHash
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(assetId, price, timestamp, numSources, sourcesHash)
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _submitPrice(
        bytes32 assetId,
        uint256 price,
        uint256 timestamp,
        uint8 numSources
    ) internal {
        bytes32 sourcesHash = keccak256("test_sources");
        bytes memory sig = _signUpdate(assetId, price, timestamp, numSources, sourcesHash);
        oracle.updatePrice(assetId, price, timestamp, numSources, sourcesHash, sig);
    }

    // ─── Owner / signer set ──────────────────────────────────────────

    function test_owner_is_admin() public view {
        assertEq(oracle.owner(), owner);
    }

    function test_validSigner_getter() public view {
        assertTrue(oracle.validSigner(signer));
        assertTrue(oracle.isValidSigner(signer));
        assertFalse(oracle.validSigner(address(0xDEAD)));
        assertEq(oracle.signerCount(), 1);
    }

    function test_constants() public view {
        assertEq(oracle.DECIMALS(), 8);
    }

    function test_immutables_set() public view {
        assertEq(oracle.expectedPCR0(), LOCAL_PCR0);
        assertEq(address(oracle.verifier()), address(mockVerifier));
    }

    // ─── Ownership Transfer (Ownable2Step) ───────────────────────────

    function test_transferOwnership_two_step_success() public {
        address newOwner = address(0xA0D1);

        vm.expectEmit(true, true, false, false);
        emit Ownable2Step.OwnershipTransferStarted(owner, newOwner);

        vm.prank(owner);
        oracle.transferOwnership(newOwner);

        assertEq(oracle.owner(), owner);
        assertEq(oracle.pendingOwner(), newOwner);

        vm.prank(newOwner);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), newOwner);
        assertEq(oracle.pendingOwner(), address(0));
    }

    function test_transferOwnership_reverts_not_owner() public {
        vm.prank(address(0xCAFE));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xCAFE))
        );
        oracle.transferOwnership(address(0xA0D1));
    }

    function test_acceptOwnership_reverts_wrong_caller() public {
        address newOwner = address(0xA0D1);
        vm.prank(owner);
        oracle.transferOwnership(newOwner);

        vm.prank(address(0xCAFE));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xCAFE))
        );
        oracle.acceptOwnership();
    }

    function test_old_owner_loses_registerAssets_after_transfer() public {
        address newOwner = address(0xA0D1);
        vm.prank(owner);
        oracle.transferOwnership(newOwner);
        vm.prank(newOwner);
        oracle.acceptOwnership();

        bytes32[] memory ids = new bytes32[](1);
        uint8[] memory mins = new uint8[](1);
        ids[0] = ETH_USD; mins[0] = 3;

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner)
        );
        oracle.registerAssets(ids, mins);

        vm.prank(newOwner);
        oracle.registerAssets(ids, mins);
        bytes32[] memory registered = oracle.registeredAssetIds();
        assertEq(registered.length, 1);
        assertEq(registered[0], ETH_USD);
    }

    // ─── Enclave Registration ────────────────────────────────────────

    function test_registerEnclave_success() public {
        KaskadPriceOracle fresh = _newOracle();

        vm.expectEmit(true, false, false, true);
        emit KaskadPriceOracle.EnclaveRegistered(signer, LOCAL_PCR0, block.timestamp);

        vm.prank(owner);
        fresh.registerEnclave(abi.encode(signer));

        assertTrue(fresh.validSigner(signer));
        assertEq(fresh.signerCount(), 1);
    }

    function test_registerEnclave_reverts_non_owner() public {
        KaskadPriceOracle fresh = _newOracle();
        vm.prank(address(0xCAFE));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xCAFE))
        );
        fresh.registerEnclave(abi.encode(signer));
    }

    function test_registerEnclave_reverts_invalid_attestation() public {
        FailingAttestationVerifier failingV = new FailingAttestationVerifier();
        KaskadPriceOracle fresh =
            new KaskadPriceOracle(LOCAL_PCR0, address(failingV), owner);

        vm.prank(owner);
        vm.expectRevert(KaskadPriceOracle.InvalidAttestation.selector);
        fresh.registerEnclave(abi.encode(signer));
    }

    function test_registerEnclave_reverts_pcr0_mismatch() public {
        WrongPCR0Verifier wrongV = new WrongPCR0Verifier(signer);
        KaskadPriceOracle fresh =
            new KaskadPriceOracle(LOCAL_PCR0, address(wrongV), owner);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                KaskadPriceOracle.PCR0Mismatch.selector,
                bytes32(uint256(0xDEAD)),
                LOCAL_PCR0
            )
        );
        fresh.registerEnclave(abi.encode(signer));
    }

    function test_registerEnclave_idempotent_on_duplicate() public {
        // Re-registering the same signer is a no-op — no revert, no event,
        // no count bump.
        uint256 countBefore = oracle.signerCount();
        _registerEnclave(oracle, signer);
        assertEq(oracle.signerCount(), countBefore);
        assertTrue(oracle.validSigner(signer));
    }

    function test_registerEnclave_multiple_signers() public {
        address signer2 = address(0xBEEF);
        _registerEnclave(oracle, signer2);

        assertTrue(oracle.validSigner(signer));
        assertTrue(oracle.validSigner(signer2));
        assertEq(oracle.signerCount(), 2);
    }

    function test_removeSigner_success() public {
        vm.expectEmit(true, false, false, true);
        emit KaskadPriceOracle.SignerRemoved(signer);

        vm.prank(owner);
        oracle.removeSigner(signer);

        assertFalse(oracle.validSigner(signer));
        assertEq(oracle.signerCount(), 0);
    }

    function test_removeSigner_reverts_non_owner() public {
        vm.prank(address(0xCAFE));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xCAFE))
        );
        oracle.removeSigner(signer);
    }

    function test_removeSigner_reverts_not_registered() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                KaskadPriceOracle.SignerNotRegistered.selector,
                address(0xBEEF)
            )
        );
        oracle.removeSigner(address(0xBEEF));
    }

    function test_removeSigner_invalidates_signatures() public {
        _submitPrice(ETH_USD, 212926000000, 1710000000, 4);

        vm.prank(owner);
        oracle.removeSigner(signer);

        vm.warp(1710000010);
        bytes32 sourcesHash = keccak256("test_sources");
        bytes memory sig = _signUpdate(ETH_USD, 213000000000, 1710000010, 4, sourcesHash);

        vm.expectRevert(KaskadPriceOracle.NoEnclaveRegistered.selector);
        oracle.updatePrice(ETH_USD, 213000000000, 1710000010, 4, sourcesHash, sig);
    }

    function test_removeSigner_keeps_other_signers_active() public {
        uint256 signer2Key = 0xBEEF1;
        address signer2 = vm.addr(signer2Key);

        _registerEnclave(oracle, signer2);

        vm.prank(owner);
        oracle.removeSigner(signer);
        assertEq(oracle.signerCount(), 1);
        assertTrue(oracle.validSigner(signer2));

        bytes32 sourcesHash = keccak256("test_sources");
        bytes32 messageHash = keccak256(
            abi.encodePacked(ETH_USD, uint256(212926000000), uint256(1710000000), uint8(4), sourcesHash)
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer2Key, ethSignedHash);
        oracle.updatePrice(
            ETH_USD,
            212926000000,
            1710000000,
            4,
            sourcesHash,
            abi.encodePacked(r, s, v)
        );

        (uint256 price, , , ) = oracle.getLatestPrice(ETH_USD);
        assertEq(price, 212926000000);
    }

    function test_registerEnclave_per_oracle_isolation() public {
        address otherSigner = address(0xBEEF);
        KaskadPriceOracle o = _newOracle();
        _registerEnclave(o, otherSigner);

        assertTrue(o.validSigner(otherSigner));
        assertFalse(o.validSigner(signer));
        assertEq(o.signerCount(), 1);
    }

    // ─── Price Updates ───────────────────────────────────────────────

    function test_updatePrice_valid() public {
        uint256 price = 212926000000;
        uint256 ts = 1710000000;
        uint8 sources = 4;
        bytes32 sourcesHash = keccak256("test_sources");

        bytes memory sig = _signUpdate(ETH_USD, price, ts, sources, sourcesHash);

        vm.expectEmit(true, false, false, true);
        emit KaskadPriceOracle.PriceUpdated(ETH_USD, price, ts, sources, 1);

        oracle.updatePrice(ETH_USD, price, ts, sources, sourcesHash, sig);

        (uint256 storedPrice, uint256 storedTs, uint8 storedSources, uint80 roundId) =
            oracle.getLatestPrice(ETH_USD);
        assertEq(storedPrice, price);
        assertEq(storedTs, ts);
        assertEq(storedSources, sources);
        assertEq(roundId, 1);
    }

    function test_updatePrice_increments_roundId() public {
        _submitPrice(ETH_USD, 212926000000, 1710000000, 4);
        vm.warp(1710000010);
        _submitPrice(ETH_USD, 213000000000, 1710000010, 5);
        vm.warp(1710000020);
        _submitPrice(ETH_USD, 213100000000, 1710000020, 3);

        (, , , uint80 roundId) = oracle.getLatestPrice(ETH_USD);
        assertEq(roundId, 3);
    }

    function test_updatePrice_multiple_assets() public {
        _submitPrice(ETH_USD, 212926000000, 1710000000, 4);
        _submitPrice(BTC_USD, 7173690000000, 1710000001, 5);

        (uint256 ethPrice, , , ) = oracle.getLatestPrice(ETH_USD);
        (uint256 btcPrice, , , ) = oracle.getLatestPrice(BTC_USD);

        assertEq(ethPrice, 212926000000);
        assertEq(btcPrice, 7173690000000);
    }

    function test_updatePrice_history() public {
        _submitPrice(ETH_USD, 100000000000, 1710000000, 3);
        vm.warp(1710000010);
        _submitPrice(ETH_USD, 100100000000, 1710000010, 4);

        (uint256 price1, uint256 ts1, ) = oracle.getRoundData(ETH_USD, 1);
        assertEq(price1, 100000000000);
        assertEq(ts1, 1710000000);

        (uint256 price2, , , ) = oracle.getLatestPrice(ETH_USD);
        assertEq(price2, 100100000000);
    }

    // ─── Rejections ──────────────────────────────────────────────────

    function test_updatePrice_reverts_no_enclave() public {
        KaskadPriceOracle unregistered = _newOracle();

        uint256 ts = block.timestamp;
        bytes32 sourcesHash = keccak256("test");
        bytes memory sig = _signUpdate(ETH_USD, 100, ts, 3, sourcesHash);

        vm.expectRevert(KaskadPriceOracle.NoEnclaveRegistered.selector);
        unregistered.updatePrice(ETH_USD, 100, ts, 3, sourcesHash, sig);
    }

    function test_updatePrice_reverts_invalid_signature() public {
        uint256 wrongKey = 0xBAD;
        uint256 ts = block.timestamp;
        bytes32 sourcesHash = keccak256("test");
        bytes32 messageHash = keccak256(
            abi.encodePacked(ETH_USD, uint256(100), ts, uint8(3), sourcesHash)
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);

        vm.expectRevert(KaskadPriceOracle.InvalidSignature.selector);
        oracle.updatePrice(ETH_USD, 100, ts, 3, sourcesHash, abi.encodePacked(r, s, v));
    }

    function test_updatePrice_reverts_stale_timestamp() public {
        _submitPrice(ETH_USD, 212926000000, 1710000000, 4);

        vm.warp(1710000010);
        bytes32 sourcesHash = keccak256("test_sources");
        bytes memory sig = _signUpdate(ETH_USD, 212900000000, 1709999999, 4, sourcesHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                KaskadPriceOracle.StalePrice.selector,
                uint256(1709999999),
                uint256(1710000000)
            )
        );
        oracle.updatePrice(ETH_USD, 212900000000, 1709999999, 4, sourcesHash, sig);
    }

    function test_updatePrice_reverts_short_signature() public {
        uint256 ts = block.timestamp;
        vm.expectRevert();
        oracle.updatePrice(ETH_USD, 100, ts, 3, bytes32(0), hex"aabbcc");
    }

    // ─── Circuit Breaker ─────────────────────────────────────────────

    function test_circuit_breaker_rejects_extreme_price_change() public {
        _submitPrice(ETH_USD, 100000000000, 1710000000, 4);

        vm.warp(1710000010);
        bytes32 sourcesHash = keccak256("test_sources");
        bytes memory sig = _signUpdate(ETH_USD, 120000000000, 1710000010, 4, sourcesHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                KaskadPriceOracle.PriceChangeExceedsLimit.selector,
                uint256(2000),
                uint256(1500)
            )
        );
        oracle.updatePrice(ETH_USD, 120000000000, 1710000010, 4, sourcesHash, sig);
    }

    function test_circuit_breaker_allows_normal_price_change() public {
        _submitPrice(ETH_USD, 100000000000, 1710000000, 4);

        vm.warp(1710000010);
        _submitPrice(ETH_USD, 110000000000, 1710000010, 4);

        (uint256 price, , , ) = oracle.getLatestPrice(ETH_USD);
        assertEq(price, 110000000000);
    }

    function test_circuit_breaker_first_update_no_limit() public {
        _submitPrice(ETH_USD, 999999000000, 1710000000, 4);

        (uint256 price, , , ) = oracle.getLatestPrice(ETH_USD);
        assertEq(price, 999999000000);
    }

    // ─── Rate Limiter ────────────────────────────────────────────────

    function test_rapid_updates_allowed() public {
        _submitPrice(ETH_USD, 100000000000, 1710000000, 4);

        vm.warp(1710000010);
        _submitPrice(ETH_USD, 100010000000, 1710000010, 4);

        (uint256 price, , , ) = oracle.getLatestPrice(ETH_USD);
        assertEq(price, 100010000000);
    }

    // ─── AggregatorV3 Wrapper ────────────────────────────────────────

    function test_aggregator_latestRoundData() public {
        _submitPrice(ETH_USD, 212926000000, 1710000000, 4);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            ethAggregator.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answer, int256(uint256(212926000000)));
        assertEq(startedAt, 1710000000);
        assertEq(updatedAt, 1710000000);
        assertEq(answeredInRound, 1);
    }

    function test_aggregator_latestAnswer() public {
        _submitPrice(ETH_USD, 212926000000, 1710000000, 4);
        assertEq(ethAggregator.latestAnswer(), int256(uint256(212926000000)));
    }

    function test_aggregator_decimals() public view {
        assertEq(ethAggregator.decimals(), 8);
    }

    function test_aggregator_description() public view {
        assertEq(ethAggregator.description(), "ETH / USD");
    }

    // ─── Circuit Breaker: Staleness Bypass ─────────────────────────

    function test_circuit_breaker_resume_allows_25pct_with_doubled_quorum() public {
        _submitPrice(ETH_USD, 100000000000, 1710000000, 6);

        vm.warp(1710000000 + 5 hours);
        uint256 ts = block.timestamp;
        _submitPrice(ETH_USD, 125000000000, ts, 6);

        (uint256 price, , , ) = oracle.getLatestPrice(ETH_USD);
        assertEq(price, 125000000000);
    }

    function test_circuit_breaker_resume_rejects_40pct_even_with_quorum() public {
        _submitPrice(ETH_USD, 100000000000, 1710000000, 6);

        vm.warp(1710000000 + 5 hours);
        uint256 ts = block.timestamp;

        bytes32 sourcesHash = keccak256("test_sources");
        bytes memory sig = _signUpdate(ETH_USD, 140000000000, ts, 6, sourcesHash);
        vm.expectRevert(
            abi.encodeWithSelector(
                KaskadPriceOracle.PriceChangeExceedsLimit.selector,
                uint256(4000),
                uint256(3000)
            )
        );
        oracle.updatePrice(ETH_USD, 140000000000, ts, 6, sourcesHash, sig);
    }

    function test_circuit_breaker_resume_no_extra_quorum() public {
        _submitPrice(ETH_USD, 100000000000, 1710000000, 6);

        vm.warp(1710000000 + 5 hours);
        uint256 ts = block.timestamp;
        bytes32 sourcesHash = keccak256("test_sources");
        bytes memory sig = _signUpdate(ETH_USD, 125000000000, ts, 3, sourcesHash);
        oracle.updatePrice(ETH_USD, 125000000000, ts, 3, sourcesHash, sig);

        (uint256 p, , uint8 n, ) = oracle.getLatestPrice(ETH_USD);
        assertEq(p, 125000000000);
        assertEq(n, 3);
    }

    function test_circuit_breaker_NOT_bypassed_within_staleness() public {
        _submitPrice(ETH_USD, 100000000000, 1710000000, 4);

        // Stay strictly inside the CIRCUIT_BREAKER_STALENESS window
        // (1 h) so the tight 15 % cap is still in effect.
        vm.warp(1710000000 + 30 minutes);
        uint256 ts = block.timestamp;

        bytes32 sourcesHash = keccak256("test_sources");
        bytes memory sig = _signUpdate(ETH_USD, 150000000000, ts, 4, sourcesHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                KaskadPriceOracle.PriceChangeExceedsLimit.selector,
                uint256(5000),
                uint256(1500)
            )
        );
        oracle.updatePrice(ETH_USD, 150000000000, ts, 4, sourcesHash, sig);
    }

    // ─── Future Timestamp Boundary ──────────────────────────────────

    function test_future_timestamp_at_boundary_allowed() public {
        uint256 ts = block.timestamp + 5 minutes;
        _submitPrice(ETH_USD, 212926000000, ts, 4);

        (uint256 price, , , ) = oracle.getLatestPrice(ETH_USD);
        assertEq(price, 212926000000);
    }

    function test_future_timestamp_allowed() public {
        uint256 ts = block.timestamp + 1 hours;
        _submitPrice(ETH_USD, 212926000000, ts, 4);

        (uint256 price, , , ) = oracle.getLatestPrice(ETH_USD);
        assertEq(price, 212926000000);
    }

    // ─── Uninitialized Asset ────────────────────────────────────────

    function test_getLatestPrice_reverts_uninitialized() public {
        bytes32 unknownAsset = keccak256("UNKNOWN/USD");
        vm.expectRevert(
            abi.encodeWithSelector(KaskadPriceOracle.NoPriceData.selector, unknownAsset)
        );
        oracle.getLatestPrice(unknownAsset);
    }

    // ─── Zero Sources ───────────────────────────────────────────────

    function test_updatePrice_reverts_zero_sources() public {
        uint256 ts = block.timestamp;
        bytes32 sourcesHash = keccak256("test_sources");
        bytes memory sig = _signUpdate(ETH_USD, 100, ts, 0, sourcesHash);

        vm.expectRevert(KaskadPriceOracle.InsufficientSources.selector);
        oracle.updatePrice(ETH_USD, 100, ts, 0, sourcesHash, sig);
    }

    // ─── Replay Same Timestamp ──────────────────────────────────────

    function test_updatePrice_reverts_replay_same_timestamp() public {
        _submitPrice(ETH_USD, 100000000000, 1710000000, 4);

        vm.warp(1710000010);
        bytes32 sourcesHash = keccak256("test_sources");
        bytes memory sig = _signUpdate(ETH_USD, 100010000000, 1710000000, 4, sourcesHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                KaskadPriceOracle.StalePrice.selector,
                uint256(1710000000),
                uint256(1710000000)
            )
        );
        oracle.updatePrice(ETH_USD, 100010000000, 1710000000, 4, sourcesHash, sig);
    }

    // ─── Circuit Breaker: Price Decrease ─────────────────────────────

    function test_circuit_breaker_rejects_extreme_price_decrease() public {
        _submitPrice(ETH_USD, 100000000000, 1710000000, 4);

        vm.warp(1710000010);
        bytes32 sourcesHash = keccak256("test_sources");
        bytes memory sig = _signUpdate(ETH_USD, 80000000000, 1710000010, 4, sourcesHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                KaskadPriceOracle.PriceChangeExceedsLimit.selector,
                uint256(2000),
                uint256(1500)
            )
        );
        oracle.updatePrice(ETH_USD, 80000000000, 1710000010, 4, sourcesHash, sig);
    }

    // ─── AggregatorV3: getAnswer / getTimestamp ─────────────────────

    function test_aggregator_getAnswer() public {
        _submitPrice(ETH_USD, 212926000000, 1710000000, 4);
        assertEq(ethAggregator.getAnswer(1), int256(uint256(212926000000)));
    }

    function test_aggregator_getTimestamp() public {
        _submitPrice(ETH_USD, 212926000000, 1710000000, 4);
        assertEq(ethAggregator.getTimestamp(1), 1710000000);
    }

    function test_aggregator_roundId_overflow_reverts() public {
        uint256 overflowId = uint256(type(uint80).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(KaskadAggregatorV3.RoundIdOverflow.selector, overflowId)
        );
        ethAggregator.getAnswer(overflowId);
    }

    function test_aggregator_getRoundData() public {
        _submitPrice(ETH_USD, 212926000000, 1710000000, 4);
        vm.warp(1710000010);
        _submitPrice(ETH_USD, 213000000000, 1710000010, 5);

        (uint80 roundId, int256 answer, , uint256 updatedAt, ) =
            ethAggregator.getRoundData(2);
        assertEq(roundId, 2);
        assertEq(answer, int256(uint256(213000000000)));
        assertEq(updatedAt, 1710000010);
    }

    // ─── Gas Benchmark ───────────────────────────────────────────────

    function test_gas_updatePrice() public {
        bytes32 sourcesHash = keccak256("test");
        bytes memory sig = _signUpdate(ETH_USD, 212926000000, 1710000000, 4, sourcesHash);

        uint256 gasBefore = gasleft();
        oracle.updatePrice(ETH_USD, 212926000000, 1710000000, 4, sourcesHash, sig);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 320_000);
        emit log_named_uint("updatePrice gas (cold)", gasUsed);
    }

    function test_gas_registerEnclave() public {
        KaskadPriceOracle fresh = _newOracle();

        vm.prank(owner);
        uint256 gasBefore = gasleft();
        fresh.registerEnclave(abi.encode(signer));
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 200_000);
        emit log_named_uint("registerEnclave gas", gasUsed);
    }
}

// ─── E2E: Full Relayer Flow ──────────────────────────────────────────────

contract RelayerE2ETest is Test {
    KaskadPriceOracle oracle;
    MockAttestationVerifier mockVerifier;

    KaskadAggregatorV3 ethAgg;
    KaskadAggregatorV3 btcAgg;
    KaskadAggregatorV3 kasAgg;
    KaskadAggregatorV3 usdcAgg;
    KaskadAggregatorV3 igraAgg;

    bytes32 internal constant LOCAL_PCR0 = bytes32(uint256(0xDEADBEEF));

    uint256 internal signerPk;
    address internal signerAddr;

    address internal relayer = address(0xBE1A);
    address internal owner = address(0xAD31);

    bytes32 internal constant ETH_USD  = keccak256("ETH/USD");
    bytes32 internal constant BTC_USD  = keccak256("BTC/USD");
    bytes32 internal constant KAS_USD  = keccak256("KAS/USD");
    bytes32 internal constant USDC_USD = keccak256("USDC/USD");
    bytes32 internal constant IGRA_USD = keccak256("IGRA/USD");

    uint256 internal constant T0 = 1710000000;

    function setUp() public {
        vm.warp(T0);

        signerPk = 0xA11CE;
        signerAddr = vm.addr(signerPk);

        mockVerifier = new MockAttestationVerifier(LOCAL_PCR0);
        oracle = new KaskadPriceOracle(LOCAL_PCR0, address(mockVerifier), owner);
        vm.prank(owner);
        oracle.registerEnclave(abi.encode(signerAddr));

        bytes32[] memory ids = new bytes32[](5);
        uint8[] memory mins = new uint8[](5);
        ids[0] = ETH_USD;  mins[0] = 3;
        ids[1] = BTC_USD;  mins[1] = 3;
        ids[2] = KAS_USD;  mins[2] = 3;
        ids[3] = USDC_USD; mins[3] = 2;
        ids[4] = IGRA_USD; mins[4] = 1;
        _registerAssetsOnto(oracle, ids, mins);

        ethAgg  = new KaskadAggregatorV3(address(oracle), ETH_USD,  "ETH / USD");
        btcAgg  = new KaskadAggregatorV3(address(oracle), BTC_USD,  "BTC / USD");
        kasAgg  = new KaskadAggregatorV3(address(oracle), KAS_USD,  "KAS / USD");
        usdcAgg = new KaskadAggregatorV3(address(oracle), USDC_USD, "USDC / USD");
        igraAgg = new KaskadAggregatorV3(address(oracle), IGRA_USD, "IGRA / USD");
    }

    function _registerAssetsOnto(
        KaskadPriceOracle o,
        bytes32[] memory ids,
        uint8[] memory mins
    ) internal {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j + 1 < n - i; j++) {
                if (uint256(ids[j]) > uint256(ids[j + 1])) {
                    (ids[j], ids[j + 1]) = (ids[j + 1], ids[j]);
                    (mins[j], mins[j + 1]) = (mins[j + 1], mins[j]);
                }
            }
        }
        vm.prank(owner);
        o.registerAssets(ids, mins);
    }

    function _sign(
        bytes32 assetId, uint256 price, uint256 ts, uint8 sources, bytes32 srcHash
    ) internal view returns (bytes memory) {
        bytes32 msgHash = keccak256(abi.encodePacked(assetId, price, ts, sources, srcHash));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _relayPrice(
        bytes32 assetId, uint256 price, uint256 ts, uint8 sources
    ) internal {
        bytes32 srcHash = keccak256(abi.encodePacked("sources_", assetId, ts));
        bytes memory sig = _sign(assetId, price, ts, sources, srcHash);
        vm.prank(relayer);
        oracle.updatePrice(assetId, price, ts, sources, srcHash, sig);
    }

    function test_e2e_round1_all_assets() public {
        _relayPrice(ETH_USD,   212926000000,  T0,   5);
        _relayPrice(BTC_USD,  7173690000000,  T0+1, 5);
        _relayPrice(KAS_USD,      11200000,   T0+2, 4);
        _relayPrice(USDC_USD,   100000000,    T0+3, 3);
        _relayPrice(IGRA_USD,    10000000,    T0+4, 3);

        (uint256 ethP, , uint8 ethS, uint80 ethR) = oracle.getLatestPrice(ETH_USD);
        assertEq(ethP, 212926000000);
        assertEq(ethS, 5);
        assertEq(ethR, 1);

        (uint256 btcP, , , ) = oracle.getLatestPrice(BTC_USD);
        assertEq(btcP, 7173690000000);

        (uint256 kasP, , , ) = oracle.getLatestPrice(KAS_USD);
        assertEq(kasP, 11200000);

        (uint256 usdcP, , , ) = oracle.getLatestPrice(USDC_USD);
        assertEq(usdcP, 100000000);

        (uint256 igraP, , , ) = oracle.getLatestPrice(IGRA_USD);
        assertEq(igraP, 10000000);

        assertEq(ethAgg.latestAnswer(),  int256(uint256(212926000000)));
        assertEq(btcAgg.latestAnswer(),  int256(uint256(7173690000000)));
        assertEq(kasAgg.latestAnswer(),  int256(uint256(11200000)));
        assertEq(usdcAgg.latestAnswer(), int256(uint256(100000000)));
        assertEq(igraAgg.latestAnswer(), int256(uint256(10000000)));
    }

    function test_e2e_round2_price_updates() public {
        _relayPrice(ETH_USD,  212926000000, T0,   5);
        _relayPrice(BTC_USD, 7173690000000, T0+1, 5);

        vm.warp(T0 + 30);

        _relayPrice(ETH_USD,  215481000000, T0+30, 5);
        _relayPrice(BTC_USD, 7137822000000, T0+31, 5);

        (, , , uint80 ethRound) = oracle.getLatestPrice(ETH_USD);
        (, , , uint80 btcRound) = oracle.getLatestPrice(BTC_USD);
        assertEq(ethRound, 2);
        assertEq(btcRound, 2);

        (uint256 ethR1Price, , ) = oracle.getRoundData(ETH_USD, 1);
        assertEq(ethR1Price, 212926000000);

        (, int256 ethLatest, , uint256 ethUpdatedAt, ) = ethAgg.latestRoundData();
        assertEq(ethLatest, int256(uint256(215481000000)));
        assertEq(ethUpdatedAt, T0 + 30);
    }

    function test_e2e_relayer_stale_skip() public {
        _relayPrice(ETH_USD, 212926000000, T0, 5);

        vm.warp(T0 + 30);

        (, uint256 onchainTs, , ) = oracle.getLatestPrice(ETH_USD);
        assertEq(onchainTs, T0);

        bytes32 srcHash = keccak256(abi.encodePacked("sources_", ETH_USD, T0));
        bytes memory sig = _sign(ETH_USD, 212926000000, T0, 5, srcHash);
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(KaskadPriceOracle.StalePrice.selector, T0, T0)
        );
        oracle.updatePrice(ETH_USD, 212926000000, T0, 5, srcHash, sig);
    }

    function test_e2e_circuit_breaker_then_ramped_resume() public {
        _relayPrice(ETH_USD, 100000000000, T0, 5);

        vm.warp(T0 + 30);
        bytes32 srcHash = keccak256(abi.encodePacked("sources_", ETH_USD, T0 + 30));
        bytes memory sig = _sign(ETH_USD, 70000000000, T0 + 30, 5, srcHash);
        vm.prank(relayer);
        vm.expectRevert();
        oracle.updatePrice(ETH_USD, 70000000000, T0 + 30, 5, srcHash, sig);

        vm.warp(T0 + 5 hours);
        uint256 ts = block.timestamp;
        _relayPrice(ETH_USD, 75000000000, ts, 3);

        (uint256 price, , , ) = oracle.getLatestPrice(ETH_USD);
        assertEq(price, 75000000000);
    }

    function test_e2e_duplicate_relayer_reverts() public {
        address relayer2 = address(0xBEEF);

        _relayPrice(ETH_USD, 212926000000, T0, 5);

        vm.warp(T0 + 10);

        bytes32 srcHash = keccak256(abi.encodePacked("sources_", ETH_USD, T0));
        bytes memory sig = _sign(ETH_USD, 212926000000, T0, 5, srcHash);

        vm.prank(relayer2);
        vm.expectRevert(
            abi.encodeWithSelector(KaskadPriceOracle.StalePrice.selector, T0, T0)
        );
        oracle.updatePrice(ETH_USD, 212926000000, T0, 5, srcHash, sig);
    }

    function test_e2e_five_round_lifecycle() public {
        uint256[5] memory prices = [
            uint256(212926000000),
            uint256(213200000000),
            uint256(212500000000),
            uint256(214000000000),
            uint256(213800000000)
        ];

        for (uint256 i = 0; i < 5; i++) {
            uint256 ts = T0 + (i * 30);
            vm.warp(ts);
            _relayPrice(ETH_USD, prices[i], ts, 5);
        }

        (uint256 latestPrice, uint256 latestTs, , uint80 latestRound) =
            oracle.getLatestPrice(ETH_USD);
        assertEq(latestPrice, 213800000000);
        assertEq(latestTs, T0 + 120);
        assertEq(latestRound, 5);

        for (uint256 i = 0; i < 5; i++) {
            (uint256 hp, , ) = oracle.getRoundData(ETH_USD, uint80(i + 1));
            assertEq(hp, prices[i]);
        }

        (, int256 answer, , , ) = ethAgg.latestRoundData();
        assertEq(answer, int256(uint256(213800000000)));
        assertEq(ethAgg.latestRound(), 5);
    }

    function test_e2e_fresh_oracle_rejects_foreign_signer() public {
        _relayPrice(ETH_USD, 212926000000, T0, 5);

        uint256 newPk = 0xBEEF1;
        address newAddr = vm.addr(newPk);
        KaskadPriceOracle fresh =
            new KaskadPriceOracle(LOCAL_PCR0, address(mockVerifier), owner);
        vm.prank(owner);
        fresh.registerEnclave(abi.encode(newAddr));
        assertTrue(fresh.validSigner(newAddr));
        assertFalse(fresh.validSigner(signerAddr));
        assertEq(fresh.signerCount(), 1);

        bytes32[] memory ids = new bytes32[](1);
        uint8[] memory mins = new uint8[](1);
        ids[0] = ETH_USD; mins[0] = 3;
        _registerAssetsOnto(fresh, ids, mins);

        bytes32 srcHash = keccak256("test");
        bytes memory oldSig = _sign(ETH_USD, 100, T0, 3, srcHash);
        vm.prank(relayer);
        vm.expectRevert(KaskadPriceOracle.InvalidSignature.selector);
        fresh.updatePrice(ETH_USD, 100, T0, 3, srcHash, oldSig);
    }
}
