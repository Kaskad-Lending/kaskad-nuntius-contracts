// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {KaskadPriceOracleV2} from "../../src/KaskadPriceOracleV2.sol";
import {NitroAttestationVerifierV2} from "../../src/NitroAttestationVerifierV2.sol";
import {KaskadStalenessGatedAggregatorV3} from "../../src/KaskadStalenessGatedAggregatorV3.sol";
import {DeployOracleV2Igra} from "../../script/DeployOracleV2Igra.s.sol";
import {DeployIgraAggregators} from "../../script/DeployIgraAggregators.s.sol";
import {MockVerifierV2} from "../mocks/MockVerifiersV2.sol";

contract IgraDeployScriptsTest is Test {
    bytes32 internal constant PCR0 = 0xbb931ffb096d1c3f39c1b35d184a2db1cf0b7d6e6cdc4e8966ea0786a814abb3;
    address internal constant SAFE = 0x5B95Ea5D5B63998467eE92B0b175ACE49ccC1943;
    address internal constant CHECKER = 0xA1Ac7719C916e554588cD05d3A8f1700C1b48Ca8;

    function setUp() public {
        vm.chainId(38833);
        vm.warp(1794583720); // CertManager checks the AWS root's validity window on construction.
    }

    /// The oracle lands Safe-owned, pinned to the PCR0, with a fresh prover and no signer.
    function test_OracleDeployBindsOwnerPcr0AndProver() public {
        DeployOracleV2Igra s = new DeployOracleV2Igra();
        KaskadPriceOracleV2 oracle = s.deploy(PCR0, SAFE, address(0));
        assertEq(oracle.owner(), SAFE);
        assertEq(oracle.expectedPcr0(), PCR0);
        assertEq(oracle.signerCount(), 0);
        address prover = address(NitroAttestationVerifierV2(address(oracle.verifier())).nitroProver());
        assertGt(prover.code.length, 0);
    }

    /// EXISTING_PROVER is wired through unchanged.
    function test_OracleDeployReusesAProver() public {
        DeployOracleV2Igra s = new DeployOracleV2Igra();
        KaskadPriceOracleV2 first = s.deploy(PCR0, SAFE, address(0));
        address prover = address(NitroAttestationVerifierV2(address(first.verifier())).nitroProver());
        KaskadPriceOracleV2 second = s.deploy(PCR0, SAFE, prover);
        assertEq(address(NitroAttestationVerifierV2(address(second.verifier())).nitroProver()), prover);
    }

    /// A zero PCR0 would admit any image; the script refuses before deploying.
    function test_OracleDeployRejectsZeroPcr0() public {
        DeployOracleV2Igra s = new DeployOracleV2Igra();
        vm.expectRevert(bytes("EXPECTED_PCR0 == 0"));
        s.deploy(bytes32(0), SAFE, address(0));
    }

    /// Both Igra scripts refuse any other chain.
    function test_ScriptsRejectOtherChains() public {
        vm.chainId(4663);
        DeployOracleV2Igra o = new DeployOracleV2Igra();
        vm.expectRevert(abi.encodeWithSelector(DeployOracleV2Igra.WrongChain.selector, 4663));
        o.run();
        DeployIgraAggregators a = new DeployIgraAggregators();
        vm.expectRevert(abi.encodeWithSelector(DeployIgraAggregators.WrongChain.selector, 4663));
        a.run();
    }

    /// One gated aggregator per reserve, bound to the oracle, the checker and the nuntius asset id.
    function test_AggregatorsDeployOnePerReserve() public {
        address oracle = address(new KaskadPriceOracleV2(PCR0, address(new MockVerifierV2(PCR0)), SAFE));
        DeployIgraAggregators s = new DeployIgraAggregators();
        (address[] memory assets, address[] memory sources) = s.deploy(oracle, CHECKER);

        address[5] memory reserves = [
            0x69790024D44504F05973E127197E6df17e283859,
            0xF2B48b6e560af8834622203a8EEff6960d6172De,
            0x17Ec7E1768c813E2a3a9b0f94A35605CA520C242,
            0xA5b8BF902b2844dA17d4506cc827F7F1681735E7,
            0x46346F49b4fe8c640c5FCdbed2d6741056FEB959
        ];
        string[5] memory symbols = ["ETH", "BTC", "KAS", "USDC", "USDT"];
        assertEq(assets.length, 5);
        for (uint256 i = 0; i < 5; i++) {
            KaskadStalenessGatedAggregatorV3 agg = KaskadStalenessGatedAggregatorV3(sources[i]);
            assertEq(assets[i], reserves[i]);
            assertEq(address(agg.oracle()), oracle);
            assertEq(address(agg.stalenessChecker()), CHECKER);
            assertEq(agg.assetId(), keccak256(bytes(string.concat(symbols[i], "/USD"))));
            assertEq(agg.description(), string.concat(symbols[i], " / USD"));
        }
    }
}
