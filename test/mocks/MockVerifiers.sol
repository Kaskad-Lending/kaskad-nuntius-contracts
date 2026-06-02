// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "../../src/KaskadPriceOracle.sol";

/// @title MockAttestationVerifier
/// @notice Mock verifier for testing. Accepts any attestation, returns the
///         pre-configured PCR0, and decodes the enclave signer from
///         `attestationDoc` (an abi-encoded `address`). Decoding the signer
///         from the doc — rather than hardcoding it — lets a single mock
///         register several enclave signers on testnet (e.g. multi-region
///         HA: one signer per region).
///         NEVER deploy this in production — it bypasses all security.
contract MockAttestationVerifier is IAttestationVerifier {
    bytes32 public pcr0;

    constructor(bytes32 _pcr0) {
        pcr0 = _pcr0;
    }

    function verifyAttestation(bytes calldata attestationDoc)
        external
        view
        override
        returns (bool valid, bytes32 _pcr0, address _enclaveAddress)
    {
        return (true, pcr0, abi.decode(attestationDoc, (address)));
    }
}

/// @title FailingAttestationVerifier
/// @notice Always-failing verifier for negative tests.
contract FailingAttestationVerifier is IAttestationVerifier {
    function verifyAttestation(bytes calldata)
        external
        pure
        override
        returns (bool valid, bytes32 _pcr0, address _enclaveAddress)
    {
        return (false, bytes32(0), address(0));
    }
}

/// @title WrongPCR0Verifier
/// @notice Returns valid attestation but with wrong PCR0 — tests PCR0 mismatch.
contract WrongPCR0Verifier is IAttestationVerifier {
    address public enclaveAddr;

    constructor(address _enclaveAddr) {
        enclaveAddr = _enclaveAddr;
    }

    function verifyAttestation(bytes calldata)
        external
        view
        override
        returns (bool valid, bytes32 _pcr0, address _enclaveAddress)
    {
        return (true, bytes32(uint256(0xDEAD)), enclaveAddr);
    }
}
