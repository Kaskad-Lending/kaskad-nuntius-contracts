// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KaskadPriceOracle.sol";
import "../src/NitroAttestationVerifier.sol";
import "nitro-prover/CertManager.sol";
import {NitroProver} from "nitro-prover/NitroProver.sol";

/// @notice Post-genesis registration for the RH keyex oracle. Warms the
///         attestation cert chain one cert at a time (RH's 32M per-tx gas cap
///         cannot fit the bundled verifyCerts), then registerEnclave(genesisDoc)
///         + registerAssets(env commitment). EOA owner -> direct broadcast;
///         Safe owner -> prints calldata. Run only after the enclave has booted
///         and completed genesis (GENESIS_DOC = its attestation over the minted
///         signer key).
///
/// Env:
///   ORACLE             — deployed KaskadPriceOracle address.
///   GENESIS_DOC        — raw Nitro attestation bytes from the booted enclave.
///   CERT_CHAIN         — comma-separated certs: CA bundle without the root, then the leaf.
///   ASSET_IDS          — comma-separated bytes32 asset ids (keccak256(symbol)), strictly ascending.
///   ASSET_MIN_SOURCES  — comma-separated uint quorum per asset, 1..255, same length as ASSET_IDS.
///   DIRECT_REGISTER    — bool; true broadcasts (EOA owner), false prints Safe calldata.
///   DEPLOYER_KEY       — uint256 (optional if --private-key / --sender).
contract RegisterOracleEnclave is Script {
    error WrongChain(uint256 chainid);
    error InvalidAttestation();
    error SignerAlreadyRegistered(address signer);
    error Pcr0Mismatch(bytes32 provided, bytes32 expected);
    error AssetsNotAscending(uint256 index);
    error AssetLengthMismatch(uint256 ids, uint256 minSources);
    error MinSourcesOutOfRange(uint256 index, uint256 value);
    error TooManyAssets(uint256 provided, uint256 max);

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        KaskadPriceOracle oracle = KaskadPriceOracle(vm.envAddress("ORACLE"));
        bytes memory doc = vm.envBytes("GENESIS_DOC");
        bool directRegister = vm.envOr("DIRECT_REGISTER", false);
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));

        _warmCerts(oracle, key);
        address signer = _checkAttestation(oracle, doc);
        (bytes32[] memory ids, uint8[] memory minSources) = _readAssets(oracle);

        if (directRegister) {
            _register(oracle, doc, ids, minSources, key, signer);
        } else {
            _printSafeTx(address(oracle), doc, ids, minSources);
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

    /// @dev Empty ASSET_IDS => genesis-only key-root oracle: registerEnclave with
    ///      no price assets. Non-empty => also serve prices (validated here).
    function _readAssets(KaskadPriceOracle oracle)
        internal
        view
        returns (bytes32[] memory ids, uint8[] memory minSources)
    {
        ids = vm.envOr("ASSET_IDS", ",", new bytes32[](0));
        if (ids.length == 0) return (ids, new uint8[](0));

        uint256[] memory ms = vm.envOr("ASSET_MIN_SOURCES", ",", new uint256[](0));
        // Mirror registerAssets's range preconditions so Safe mode (no simulation)
        // never queues calldata that reverts after registerEnclave has committed.
        uint256 max = oracle.MAX_ASSETS();
        if (ids.length > max) revert TooManyAssets(ids.length, max);
        if (ids.length != ms.length) revert AssetLengthMismatch(ids.length, ms.length);

        minSources = new uint8[](ms.length);
        for (uint256 i = 0; i < ms.length; i++) {
            if (i > 0 && ids[i] <= ids[i - 1]) revert AssetsNotAscending(i);
            if (ms[i] == 0 || ms[i] > type(uint8).max) revert MinSourcesOutOfRange(i, ms[i]);
            minSources[i] = uint8(ms[i]);
        }
    }

    /// @dev Reachable only when the broadcasting key is the oracle owner (both
    ///      calls are onlyOwner).
    function _register(
        KaskadPriceOracle oracle,
        bytes memory doc,
        bytes32[] memory ids,
        uint8[] memory minSources,
        uint256 key,
        address signer
    ) internal {
        _broadcast(key);
        oracle.registerEnclave(doc);
        if (ids.length > 0) oracle.registerAssets(ids, minSources);
        vm.stopBroadcast();
        console.log("registerEnclave done. signer:", signer);
        console.log("assets registered:", ids.length);
        console.log("signerCount:", oracle.signerCount());
    }

    /// @dev Safe-owned oracle: no broadcast, just the two calldatas to submit.
    function _printSafeTx(
        address oracleAddr,
        bytes memory doc,
        bytes32[] memory ids,
        uint8[] memory minSources
    ) internal pure {
        bytes memory d1 = abi.encodeCall(KaskadPriceOracle.registerEnclave, (doc));
        console.log("Safe tx 1 registerEnclave -> :", oracleAddr);
        console.log(vm.toString(d1));
        if (ids.length > 0) {
            bytes memory d2 = abi.encodeCall(KaskadPriceOracle.registerAssets, (ids, minSources));
            console.log("Safe tx 2 registerAssets -> :", oracleAddr);
            console.log(vm.toString(d2));
        }
    }

    function _broadcast(uint256 key) internal {
        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }
    }
}
