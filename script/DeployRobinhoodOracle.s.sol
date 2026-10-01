// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KaskadPriceOracle.sol";
import "../src/NitroAttestationVerifier.sol";
import "nitro-prover/CertManager.sol";
import {NitroProver} from "nitro-prover/NitroProver.sol";

/// @notice Standalone Robinhood deploy of the keyex-genesis price oracle:
///         CertManager + NitroProver + NitroAttestationVerifier + a
///         KaskadPriceOracle bound to the build-time PCR0. NO registerEnclave /
///         registerAssets / aggregators — the enclave has not booted yet, so
///         there is no signer and no genesis attestation. Those are post-genesis
///         (RegisterOracleEnclave.s.sol).
///
///         Registry<->PCR0 circular bootstrap: the enclave bakes this oracle's
///         address into PCR0 as KEYEX_ORACLE_REGISTRY (it polls this address for
///         its genesis mint). The address is predicted off the deployer nonce
///         (CREATE address ignores constructor args, so it is independent of the
///         PCR0 it will carry — this is why CREATE, not CREATE2, breaks the
///         cycle) and asserted here: a mismatch reverts before any gas is spent.
///
/// Env:
///   EXPECTED_PCR0          — bytes32, from `nitro-cli describe-eif` at build. Non-zero.
///   EXPECTED_PCR1          — bytes32 kernel hash. Non-zero (audit D-2).
///   EXPECTED_PCR2          — bytes32 application hash. Non-zero (audit D-2).
///   KEYEX_ORACLE_REGISTRY  — address baked into the enclave; the oracle MUST land here.
///   ORACLE_OWNER           — address (optional; defaults to deployer). Ownable2Step admin.
///   DEPLOYER_KEY           — uint256 (optional if --private-key / --sender).
contract DeployRobinhoodOracle is Script {
    error WrongChain(uint256 chainid);
    error RegistryMismatch(address predicted, address baked);
    error OracleAddressMismatch(address deployed, address baked);

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        bytes32 expectedPCR0 = vm.envBytes32("EXPECTED_PCR0");
        bytes32 expectedPCR1 = vm.envBytes32("EXPECTED_PCR1");
        bytes32 expectedPCR2 = vm.envBytes32("EXPECTED_PCR2");
        address baked = vm.envAddress("KEYEX_ORACLE_REGISTRY");

        require(expectedPCR0 != bytes32(0), "EXPECTED_PCR0 == 0");
        require(expectedPCR1 != bytes32(0), "EXPECTED_PCR1 == 0 (audit D-2)");
        require(expectedPCR2 != bytes32(0), "EXPECTED_PCR2 == 0 (audit D-2)");
        require(baked != address(0), "KEYEX_ORACLE_REGISTRY == 0");

        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        address deployer = key != 0 ? vm.addr(key) : msg.sender;
        address owner = vm.envOr("ORACLE_OWNER", deployer);
        require(owner != address(0), "ORACLE_OWNER == 0");

        // Pre-flight: oracle is the deployer's 4th CREATE from here. Fail before
        // spending gas if the live nonce won't land it on the baked address.
        address predicted = vm.computeCreateAddress(deployer, uint256(vm.getNonce(deployer)) + 3);
        if (predicted != baked) revert RegistryMismatch(predicted, baked);

        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }

        CertManager certManager = new CertManager();
        console.log("CertManager:", address(certManager));

        NitroProver prover = new NitroProver(certManager);
        console.log("NitroProver:", address(prover));

        NitroAttestationVerifier verifier =
            new NitroAttestationVerifier(address(prover), expectedPCR1, expectedPCR2);
        console.log("NitroAttestationVerifier:", address(verifier));

        // Authoritative: the very next CREATE (the oracle) must land on the
        // baked address. getNonce here reflects the three CREATEs above.
        address next = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        if (next != baked) revert RegistryMismatch(next, baked);

        KaskadPriceOracle oracle = new KaskadPriceOracle(expectedPCR0, address(verifier), owner);
        console.log("KaskadPriceOracle:", address(oracle));

        vm.stopBroadcast();

        // ─── Post-deploy invariants ─────────────────────────────────────────
        if (address(oracle) != baked) revert OracleAddressMismatch(address(oracle), baked);
        require(oracle.expectedPCR0() == expectedPCR0, "expectedPCR0 not bound");
        require(address(oracle.verifier()) == address(verifier), "verifier not bound");
        require(oracle.owner() == owner, "owner not set");
        require(oracle.signerCount() == 0, "signerCount != 0 (must be pre-genesis)");
        require(verifier.nitroProver() == prover, "prover not bound");
        require(verifier.expectedPCR1() == expectedPCR1, "PCR1 not bound");
        require(verifier.expectedPCR2() == expectedPCR2, "PCR2 not bound");

        console.log("=== RH oracle at baked KEYEX_ORACLE_REGISTRY ===");
        console.log("oracle:", address(oracle));
        console.log("owner :", owner);
        console.log("next  : boot enclave -> genesis -> RegisterOracleEnclave.s.sol");
    }
}
