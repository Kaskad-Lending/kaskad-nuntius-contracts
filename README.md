# Kaskad Nuntius Contracts

The on-chain side of Nuntius, Kaskad's price oracle. The oracle contracts register enclave signers from AWS Nitro attestations, accept EIP-191 signed price updates from those signers, and expose the prices to lending markets, also through a Chainlink-compatible `AggregatorV3` adapter.

The enclave that signs the prices is developed in [Kaskad-Lending/kaskad-nuntius](https://github.com/Kaskad-Lending/kaskad-nuntius), which includes this repository as a submodule. The source of the live Robinhood Chain images is [Kaskad-Lending/kaskad-pontifex-enclave](https://github.com/Kaskad-Lending/kaskad-pontifex-enclave).

- [Oracle API Reference](https://docs.kaskad.app/docs/oracle-api): addresses, functions, errors, and examples for apps that read or submit prices.
- [Verify the Enclaves](https://docs.kaskad.app/docs/enclave-verification): how to check the enclave images against the on-chain pins.

## Deployments

| Network | Contracts | Source |
|---|---|---|
| Robinhood Chain (`4663`) | `KaskadPriceOracleV2`, `NitroAttestationVerifierV2` | tag [`robinhood-mainnet-v2`](https://github.com/Kaskad-Lending/kaskad-nuntius-contracts/tree/robinhood-mainnet-v2), commit `a840d6b` |
| Igra (`38833`) | `KaskadPriceOracle`, `NitroAttestationVerifier` | tag [`igra-mainnet-v1`](https://github.com/Kaskad-Lending/kaskad-nuntius-contracts/tree/igra-mainnet-v1), commit `5d865b3` |

The deployed bytecode of these contracts matches the tagged commits. To compare bytecode, build the tag, not `main`.

## Contracts

| Contract | Purpose |
|---|---|
| `src/KaskadPriceOracleV2.sol` | Oracle on Robinhood Chain. Registers a signer from an attestation whose PCR0 matches `expectedPcr0`, verifies signed price updates, applies per-asset source quorum and change limits, and stores the latest price and the round history. |
| `src/NitroAttestationVerifierV2.sol` | Verifies an attestation document against the AWS Nitro root certificate and returns its PCR0 and the Ethereum address of the enclave key. |
| `src/KaskadPriceOracle.sol` | Oracle on Igra. The same update and read interface, with fixed change limits and a PCR0 set at deployment. |
| `src/NitroAttestationVerifier.sol` | Attestation verifier of the Igra oracle. It also requires the PCR1 and PCR2 set at deployment. |
| `src/KaskadAggregatorV3.sol` | Chainlink `AggregatorV3` adapter for one asset of either oracle version. |
| `src/IKaskadPriceOracleRead.sol` | The read functions both oracles implement: `getLatestPrice` and `getRoundData`. |
| `src/KaskadRouter.sol` | Submits signed prices, alone or followed by an Aave borrow, withdrawal or liquidation in the same transaction. |
| `src/vendor/p384/` | P-384 signature verification used by the attestation verifiers. Origin in `PROVENANCE`. |
| `test/mocks/` | Mock verifiers for tests and local deployments. Never deploy them to a live network. |

## Build and Test

```bash
git clone --recursive https://github.com/Kaskad-Lending/kaskad-nuntius-contracts.git
cd kaskad-nuntius-contracts
forge build
forge test
```

If you cloned without `--recursive`, run `git submodule update --init --recursive`. `foundry.toml` pins solc 0.8.24.

## Deploy on Robinhood Chain

The enclave image has the oracle's address built in, and the oracle pins the image's PCR0. To break the cycle, the oracle address is predicted from the deployer's nonce before the image is built. `DeployOracleV2` and `RegisterOracleEnclaveV2` run only on Robinhood Chain (`4663`) and its testnet (`46630`).

1. **Predict the oracle address.** `script/PredictOracleAddress.s.sol` computes, from the deployer's current nonce, the address at which `DeployOracleV2` will create the oracle. The deployer must send no other transaction before step 3.

   ```bash
   DEPLOYER_ADDR=0x… forge script script/PredictOracleAddress.s.sol --rpc-url <rpc>
   ```

2. **Build the enclave image** from `Dockerfile.oracle` in [kaskad-pontifex-enclave](https://github.com/Kaskad-Lending/kaskad-pontifex-enclave/tree/79c81b806232c325b3b4b01c9d47cb8713e71063), the source of the live Robinhood Chain images, with that address as `KEYEX_ORACLE_REGISTRY`. Read its PCR0 with `nitro-cli describe-eif`. The first 32 bytes of PCR0 are the value the oracle pins.
3. **Deploy the oracle.** `script/DeployOracleV2.s.sol` deploys the attestation verifier and `KaskadPriceOracleV2` pinned to that PCR0. It stops before sending anything if the oracle would not land on the predicted address. `ORACLE_OWNER` defaults to the deployer.

   ```bash
   EXPECTED_PCR0=0x… KEYEX_ORACLE_REGISTRY=0x… ORACLE_OWNER=0x… \
   forge script script/DeployOracleV2.s.sol --rpc-url <rpc> --broadcast --private-key <deployer key>
   ```

4. **Boot the enclave.** While the oracle has no registered signer, the enclave generates a new signing key and produces an attestation document that binds it.
5. **Register the signer and the assets.** `script/RegisterOracleEnclaveV2.s.sol` stores the attestation's certificate chain one certificate per transaction, because the whole chain does not fit in one Robinhood Chain transaction. It then calls `registerEnclave` with the attestation and `registerAssets` with the asset list. With `DIRECT_REGISTER=false`, for example when a Safe owns the oracle, it still stores the certificates, then prints the `registerEnclave` and `registerAssets` calldata for the owner to submit.

   ```bash
   ORACLE=0x… GENESIS_DOC=0x… CERT_CHAIN=0x…,0x… \
   ASSET_IDS=0x…,0x… ASSET_MIN_SOURCES=… ASSET_MAX_CHANGE_BPS=… ASSET_MAX_RESUME_BPS=… \
   DIRECT_REGISTER=true \
   forge script script/RegisterOracleEnclaveV2.s.sol --rpc-url <rpc> --broadcast --slow --private-key <owner key>
   ```

   - `--slow` sends each transaction only after the previous one is mined.
   - `GENESIS_DOC` is the attestation document in hex.
   - `CERT_CHAIN` comes from the attestation: `CERT_DOC_FILE=<file with the hex> cargo run -q -p nitro-common --example extract_cert_chain` in kaskad-pontifex-enclave.
   - `ASSET_IDS` are `keccak256` of the symbols, such as `ETH/USD`, in ascending order. The other lists follow the same order: the minimum number of sources, the change limit in basis points, and the looser limit that applies after an hour without updates. Both limits are at most 5000, and the second is not lower than the first.

Once its key is registered, the enclave starts signing prices for the assets in its bundled `config/assets.json`. The oracle accepts updates only for registered assets.

## Deploy on Igra

`script/Deploy.s.sol` deploys the first version in one run. It deploys the attestation verifier pinned to PCR1 and PCR2, takes PCR0 from the attestation document, deploys `KaskadPriceOracle`, registers the signer and Kaskad's seven assets with their source quorums, and deploys one aggregator per asset. To use other assets, change the lists in the script.

```bash
DEPLOYER_KEY=0x… ATTESTATION_DOC=0x… EXPECTED_PCR1=0x… EXPECTED_PCR2=0x… \
forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast
```

- `EXPECTED_PCR1` and `EXPECTED_PCR2` are the first 32 bytes of the image's PCR1 and PCR2.
- With `EXPECTED_ENCLAVE_SIGNER=0x…`, the script also checks that the attestation binds that signer.
- The certificate chain is stored in a single transaction, for which forge estimates about 70 million gas. The chain must accept a transaction of that size.

`script/DeployLocal.s.sol` runs the same flow on a local node with a mock verifier:

```bash
anvil &
ORACLE_SIGNER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

The key is anvil's first default account.

## Layout

```
src/          contracts; src/vendor/p384 is the vendored P-384 verifier
script/       forge scripts, including the ones above
test/         forge tests, mocks and P-384 test helpers
lib/          forge-std, nitro-prover and OpenZeppelin (submodules)
deployments/  addresses of an earlier Galleon testnet deployment
```

## License

Apache-2.0. See `LICENSE`.
