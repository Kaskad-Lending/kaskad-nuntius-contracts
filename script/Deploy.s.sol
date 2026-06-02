// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KaskadPriceOracle.sol";
import "../src/KaskadAggregatorV3.sol";
import "../src/NitroAttestationVerifier.sol";
import "nitro-prover/CertManager.sol";

import {NitroProver} from "nitro-prover/NitroProver.sol";

/// @notice Production deploy: CertManager + NitroProver +
///         NitroAttestationVerifier + KaskadPriceOracle + per-asset
///         KaskadAggregatorV3 wrappers. The deployer EOA is set as
///         initial owner (Ownable2Step); the script runs
///         `registerEnclave` + `registerAssets` under that ownership,
///         then hand the role to the final multisig via
///         `TransferAdmin.s.sol`.
///
/// Required env:
///   DEPLOYER_KEY              — uint256 deployer key (optional if `--private-key`)
///   ATTESTATION_DOC           — raw Nitro attestation bytes (CBOR COSE_Sign1)
///   EXPECTED_PCR1             — bytes32 kernel hash. MUST be non-zero (audit D-2).
///   EXPECTED_PCR2             — bytes32 application hash. MUST be non-zero (audit D-2).
///
/// Optional env:
///   EXPECTED_ENCLAVE_SIGNER   — address. When set, the script asserts
///                                the attestation doc resolves to this
///                                signer (audit D-5: defends against a
///                                substituted attestation doc that pins
///                                an attacker-controlled signer).
contract Deploy is Script {
    // ─── Hooks (overridden in DeployLocal) ────────────────────────────────

    /// @notice Deploy the attestation verifier stack. Prod: CertManager +
    ///         NitroProver + NitroAttestationVerifier with env-supplied
    ///         PCR1/PCR2. Local: MockAttestationVerifier.
    function _buildVerifier() internal virtual returns (IAttestationVerifier) {
        CertManager certManager = new CertManager();
        console.log("CertManager:", address(certManager));

        NitroProver prover = new NitroProver(certManager);
        console.log("NitroProver:", address(prover));

        bytes32 expectedPCR1 = vm.envBytes32("EXPECTED_PCR1");
        bytes32 expectedPCR2 = vm.envBytes32("EXPECTED_PCR2");
        NitroAttestationVerifier v =
            new NitroAttestationVerifier(address(prover), expectedPCR1, expectedPCR2);
        console.log("NitroAttestationVerifier:", address(v));
        return IAttestationVerifier(address(v));
    }

    /// @notice Return the attestation document used for `registerEnclave`.
    ///         Prod: loaded from env. Local: stub bytes accepted by mock.
    function _getAttestationDoc() internal virtual returns (bytes memory) {
        return vm.envBytes("ATTESTATION_DOC");
    }

    /// @notice Cache the certificate chain so the on-chain
    ///         `verifyAttestation` in `registerEnclave` is cheap. Prod:
    ///         calls `verifyCerts`. Local: no-op.
    function _cacheCerts(IAttestationVerifier v, bytes memory doc) internal virtual {
        NitroAttestationVerifier(address(v)).verifyCerts(doc);
    }

    /// @notice Extract the PCR0 that the oracle contract should be bound
    ///         to. Prod: dry-run `verifyAttestation`. Local: a compile-
    ///         time constant the mock verifier is also constructed with.
    function _extractPCR0(IAttestationVerifier v, bytes memory doc)
        internal
        virtual
        returns (bytes32)
    {
        (bool valid, bytes32 pcr0, address enclaveSigner) = v.verifyAttestation(doc);
        require(valid, "Attestation invalid (Root CA signature / PCR1 / PCR2 mismatch)");
        console.log("Nitro PCR0:");
        console.logBytes32(pcr0);
        console.log("Enclave Signer:", enclaveSigner);
        return pcr0;
    }

    /// @notice Pre-flight env validation. Fails fast before any
    ///         state-modifying tx so a misconfig is caught at the top
    ///         of the script, not after partial deployment.
    function _validateEnv() internal virtual {
        bytes32 expectedPCR1 = vm.envBytes32("EXPECTED_PCR1");
        bytes32 expectedPCR2 = vm.envBytes32("EXPECTED_PCR2");
        require(expectedPCR1 != bytes32(0), "EXPECTED_PCR1 == 0 (audit D-2)");
        require(expectedPCR2 != bytes32(0), "EXPECTED_PCR2 == 0 (audit D-2)");
    }

    /// @notice Optional: when `EXPECTED_ENCLAVE_SIGNER` is set, assert the
    ///         attestation doc resolves to that signer (audit D-5).
    function _assertExpectedSigner(IAttestationVerifier v, bytes memory doc) internal virtual {
        address expected = vm.envOr("EXPECTED_ENCLAVE_SIGNER", address(0));
        if (expected == address(0)) return;
        (, , address actual) = v.verifyAttestation(doc);
        require(
            actual == expected,
            "Attestation signer != EXPECTED_ENCLAVE_SIGNER (audit D-5)"
        );
        console.log("EXPECTED_ENCLAVE_SIGNER bound:", expected);
    }

    // ─── Static config ────────────────────────────────────────────────────

    /// @notice Asset registration commitment. Sorted ascending —
    ///         `registerAssets` enforces canonical order. Six mainnet
    ///         (igra 38833) assets: ETH/IGRA/USDT/KAS/BTC/USDC.
    ///         IGRA is signed by the enclave (frontend pulls it) even
    ///         though it isn't a listed Aave reserve — must be in the
    ///         commitment so `updatePrice` accepts it.
    function _getAssets()
        internal
        pure
        virtual
        returns (bytes32[] memory ids, uint8[] memory minSources)
    {
        ids = new bytes32[](6);
        minSources = new uint8[](6);

        //   0x0b43…6e45  ETH/USD
        //   0x4db2…8273  IGRA/USD
        //   0x9187…3eb0  USDT/USD
        //   0xb445…5cd2  KAS/USD
        //   0xee62…6489  BTC/USD
        //   0xff06…b7ef  USDC/USD
        ids[0] = keccak256("ETH/USD");   minSources[0] = 3;
        ids[1] = keccak256("IGRA/USD");  minSources[1] = 1;
        ids[2] = keccak256("USDT/USD");  minSources[2] = 2;
        ids[3] = keccak256("KAS/USD");   minSources[3] = 3;
        ids[4] = keccak256("BTC/USD");   minSources[4] = 3;
        ids[5] = keccak256("USDC/USD");  minSources[5] = 2;
    }

    // ─── Entrypoint ───────────────────────────────────────────────────────

    function run() external {
        _validateEnv();

        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }

        // 1. Verifier stack
        IAttestationVerifier v = _buildVerifier();

        // 2. Attestation doc
        bytes memory attestationDoc = _getAttestationDoc();

        // 3. Cache certs so on-chain verifyAttestation is cheap (prod only)
        _cacheCerts(v, attestationDoc);

        // 4. Pin PCR0 — deployed oracle will only accept this image
        bytes32 pcr0 = _extractPCR0(v, attestationDoc);

        // 4b. (Optional) bind to a specific expected signer.
        _assertExpectedSigner(v, attestationDoc);

        // 5. Oracle — initial owner = deployer (transient). Hand off to
        //    multisig via TransferAdmin.s.sol after setup.
        address initialOwner = key != 0 ? vm.addr(key) : msg.sender;
        KaskadPriceOracle oracle = new KaskadPriceOracle(pcr0, address(v), initialOwner);
        console.log("KaskadPriceOracle:", address(oracle));
        console.log("Owner (deployer):", initialOwner);

        // 6. Register the enclave signer — onlyOwner, attestation-gated.
        oracle.registerEnclave(attestationDoc);
        console.log("Enclave registered");

        // 7. Register asset quorum commitment.
        (bytes32[] memory ids, uint8[] memory minSources) = _getAssets();
        oracle.registerAssets(ids, minSources);
        console.log("Registered assets:", ids.length);

        // 8. Per-asset Chainlink-compat wrappers
        _deployAggregators(address(oracle));

        vm.stopBroadcast();
    }

    function _deployAggregators(address oracle) internal {
        KaskadAggregatorV3 ethAgg  = new KaskadAggregatorV3(oracle, keccak256("ETH/USD"),  "ETH / USD");
        KaskadAggregatorV3 btcAgg  = new KaskadAggregatorV3(oracle, keccak256("BTC/USD"),  "BTC / USD");
        KaskadAggregatorV3 kasAgg  = new KaskadAggregatorV3(oracle, keccak256("KAS/USD"),  "KAS / USD");
        KaskadAggregatorV3 usdcAgg = new KaskadAggregatorV3(oracle, keccak256("USDC/USD"), "USDC / USD");
        KaskadAggregatorV3 usdtAgg = new KaskadAggregatorV3(oracle, keccak256("USDT/USD"), "USDT / USD");
        KaskadAggregatorV3 igraAgg = new KaskadAggregatorV3(oracle, keccak256("IGRA/USD"), "IGRA / USD");

        console.log("ETH/USD Aggregator:", address(ethAgg));
        console.log("BTC/USD Aggregator:", address(btcAgg));
        console.log("KAS/USD Aggregator:", address(kasAgg));
        console.log("USDC/USD Aggregator:", address(usdcAgg));
        console.log("USDT/USD Aggregator:", address(usdtAgg));
        console.log("IGRA/USD Aggregator:", address(igraAgg));
    }
}
