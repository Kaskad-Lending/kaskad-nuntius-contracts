// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KaskadPriceOracle.sol";
import "../src/KaskadAggregatorV3.sol";

/// @notice Production deploy. Owner = deployer (transient): the script
///         whitelists `ENCLAVE_SIGNER` via `addSigner` and writes the
///         asset quorum commitment via `registerAssets`. Hand ownership
///         to the final multisig afterwards via TransferAdmin.s.sol
///         (kicks off the Ownable2Step pending-owner flow).
///
/// Required env:
///   DEPLOYER_KEY    — uint256 private key (optional if `--private-key` passed)
///   ENCLAVE_SIGNER  — address of the enclave signing key to whitelist.
///                     Owner is responsible for verifying the Nitro
///                     attestation document OFF-CHAIN before deploy.
contract Deploy is Script {
    /// @notice Enclave signer to whitelist on deploy. Virtual so DeployLocal
    ///         can supply a default (anvil account) instead of demanding env.
    function _getEnclaveSigner() internal virtual returns (address) {
        return vm.envAddress("ENCLAVE_SIGNER");
    }

    /// @notice Asset registration commitment. Sorted ascending —
    ///         `registerAssets` enforces canonical order.
    function _getAssets()
        internal
        pure
        virtual
        returns (bytes32[] memory ids, uint8[] memory minSources)
    {
        ids = new bytes32[](5);
        minSources = new uint8[](5);

        //   0x0b43…6e45  ETH/USD
        //   0x4db2…8273  IGRA/USD
        //   0xb445…5cd2  KAS/USD
        //   0xee62…6489  BTC/USD
        //   0xff06…b7ef  USDC/USD
        ids[0] = keccak256("ETH/USD");   minSources[0] = 3;
        ids[1] = keccak256("IGRA/USD");  minSources[1] = 1;
        ids[2] = keccak256("KAS/USD");   minSources[2] = 3;
        ids[3] = keccak256("BTC/USD");   minSources[3] = 3;
        ids[4] = keccak256("USDC/USD");  minSources[4] = 2;
    }

    function run() external {
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }

        address owner = key != 0 ? vm.addr(key) : msg.sender;
        address enclaveSigner = _getEnclaveSigner();
        require(enclaveSigner != address(0), "ENCLAVE_SIGNER == 0");

        KaskadPriceOracle oracle = new KaskadPriceOracle(owner);
        console.log("KaskadPriceOracle deployed at:", address(oracle));
        console.log("Owner (deployer; controls signer set + assets):", owner);

        oracle.addSigner(enclaveSigner);
        console.log("Whitelisted enclave signer:", enclaveSigner);

        (bytes32[] memory ids, uint8[] memory minSources) = _getAssets();
        oracle.registerAssets(ids, minSources);
        console.log("Registered assets:", ids.length);

        _deployAggregators(address(oracle));

        vm.stopBroadcast();
    }

    function _deployAggregators(address oracle) internal {
        KaskadAggregatorV3 ethAgg  = new KaskadAggregatorV3(oracle, keccak256("ETH/USD"),  "ETH / USD");
        KaskadAggregatorV3 btcAgg  = new KaskadAggregatorV3(oracle, keccak256("BTC/USD"),  "BTC / USD");
        KaskadAggregatorV3 kasAgg  = new KaskadAggregatorV3(oracle, keccak256("KAS/USD"),  "KAS / USD");
        KaskadAggregatorV3 usdcAgg = new KaskadAggregatorV3(oracle, keccak256("USDC/USD"), "USDC / USD");
        KaskadAggregatorV3 igraAgg = new KaskadAggregatorV3(oracle, keccak256("IGRA/USD"), "IGRA / USD");

        console.log("ETH/USD Aggregator:", address(ethAgg));
        console.log("BTC/USD Aggregator:", address(btcAgg));
        console.log("KAS/USD Aggregator:", address(kasAgg));
        console.log("USDC/USD Aggregator:", address(usdcAgg));
        console.log("IGRA/USD Aggregator:", address(igraAgg));
    }
}
