// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {NitroProver} from "nitro-prover/NitroProver.sol";
import {CBORDecoding} from "marlinprotocol/solidity-cbor/CBORDecoding.sol";
import {ByteParser} from "marlinprotocol/solidity-cbor/ByteParser.sol";

import {IAttestationVerifier} from "./IAttestationVerifier.sol";

/// @title NitroAttestationVerifierV2
/// @notice On-chain AWS Nitro attestation verification over Marlin's NitroProver.
///         Carries no measurement of its own: PCR0 already hashes the whole EIF
///         (kernel, both ramdisks, application), so the caller pins PCR0 and this
///         contract never needs replacing when the image changes.
contract NitroAttestationVerifierV2 is IAttestationVerifier {
    error InvalidPCR0Length(uint256 length);
    error PCR0NotFound();
    error InvalidPublicKeyLength(uint256 length);
    error ZeroAddress();

    /// @notice Marlin NitroProver (CBOR/COSE/P-384 and the cached cert chain).
    NitroProver public immutable nitroProver;

    /// @notice Attestation age ceiling. AWS Nitro leaf certs live ~3 h, so anything
    ///         older is a replay; the extra hour absorbs chain clock drift.
    uint256 public constant MAX_ATTESTATION_AGE = 4 hours;

    constructor(address _nitroProver) {
        if (_nitroProver == address(0)) revert ZeroAddress();
        nitroProver = NitroProver(_nitroProver);
    }

    /// @inheritdoc IAttestationVerifier
    function verifyAttestation(bytes calldata attestationDoc)
        external
        view
        override
        returns (bool valid, bytes32 pcr0, address enclaveAddress)
    {
        (bytes memory enclaveKey, , bytes memory rawPcrs) =
            nitroProver.verifyAttestation(attestationDoc, MAX_ATTESTATION_AGE);

        pcr0 = _extractPcr0(rawPcrs);
        enclaveAddress = _deriveAddress(enclaveKey);
        valid = true;
    }

    /// @notice Cache the attestation's certificate chain. Must run before the first
    ///         `verifyAttestation` of a chain; on gas-capped chains, one cert per tx.
    function verifyCerts(bytes calldata attestationDoc) external {
        nitroProver.verifyCerts(attestationDoc);
    }

    /// @dev PCR map is `{ 0: <48B>, 1: <48B>, ... }`; the SHA-384 digest is truncated
    ///      to its first 32 bytes, which is what callers pin.
    function _extractPcr0(bytes memory rawPcrs) internal view returns (bytes32 pcr0) {
        bytes[2][] memory pcrs = CBORDecoding.decodeMapping(rawPcrs);

        for (uint256 i = 0; i < pcrs.length; i++) {
            if (ByteParser.bytesToUint64(pcrs[i][0]) != 0) continue;
            bytes memory pcrBytes = pcrs[i][1];
            if (pcrBytes.length != 48) revert InvalidPCR0Length(pcrBytes.length);
            assembly {
                pcr0 := mload(add(pcrBytes, 32))
            }
            return pcr0;
        }
        revert PCR0NotFound();
    }

    /// @dev keccak256 over the uncompressed key without its 0x04 prefix, last 20 bytes.
    function _deriveAddress(bytes memory publicKey) internal pure returns (address) {
        if (publicKey.length == 65) {
            bytes memory xy = new bytes(64);
            for (uint256 i = 0; i < 64; i++) {
                xy[i] = publicKey[i + 1];
            }
            return address(uint160(uint256(keccak256(xy))));
        } else if (publicKey.length == 64) {
            return address(uint160(uint256(keccak256(publicKey))));
        } else {
            revert InvalidPublicKeyLength(publicKey.length);
        }
    }
}
