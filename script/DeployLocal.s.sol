// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./Deploy.s.sol";
import "../test/mocks/MockVerifiers.sol";

/// @notice Local/anvil deploy. Swaps the Nitro verifier stack for a
///         `MockAttestationVerifier` that returns a predetermined PCR0 and
///         decodes the enclave signer from the attestation doc. Everything
///         else — `registerEnclave`, `registerAssets`, aggregator
///         deployment — is inherited from `Deploy`, so local flow matches
///         prod flow.
///
/// Required env:
///   DEPLOYER_KEY    — uint256 private key (or `--private-key` on CLI)
///   ORACLE_SIGNER   — (optional) enclave-signer address the mock returns.
///                     Passed to the mock inside the attestation doc.
///                     Defaults to Anvil account #1.
contract DeployLocal is Deploy {
    /// @notice Fake PCR0 — must match what `MockAttestationVerifier`
    ///         returns. Local-only; prod derives the real one from the
    ///         attestation document.
    bytes32 constant LOCAL_PCR0 = keccak256("kaskad-oracle:local");

    address constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    function _buildVerifier() internal override returns (IAttestationVerifier) {
        MockAttestationVerifier verifier = new MockAttestationVerifier(LOCAL_PCR0);
        console.log("MockAttestationVerifier:", address(verifier));
        return IAttestationVerifier(address(verifier));
    }

    function _getAttestationDoc() internal view override returns (bytes memory) {
        // The mock decodes the enclave signer from the attestation doc.
        return abi.encode(vm.envOr("ORACLE_SIGNER", ANVIL_ACCOUNT_1));
    }

    function _cacheCerts(IAttestationVerifier, bytes memory) internal override {
        // Mock verifier has no cert chain to cache.
    }

    function _extractPCR0(IAttestationVerifier, bytes memory)
        internal
        pure
        override
        returns (bytes32)
    {
        return LOCAL_PCR0;
    }

    /// @notice Skip the prod env-validation gates (PCR1/PCR2). DeployLocal
    ///         uses a mock verifier with no PCR1/PCR2 inputs.
    function _validateEnv() internal pure override {
        // intentional no-op — see Deploy._validateEnv NatSpec.
    }
}
