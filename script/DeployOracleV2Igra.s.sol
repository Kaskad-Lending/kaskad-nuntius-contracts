// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KaskadPriceOracleV2.sol";
import "../src/NitroAttestationVerifierV2.sol";
import "nitro-prover/CertManager.sol";
import {NitroProver} from "nitro-prover/NitroProver.sol";

/// @notice Deploy the V2 oracle stack on Igra (38833): CertManager, NitroProver,
///         NitroAttestationVerifierV2 and KaskadPriceOracleV2 owned by the Igra Safe.
///         No KEYEX_ORACLE_REGISTRY guard: the Igra oracle registers an image that
///         is already built, so its own address is not part of PCR0.
///
/// Env:
///   EXPECTED_PCR0    — bytes32, the live enclave's PCR0 (first 32 bytes). Non-zero.
///   ORACLE_OWNER     — address (optional; defaults to the Igra Safe). Ownable2Step admin.
///   EXISTING_PROVER  — address (optional); reuse this NitroProver and its cert cache.
///   DEPLOYER_KEY     — uint256 (optional if --private-key / --sender).
contract DeployOracleV2Igra is Script {
    error WrongChain(uint256 chainid);

    uint256 internal constant IGRA_CHAIN_ID = 38833;
    address internal constant IGRA_SAFE = 0x5B95Ea5D5B63998467eE92B0b175ACE49ccC1943;

    function run() external returns (KaskadPriceOracleV2 oracle) {
        if (block.chainid != IGRA_CHAIN_ID) revert WrongChain(block.chainid);

        bytes32 expectedPcr0 = vm.envBytes32("EXPECTED_PCR0");
        address owner = vm.envOr("ORACLE_OWNER", IGRA_SAFE);
        address existingProver = vm.envOr("EXISTING_PROVER", address(0));
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));

        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }
        oracle = deploy(expectedPcr0, owner, existingProver);
        vm.stopBroadcast();

        console.log("=== V2 oracle on Igra ===");
        console.log("oracle:", address(oracle));
        console.log("owner :", owner);
        console.log("next  : RegisterOracleEnclaveV2.s.sol (Safe calldata) -> DeployIgraAggregators.s.sol");
    }

    /// @notice Deploys and checks the stack; callers own the broadcast scope.
    function deploy(bytes32 expectedPcr0, address owner, address existingProver)
        public
        returns (KaskadPriceOracleV2 oracle)
    {
        require(expectedPcr0 != bytes32(0), "EXPECTED_PCR0 == 0");
        require(owner != address(0), "ORACLE_OWNER == 0");

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

        oracle = new KaskadPriceOracleV2(expectedPcr0, address(verifier), owner);
        console.log("KaskadPriceOracleV2:", address(oracle));

        require(oracle.expectedPcr0() == expectedPcr0, "expectedPcr0 not bound");
        require(address(oracle.verifier()) == address(verifier), "verifier not bound");
        require(oracle.owner() == owner, "owner not set");
        require(oracle.signerCount() == 0, "signerCount != 0");
        require(address(verifier.nitroProver()) == address(prover), "prover not bound");
    }
}
