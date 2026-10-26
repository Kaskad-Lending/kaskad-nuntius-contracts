// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/// @notice Print the CREATE address the RH KaskadPriceOracle will land on, to
///         bake into the enclave as KEYEX_ORACLE_REGISTRY. The standalone
///         deploy does exactly three CREATEs before the oracle (CertManager,
///         NitroProver, NitroAttestationVerifier), so the oracle sits at
///         nonce+3. Run against the live RH RPC so `getNonce` is authoritative;
///         the deploy must then run with no intervening tx from `deployer`
///         (dedicate the deployer or freeze its nonce) or the deploy asserts
///         out fail-loud.
///
/// Env (one of DEPLOYER_ADDR / DEPLOYER_KEY; else the default script sender):
///   DEPLOYER_ADDR — address that will run DeployRobinhoodOracle
///   DEPLOYER_KEY  — uint256 key (address derived if DEPLOYER_ADDR unset)
contract PredictOracleAddress is Script {
    function run() external view {
        address deployer = vm.envOr("DEPLOYER_ADDR", address(0));
        if (deployer == address(0)) {
            uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
            deployer = key != 0 ? vm.addr(key) : msg.sender;
        }

        uint64 nonce = vm.getNonce(deployer);
        address predicted = vm.computeCreateAddress(deployer, uint256(nonce) + 3);

        console.log("deployer :", deployer);
        console.log("nonce    :", nonce);
        console.log("Bake as KEYEX_ORACLE_REGISTRY (oracle @ nonce+3):");
        console.log(predicted);
    }
}
