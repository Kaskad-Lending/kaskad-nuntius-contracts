// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KaskadPriceOracle.sol";

/// @notice Kicks off the Ownable2Step ownership transfer (step 1/2).
///         Current owner calls `transferOwnership(NEW_OWNER)`; the new
///         owner then has to call `acceptOwnership()` from its own
///         account (step 2/2) to take the role.
///
/// Env: DEPLOYER_KEY (current owner EOA), ORACLE_ADDRESS, NEW_ADMIN.
contract TransferAdmin is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        KaskadPriceOracle oracle = KaskadPriceOracle(vm.envAddress("ORACLE_ADDRESS"));
        address newOwner = vm.envAddress("NEW_ADMIN");

        vm.startBroadcast(key);
        oracle.transferOwnership(newOwner);
        vm.stopBroadcast();

        console.log("Oracle:", address(oracle));
        console.log("Pending owner set to:", newOwner);
        console.log("Step 2: new owner MUST call acceptOwnership() to finalize.");
    }
}
