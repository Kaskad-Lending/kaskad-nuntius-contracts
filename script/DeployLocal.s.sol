// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./Deploy.s.sol";
import "../test/mocks/MockVerifiers.sol";

/// @notice Local/anvil deploy. Swaps the real Nitro stack for
///         MockAttestationVerifier so no AWS attestation is needed.
///         All other flow (registerEnclave + registerAssets + aggregators)
///         matches prod.
///
/// Required env:
///   DEPLOYER_KEY    — uint256 private key (or `--private-key` on CLI)
///
/// Optional env:
///   ORACLE_SIGNER   — enclave-signer address (defaults to Anvil acct #1).
///   LOCAL_PCR0      — bytes32 PCR0 baked into mock (defaults to keccak256("local-pcr0")).
contract DeployLocal is Deploy {
    address constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    function _localPCR0() internal view returns (bytes32) {
        return vm.envOr("LOCAL_PCR0", keccak256("local-pcr0"));
    }

    function _localSigner() internal view returns (address) {
        return vm.envOr("ORACLE_SIGNER", ANVIL_ACCOUNT_1);
    }

    function _buildVerifier() internal override returns (IAttestationVerifier) {
        MockAttestationVerifier mock = new MockAttestationVerifier(_localPCR0());
        console.log("MockAttestationVerifier:", address(mock));
        return IAttestationVerifier(address(mock));
    }

    function _getAttestationDoc() internal override returns (bytes memory) {
        return abi.encode(_localSigner());
    }

    function _cacheCerts(IAttestationVerifier, bytes memory) internal override {}

    function _validateEnv() internal override {}

    function _assertExpectedSigner(IAttestationVerifier, bytes memory) internal override {}
}
