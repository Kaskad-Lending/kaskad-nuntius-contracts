// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KaskadPriceOracle.sol";
import "../src/NitroAttestationVerifier.sol";
import "nitro-prover/CertManager.sol";
import {NitroProver} from "nitro-prover/NitroProver.sol";

/// @notice Genesis keyex-signer registration for the RH oracle: warm the cert
///         chain one cert per tx (RH's 32M gas cap cannot fit bundled
///         verifyCerts), then registerEnclave(genesisDoc). Signer-only — price
///         asset quorums (registerAssets) are a separate later step, and
///         registerAssets itself requires signerCount != 0 first. EOA owner ->
///         direct broadcast; Safe owner -> prints calldata. Run only after the
///         enclave booted and minted its genesis candidate.
///
/// Env:
///   ORACLE           — deployed KaskadPriceOracle address.
///   GENESIS_DOC      — raw Nitro attestation bytes from the booted enclave.
///   CERT_CHAIN       — comma-separated certs: CA bundle without the root, then the leaf.
///   DIRECT_REGISTER  — bool; true broadcasts (EOA owner), false prints Safe calldata.
///   DEPLOYER_KEY     — uint256 (optional if --private-key / --sender).
contract RegisterOracleSigner is Script {
    error WrongChain(uint256 chainid);
    error InvalidAttestation();
    error SignerAlreadyRegistered(address signer);
    error Pcr0Mismatch(bytes32 provided, bytes32 expected);

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        KaskadPriceOracle oracle = KaskadPriceOracle(vm.envAddress("ORACLE"));
        bytes memory doc = vm.envBytes("GENESIS_DOC");
        bool directRegister = vm.envOr("DIRECT_REGISTER", false);
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));

        _warmCerts(oracle, key);
        address signer = _checkAttestation(oracle, doc);

        if (directRegister) {
            _broadcast(key);
            oracle.registerEnclave(doc);
            vm.stopBroadcast();
            console.log("registerEnclave done. signer:", signer);
            console.log("signerCount:", oracle.signerCount());
        } else {
            bytes memory d = abi.encodeCall(KaskadPriceOracle.registerEnclave, (doc));
            console.log("Safe tx registerEnclave -> :", address(oracle));
            console.log(vm.toString(d));
        }
    }

    /// @dev Walk CERT_CHAIN skipping certs CertManager already cached, parent
    ///      hash chained from ROOT_CA_CERT_HASH. Mirrors NitroProver.verifyCerts
    ///      but one tx per cert so each fits RH's per-tx gas cap.
    function _warmCerts(KaskadPriceOracle oracle, uint256 key) internal {
        bytes[] memory certChain = vm.envBytes("CERT_CHAIN", ",");
        NitroProver prover = NitroAttestationVerifier(address(oracle.verifier())).nitroProver();
        CertManager certManager = prover.certManager();

        bytes32 parentHash = certManager.ROOT_CA_CERT_HASH();
        for (uint256 i = 0; i < certChain.length; i++) {
            bytes32 certHash = keccak256(certChain[i]);
            if (certManager.certPubKey(certHash).length == 0) {
                _broadcast(key);
                certManager.verifyCert(certChain[i], parentHash);
                vm.stopBroadcast();
                console.log("verifyCert broadcast, cert #", i);
            } else {
                console.log("verifyCert cached, skipped cert #", i);
            }
            parentHash = certHash;
        }
    }

    /// @dev Static (verifyAttestation is view): valid, PCR0 matches the oracle's
    ///      immutable expectation, signer not already registered.
    function _checkAttestation(KaskadPriceOracle oracle, bytes memory doc)
        internal
        view
        returns (address signer)
    {
        bool valid;
        bytes32 pcr0;
        (valid, pcr0, signer) = oracle.verifier().verifyAttestation(doc);
        if (!valid) revert InvalidAttestation();
        if (pcr0 != oracle.expectedPCR0()) revert Pcr0Mismatch(pcr0, oracle.expectedPCR0());
        if (oracle.isValidSigner(signer)) revert SignerAlreadyRegistered(signer);
        console.log("verifyAttestation OK, signer:", signer);
    }

    function _broadcast(uint256 key) internal {
        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }
    }
}
