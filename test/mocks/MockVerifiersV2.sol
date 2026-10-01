// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IAttestationVerifier} from "../../src/IAttestationVerifier.sol";

/// @notice Accepts any document, returns a settable PCR0 and the signer abi-encoded
///         in the document. Test-only — it verifies nothing.
contract MockVerifierV2 is IAttestationVerifier {
    bytes32 public pcr0;
    bool public ok = true;

    constructor(bytes32 _pcr0) {
        pcr0 = _pcr0;
    }

    function setPcr0(bytes32 _pcr0) external {
        pcr0 = _pcr0;
    }

    function setOk(bool _ok) external {
        ok = _ok;
    }

    function verifyAttestation(bytes calldata attestationDoc)
        external
        view
        override
        returns (bool, bytes32, address)
    {
        return (ok, pcr0, abi.decode(attestationDoc, (address)));
    }
}
