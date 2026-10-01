// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/// Independent Solidity implementation of the keyex owner-approval EIP-712
/// digest. Nothing on chain verifies this struct; the script exists so the
/// Rust encoder in crates/keyex/src/approval.rs has a second implementation to
/// be checked against (the KAT asserted by `parity_with_forge`).
contract KeyexApprovalDigest is Script {
    bytes32 constant APPROVAL_TYPEHASH = keccak256(
        "Approval(bytes pcr0,uint64 version,uint8 mode,bytes32 label,uint8 role,uint64 expiry,bytes32 nonce)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId)");

    struct Approval {
        bytes pcr0;
        uint64 version;
        uint8 mode;
        bytes32 label;
        uint8 role;
        uint64 expiry;
        bytes32 nonce;
    }

    function domainSeparator(uint256 chainId) public pure returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Kaskad Keyex"), keccak256("1"), chainId)
        );
    }

    function hashStruct(Approval memory a) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                APPROVAL_TYPEHASH,
                keccak256(a.pcr0),
                a.version,
                a.mode,
                a.label,
                a.role,
                a.expiry,
                a.nonce
            )
        );
    }

    function digest(Approval memory a, uint256 chainId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(chainId), hashStruct(a)));
    }

    /// The canonical vector: pcr0 = [0..48), version 1, mode Carry(1),
    /// label keccak256("kaskad/pontifex/v1"), role Oracle(1),
    /// expiry 1900000000, nonce = [0..32), chain 46630.
    function canonical() public pure returns (Approval memory a) {
        bytes memory pcr0 = new bytes(48);
        for (uint256 i = 0; i < 48; i++) {
            pcr0[i] = bytes1(uint8(i));
        }
        bytes32 nonce;
        for (uint256 i = 0; i < 32; i++) {
            nonce |= bytes32(bytes1(uint8(i))) >> (i * 8);
        }
        a = Approval({
            pcr0: pcr0,
            version: 1,
            mode: 1,
            label: keccak256("kaskad/pontifex/v1"),
            role: 1,
            expiry: 1900000000,
            nonce: nonce
        });
    }

    function run() external pure {
        console2.logBytes32(APPROVAL_TYPEHASH);
        console2.logBytes32(digest(canonical(), 46630));
    }
}
