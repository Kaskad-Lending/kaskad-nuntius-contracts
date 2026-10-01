// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/NitroAttestationVerifier.sol";
import "nitro-prover/CertManager.sol";
import {NitroProver} from "nitro-prover/NitroProver.sol";

/// @notice Standalone verifier for the pontifex BRIDGE enclave: CertManager +
///         NitroProver + NitroAttestationVerifier pinning the BRIDGE image's
///         PCR1/PCR2. The bridge (kaskad-pontifex) vendors no prover source, so
///         its KskdEntry.VERIFIER must be deployed here and passed in as VERIFIER.
///         The bridge enclave (CID 17, Dockerfile.pontifex) has its own PCRs,
///         distinct from the oracle's (CID 16) — never reuse the oracle verifier.
///         PCR0 is NOT pinned here: it lives on KskdEntry.expectedPcr0, so the
///         verifier only enforces PCR1 (kernel) + PCR2 (application).
///
/// Env:
///   EXPECTED_PCR1      — bytes32 bridge kernel hash. Non-zero.
///   EXPECTED_PCR2      — bytes32 bridge application hash. Non-zero.
///   EXISTING_PROVER    — address (optional). Reuse this NitroProver instead of deploying
///                        one, so the oracle's warm CertManager covers the shared
///                        intermediates and only the bridge leaf needs a warm-up tx.
///   EXPECTED_VERIFIER  — address (optional). If set, deploy must land here (pre-commit guard).
///   DEPLOYER_KEY       — uint256 (optional if --private-key / --sender).
contract DeployBridgeVerifier is Script {
    error WrongChain(uint256 chainid);
    error VerifierAddressMismatch(address deployed, address expected);

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        bytes32 expectedPCR1 = vm.envBytes32("EXPECTED_PCR1");
        bytes32 expectedPCR2 = vm.envBytes32("EXPECTED_PCR2");
        require(expectedPCR1 != bytes32(0), "EXPECTED_PCR1 == 0");
        require(expectedPCR2 != bytes32(0), "EXPECTED_PCR2 == 0");

        address expectedVerifier = vm.envOr("EXPECTED_VERIFIER", address(0));
        address existingProver = vm.envOr("EXISTING_PROVER", address(0));
        require(existingProver == address(0) || existingProver.code.length != 0, "EXISTING_PROVER has no code");
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));

        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }

        NitroProver prover;
        if (existingProver != address(0)) {
            prover = NitroProver(existingProver);
            console.log("NitroProver (reused):", existingProver);
        } else {
            CertManager certManager = new CertManager();
            console.log("CertManager:", address(certManager));
            prover = new NitroProver(certManager);
            console.log("NitroProver:", address(prover));
        }

        NitroAttestationVerifier verifier =
            new NitroAttestationVerifier(address(prover), expectedPCR1, expectedPCR2);
        console.log("NitroAttestationVerifier:", address(verifier));

        vm.stopBroadcast();

        // ─── Post-deploy invariants ─────────────────────────────────────────
        if (expectedVerifier != address(0) && address(verifier) != expectedVerifier) {
            revert VerifierAddressMismatch(address(verifier), expectedVerifier);
        }
        require(verifier.nitroProver() == prover, "prover not bound");
        require(verifier.expectedPCR1() == expectedPCR1, "PCR1 not bound");
        require(verifier.expectedPCR2() == expectedPCR2, "PCR2 not bound");
        require(address(prover.certManager()) != address(0), "certManager not bound");

        console.log("=== bridge verifier ===");
        console.log("VERIFIER:", address(verifier));
        console.log("next    : pontifex RotateEntry.s.sol (VERIFIER=this) or DeployRobinhood.s.sol");
    }
}
