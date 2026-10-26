// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title IAttestationVerifier
/// @notice TEE attestation verification. Returns the measurement the caller pins
///         against and the Ethereum address derived from the enclave key.
interface IAttestationVerifier {
    function verifyAttestation(bytes calldata attestationDoc)
        external
        view
        returns (bool valid, bytes32 pcr0, address enclaveAddress);
}
