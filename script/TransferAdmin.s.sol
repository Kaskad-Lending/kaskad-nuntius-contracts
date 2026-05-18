// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KaskadPriceOracle.sol";

/// @notice Hand the oracle admin role from the deploy-time EOA to the
///         final admin (multisig). Run after deploy + registerAssets
///         are verified on-chain.
///
/// Env: DEPLOYER_KEY (current admin EOA), ORACLE_ADDRESS, NEW_ADMIN.
contract TransferAdmin is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        KaskadPriceOracle oracle = KaskadPriceOracle(vm.envAddress("ORACLE_ADDRESS"));
        address newAdmin = vm.envAddress("NEW_ADMIN");

        vm.startBroadcast(key);
        oracle.transferAdmin(newAdmin);
        vm.stopBroadcast();

        console.log("Oracle:", address(oracle));
        console.log("Admin transferred to:", newAdmin);
    }
}
