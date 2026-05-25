// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./Deploy.s.sol";

/// @notice Local/anvil deploy. No attestation verifier anywhere in the
///         contract anymore — local flow matches prod flow exactly,
///         only the signer source differs: env or Anvil account #1.
///
/// Required env:
///   DEPLOYER_KEY    — uint256 private key (or `--private-key` on CLI)
///   ORACLE_SIGNER   — (optional) enclave-signer address.
///                     Defaults to Anvil account #1.
contract DeployLocal is Deploy {
    address constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    function _getEnclaveSigner() internal view override returns (address) {
        return vm.envOr("ORACLE_SIGNER", ANVIL_ACCOUNT_1);
    }
}
