// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KaskadPriceOracleV2.sol";
import "../src/NitroAttestationVerifierV2.sol";
import "nitro-prover/CertManager.sol";
import {NitroProver} from "nitro-prover/NitroProver.sol";

/// @notice Deploy the V2 keyex-genesis oracle stack: NitroAttestationVerifierV2
///         (PCR0-only) + KaskadPriceOracleV2. CertManager and NitroProver are
///         deployed fresh, or reused via EXISTING_PROVER to keep a warmed cert
///         cache. No registerEnclave / registerAssets — the enclave has not
///         booted yet.
///
///         Registry<->PCR0 circular bootstrap: the enclave bakes this oracle's
///         address into PCR0 as KEYEX_ORACLE_REGISTRY. The address is predicted
///         off the deployer nonce (CREATE ignores constructor args, which is why
///         CREATE and not CREATE2 breaks the cycle) and asserted before any gas
///         is spent.
///
/// Env:
///   EXPECTED_PCR0          — bytes32 from `nitro-cli describe-eif`. Non-zero.
///   KEYEX_ORACLE_REGISTRY  — address baked into the enclave; the oracle MUST land here.
///   EXISTING_PROVER        — address (optional); reuse this NitroProver and its cert cache.
///   ORACLE_OWNER           — address (optional; defaults to deployer). Ownable2Step admin.
///   DEPLOYER_KEY           — uint256 (optional if --private-key / --sender).
contract DeployOracleV2 is Script {
    error WrongChain(uint256 chainid);
    error RegistryMismatch(address predicted, address baked);
    error OracleAddressMismatch(address deployed, address baked);

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        bytes32 expectedPcr0 = vm.envBytes32("EXPECTED_PCR0");
        address baked = vm.envAddress("KEYEX_ORACLE_REGISTRY");
        address existingProver = vm.envOr("EXISTING_PROVER", address(0));

        require(expectedPcr0 != bytes32(0), "EXPECTED_PCR0 == 0");
        require(baked != address(0), "KEYEX_ORACLE_REGISTRY == 0");

        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        address deployer = key != 0 ? vm.addr(key) : msg.sender;
        address owner = vm.envOr("ORACLE_OWNER", deployer);
        require(owner != address(0), "ORACLE_OWNER == 0");

        // CREATEs before the oracle: 3 fresh (CertManager, NitroProver,
        // verifier) or 1 when the prover is reused.
        uint256 priorCreates = existingProver == address(0) ? 3 : 1;
        address predicted = vm.computeCreateAddress(deployer, uint256(vm.getNonce(deployer)) + priorCreates);
        if (predicted != baked) revert RegistryMismatch(predicted, baked);

        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }

        NitroProver prover;
        if (existingProver == address(0)) {
            CertManager certManager = new CertManager();
            console.log("CertManager:", address(certManager));
            prover = new NitroProver(certManager);
            console.log("NitroProver:", address(prover));
        } else {
            prover = NitroProver(existingProver);
            console.log("NitroProver (reused):", address(prover));
        }

        NitroAttestationVerifierV2 verifier = new NitroAttestationVerifierV2(address(prover));
        console.log("NitroAttestationVerifierV2:", address(verifier));

        // Authoritative: the very next CREATE must land on the baked address.
        address next = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        if (next != baked) revert RegistryMismatch(next, baked);

        KaskadPriceOracleV2 oracle = new KaskadPriceOracleV2(expectedPcr0, address(verifier), owner);
        console.log("KaskadPriceOracleV2:", address(oracle));

        vm.stopBroadcast();

        if (address(oracle) != baked) revert OracleAddressMismatch(address(oracle), baked);
        require(oracle.expectedPcr0() == expectedPcr0, "expectedPcr0 not bound");
        require(address(oracle.verifier()) == address(verifier), "verifier not bound");
        require(oracle.owner() == owner, "owner not set");
        require(oracle.signerCount() == 0, "signerCount != 0 (must be pre-genesis)");
        require(address(verifier.nitroProver()) == address(prover), "prover not bound");

        console.log("=== V2 oracle at baked KEYEX_ORACLE_REGISTRY ===");
        console.log("oracle:", address(oracle));
        console.log("owner :", owner);
        console.log("next  : boot enclave -> genesis -> RegisterOracleEnclaveV2.s.sol");
    }
}
