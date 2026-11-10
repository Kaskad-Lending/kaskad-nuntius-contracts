// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {HemiKaskadRouter} from "../src/HemiKaskadRouter.sol";

/// @notice Deploys HemiKaskadRouter on Hemi Sepolia against the live price
///         registry, pool and WETH. Broadcast with --private-key or --account.
contract DeployHemiRouter is Script {
    uint256 internal constant HEMI_SEPOLIA = 743111;
    address internal constant REGISTRY = 0xaa756d70edea36F834B982E03A79EE59835d0d1A;
    address internal constant POOL = 0xf3E62b03e8DEd32B7000A1800460C92803f9E798;
    address internal constant WETH = 0x0C8aFD1b58aa2A5bAd2414B861D8A7fF898eDC3A;

    error WrongChain(uint256 chainid);
    error MissingCode(address target);

    function run() external returns (HemiKaskadRouter router) {
        if (block.chainid != HEMI_SEPOLIA) revert WrongChain(block.chainid);
        if (REGISTRY.code.length == 0) revert MissingCode(REGISTRY);
        if (POOL.code.length == 0) revert MissingCode(POOL);
        if (WETH.code.length == 0) revert MissingCode(WETH);

        vm.startBroadcast();
        router = new HemiKaskadRouter(REGISTRY, POOL, WETH);
        vm.stopBroadcast();

        console.log("HemiKaskadRouter", address(router));
    }
}
