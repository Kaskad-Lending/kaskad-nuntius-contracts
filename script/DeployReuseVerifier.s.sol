// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./Deploy.s.sol";

/// @notice Deploy a fresh KaskadPriceOracle + aggregators reusing an
///         already-deployed NitroProver (CertManager stays cached too).
///         A NEW NitroAttestationVerifier is deployed with the current
///         PCR1 / PCR2 values — that's the only part of the verifier
///         stack that needs to rotate when the enclave EIF changes.
///
/// Required env (in addition to base Deploy):
///   EXISTING_PROVER     — address of deployed NitroProver
///   EXPECTED_PCR1       — current PCR1 (kernel hash)
///   EXPECTED_PCR2       — current PCR2 (application hash)
contract DeployReuseVerifier is Deploy {
    function _buildVerifier() internal override returns (IAttestationVerifier) {
        address existingProver = vm.envAddress("EXISTING_PROVER");
        require(existingProver != address(0), "EXISTING_PROVER == 0");

        bytes32 expectedPCR1 = vm.envBytes32("EXPECTED_PCR1");
        bytes32 expectedPCR2 = vm.envBytes32("EXPECTED_PCR2");
        require(expectedPCR1 != bytes32(0), "EXPECTED_PCR1 == 0");
        require(expectedPCR2 != bytes32(0), "EXPECTED_PCR2 == 0");

        console.log("Reusing NitroProver:", existingProver);

        NitroAttestationVerifier v =
            new NitroAttestationVerifier(existingProver, expectedPCR1, expectedPCR2);
        console.log("NitroAttestationVerifier (new):", address(v));
        return IAttestationVerifier(address(v));
    }
}
