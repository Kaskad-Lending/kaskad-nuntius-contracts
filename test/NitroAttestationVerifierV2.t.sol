// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {NitroAttestationVerifierV2} from "../src/NitroAttestationVerifierV2.sol";

/// @dev Exposes the internals; the COSE/P-384 path above them is NitroProver's.
contract VerifierHarness is NitroAttestationVerifierV2 {
    constructor(address prover) NitroAttestationVerifierV2(prover) {}

    function extractPcr0(bytes memory rawPcrs) external view returns (bytes32) {
        return _extractPcr0(rawPcrs);
    }

    function deriveAddress(bytes memory publicKey) external pure returns (address) {
        return _deriveAddress(publicKey);
    }
}

contract NitroAttestationVerifierV2Test is Test {
    VerifierHarness harness;

    function setUp() public {
        harness = new VerifierHarness(address(0xBEEF));
    }

    /// @dev CBOR map of `count` entries `{ i: <48 bytes> }`, as NSM emits PCRs.
    function _pcrMap(uint8 count, bytes32[] memory heads) internal pure returns (bytes memory out) {
        require(count <= 23, "short-count only");
        out = abi.encodePacked(uint8(0xa0 + count));
        for (uint8 i = 0; i < count; i++) {
            bytes32 head = i < heads.length ? heads[i] : bytes32(uint256(0xFF00 + i));
            out = abi.encodePacked(out, i, uint8(0x58), uint8(48), head, bytes16(uint128(i + 1)));
        }
    }

    function _heads(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory h) {
        h = new bytes32[](3);
        (h[0], h[1], h[2]) = (a, b, c);
    }

    function test_ConstructorRejectsZeroProver() public {
        vm.expectRevert(NitroAttestationVerifierV2.ZeroAddress.selector);
        new VerifierHarness(address(0));
    }

    function test_ExtractsPcr0FromAFullSixteenEntryMap() public view {
        bytes32 pcr0 = keccak256("pcr0");
        bytes memory raw = _pcrMap(16, _heads(pcr0, keccak256("pcr1"), keccak256("pcr2")));
        assertEq(harness.extractPcr0(raw), pcr0);
    }

    /// The point of V2: a rebuilt image changes PCR1/PCR2 and the verifier does not care.
    function test_Pcr1AndPcr2AreIgnored() public view {
        bytes32 pcr0 = keccak256("pcr0");
        bytes32 a = harness.extractPcr0(_pcrMap(16, _heads(pcr0, keccak256("kernel-A"), keccak256("app-A"))));
        bytes32 b = harness.extractPcr0(_pcrMap(16, _heads(pcr0, keccak256("kernel-B"), keccak256("app-B"))));
        assertEq(a, pcr0);
        assertEq(b, pcr0);
    }

    function test_RevertsWhenPcr0IsAbsent() public {
        bytes memory raw = abi.encodePacked(uint8(0xa1), uint8(1), uint8(0x58), uint8(48), keccak256("x"), bytes16(0));
        vm.expectRevert(NitroAttestationVerifierV2.PCR0NotFound.selector);
        harness.extractPcr0(raw);
    }

    function test_RevertsOnAShortPcr0() public {
        bytes memory raw = abi.encodePacked(uint8(0xa1), uint8(0), uint8(0x58), uint8(32), keccak256("x"));
        vm.expectRevert(abi.encodeWithSelector(NitroAttestationVerifierV2.InvalidPCR0Length.selector, 32));
        harness.extractPcr0(raw);
    }

    function test_RevertsOnAMalformedPublicKey() public {
        vm.expectRevert(abi.encodeWithSelector(NitroAttestationVerifierV2.InvalidPublicKeyLength.selector, 33));
        harness.deriveAddress(new bytes(33));
    }

    function test_BothKeyEncodingsDeriveTheSameAddress() public view {
        bytes memory xy = new bytes(64);
        for (uint256 i = 0; i < 64; i++) xy[i] = bytes1(uint8(i + 1));
        bytes memory uncompressed = abi.encodePacked(uint8(0x04), xy);
        assertEq(harness.deriveAddress(xy), harness.deriveAddress(uncompressed));
        assertEq(harness.deriveAddress(xy), address(uint160(uint256(keccak256(xy)))));
    }

    function test_MaxAttestationAgeIsFourHours() public view {
        assertEq(harness.MAX_ATTESTATION_AGE(), 4 hours);
    }
}
