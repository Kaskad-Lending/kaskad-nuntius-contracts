// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KaskadPriceOracleV2.sol";
import "../src/NitroAttestationVerifierV2.sol";
import "nitro-prover/CertManager.sol";
import {NitroProver} from "nitro-prover/NitroProver.sol";

/// @notice Post-genesis registration for a V2 oracle. Warms the attestation
///         cert chain one cert at a time (RH's per-tx gas cap cannot fit the
///         bundled verifyCerts), then registerEnclave(GENESIS_DOC) and
///         registerAssets(the four parallel env arrays, packed into structs).
///         EOA owner -> direct broadcast; Safe owner -> prints calldata.
///
/// Env:
///   ORACLE                 — deployed KaskadPriceOracleV2 address.
///   GENESIS_DOC            — raw Nitro attestation bytes from the booted enclave.
///   CERT_CHAIN             — comma-separated certs: CA bundle without the root, then the leaf.
///   ASSET_IDS              — comma-separated bytes32 keccak256(symbol), strictly ascending.
///   ASSET_MIN_SOURCES      — comma-separated quorum per asset, 1..255.
///   ASSET_MAX_CHANGE_BPS   — comma-separated per-asset breaker, 1..5000.
///   ASSET_MAX_RESUME_BPS   — comma-separated post-silence breaker, >= max change, <= 5000.
///   DIRECT_REGISTER        — bool; true broadcasts (EOA owner), false prints Safe calldata.
///   DEPLOYER_KEY           — uint256 (optional if --private-key / --sender).
contract RegisterOracleEnclaveV2 is Script {
    error WrongChain(uint256 chainid);
    error InvalidAttestation();
    error SignerAlreadyRegistered(address signer);
    error Pcr0Mismatch(bytes32 provided, bytes32 expected);
    error AssetsNotAscending(uint256 index);
    error AssetLengthMismatch(uint256 ids, uint256 minSources, uint256 maxChange, uint256 maxResume);
    error MinSourcesOutOfRange(uint256 index, uint256 value);
    error ChangeBpsOutOfRange(uint256 index, uint256 maxChange, uint256 maxResume);
    error TooManyAssets(uint256 provided, uint256 max);

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        KaskadPriceOracleV2 oracle = KaskadPriceOracleV2(vm.envAddress("ORACLE"));
        bytes memory doc = vm.envBytes("GENESIS_DOC");
        bool directRegister = vm.envOr("DIRECT_REGISTER", false);
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));

        _warmCerts(oracle, key);
        address signer = _checkAttestation(oracle, doc);
        KaskadPriceOracleV2.AssetConfig[] memory configs = _readAssets(oracle);

        if (directRegister) {
            _register(oracle, doc, configs, key, signer);
        } else {
            _printSafeTx(address(oracle), doc, configs);
        }
    }

    /// @dev Walk CERT_CHAIN skipping certs CertManager already cached, parent
    ///      hash chained from ROOT_CA_CERT_HASH. One tx per cert so each fits
    ///      the per-tx gas cap.
    function _warmCerts(KaskadPriceOracleV2 oracle, uint256 key) internal {
        bytes[] memory certChain = vm.envBytes("CERT_CHAIN", ",");
        NitroProver prover = NitroAttestationVerifierV2(address(oracle.verifier())).nitroProver();
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
    ///      current expectation, signer not already registered.
    function _checkAttestation(KaskadPriceOracleV2 oracle, bytes memory doc)
        internal
        view
        returns (address signer)
    {
        bool valid;
        bytes32 pcr0;
        (valid, pcr0, signer) = oracle.verifier().verifyAttestation(doc);
        if (!valid) revert InvalidAttestation();
        if (pcr0 != oracle.expectedPcr0()) revert Pcr0Mismatch(pcr0, oracle.expectedPcr0());
        if (oracle.isValidSigner(signer)) revert SignerAlreadyRegistered(signer);
        console.log("verifyAttestation OK, signer:", signer);
    }

    /// @dev Empty ASSET_IDS => genesis-only key-root oracle. Mirrors every
    ///      registerAssets precondition so Safe mode (no simulation) can never
    ///      queue calldata that reverts after registerEnclave has committed.
    function _readAssets(KaskadPriceOracleV2 oracle)
        internal
        view
        returns (KaskadPriceOracleV2.AssetConfig[] memory configs)
    {
        bytes32[] memory ids = vm.envOr("ASSET_IDS", ",", new bytes32[](0));
        if (ids.length == 0) return new KaskadPriceOracleV2.AssetConfig[](0);

        uint256[] memory ms = vm.envOr("ASSET_MIN_SOURCES", ",", new uint256[](0));
        uint256[] memory mc = vm.envOr("ASSET_MAX_CHANGE_BPS", ",", new uint256[](0));
        uint256[] memory mr = vm.envOr("ASSET_MAX_RESUME_BPS", ",", new uint256[](0));

        uint256 max = oracle.MAX_ASSETS();
        if (ids.length > max) revert TooManyAssets(ids.length, max);
        if (ids.length != ms.length || ids.length != mc.length || ids.length != mr.length) {
            revert AssetLengthMismatch(ids.length, ms.length, mc.length, mr.length);
        }

        uint256 ceiling = oracle.MAX_CHANGE_BPS_CEILING();
        configs = new KaskadPriceOracleV2.AssetConfig[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            if (i > 0 && ids[i] <= ids[i - 1]) revert AssetsNotAscending(i);
            if (ms[i] == 0 || ms[i] > type(uint8).max) revert MinSourcesOutOfRange(i, ms[i]);
            if (mc[i] == 0 || mr[i] < mc[i] || mr[i] > ceiling) {
                revert ChangeBpsOutOfRange(i, mc[i], mr[i]);
            }
            configs[i] = KaskadPriceOracleV2.AssetConfig({
                id: ids[i],
                minSources: uint8(ms[i]),
                maxChangeBps: uint16(mc[i]),
                maxResumeChangeBps: uint16(mr[i])
            });
        }
    }

    /// @dev Reachable only when the broadcasting key is the oracle owner (both
    ///      calls are onlyOwner).
    function _register(
        KaskadPriceOracleV2 oracle,
        bytes memory doc,
        KaskadPriceOracleV2.AssetConfig[] memory configs,
        uint256 key,
        address signer
    ) internal {
        _broadcast(key);
        oracle.registerEnclave(doc);
        if (configs.length > 0) oracle.registerAssets(configs);
        vm.stopBroadcast();
        console.log("registerEnclave done. signer:", signer);
        console.log("assets registered:", configs.length);
        console.log("signerCount:", oracle.signerCount());
    }

    /// @dev Safe-owned oracle: no broadcast, just the two calldatas to submit.
    function _printSafeTx(
        address oracleAddr,
        bytes memory doc,
        KaskadPriceOracleV2.AssetConfig[] memory configs
    ) internal pure {
        bytes memory d1 = abi.encodeCall(KaskadPriceOracleV2.registerEnclave, (doc));
        console.log("Safe tx 1 registerEnclave -> :", oracleAddr);
        console.log(vm.toString(d1));
        if (configs.length > 0) {
            bytes memory d2 = abi.encodeCall(KaskadPriceOracleV2.registerAssets, (configs));
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
