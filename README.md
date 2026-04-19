# Kaskad Oracle Contracts

Solidity side of the Kaskad TEE Oracle stack. Verifies AWS Nitro
attestations, accepts EIP-191 signed price updates from an enclave-bound
signer, and exposes prices through a Chainlink-compatible
`AggregatorV3` wrapper.

The Rust enclave that produces these prices lives in a sibling
repository and consumes this one as a git submodule.

## Contracts

| Contract | Purpose |
|----------|---------|
| `src/KaskadPriceOracle.sol`      | Verifies EIP-191 signatures against a grow-only enclave-signer set, applies circuit breaker + freshness checks, stores per-asset price + round history. |
| `src/KaskadAggregatorV3.sol`     | Per-asset Chainlink `IAggregatorV3` adapter. |
| `src/KaskadRouter.sol`           | Atomic price-update + Aave action (borrow / withdraw / liquidate). |
| `src/NitroAttestationVerifier.sol` | Wraps Marlin NitroProver; enforces PCR0/PCR1/PCR2 match and a 4 h max attestation age. |
| `test/mocks/MockVerifiers.sol`   | Mock verifier used by `DeployLocal` and tests. **Never deploy to prod.** |

## Getting started

```bash
git clone --recursive git@github.com:Kaskad-Lending/kaskad-oracle-contracts.git
cd kaskad-oracle-contracts

forge build --sizes
forge test
```

If you forgot `--recursive`:

```bash
git submodule update --init --recursive
```

## Deploy

Two deploy entrypoints share a single base contract. The production
script uses the real Nitro stack; the local one swaps in
`MockAttestationVerifier` and inherits the rest.

### Local (anvil)

```bash
ORACLE_ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
ORACLE_SIGNER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### Production (real AWS Nitro)

```bash
DEPLOYER_KEY=0x... \
ORACLE_ADMIN=0x... \
ATTESTATION_DOC=0x... \
EXPECTED_PCR1=0x... \
EXPECTED_PCR2=0x... \
forge script script/Deploy.s.sol \
  --rpc-url <chain-rpc> \
  --broadcast
```

Both scripts perform the full bootstrap:

1. Deploy the attestation verifier (Nitro stack or mock).
2. Extract / pin PCR0 and deploy `KaskadPriceOracle`.
3. `registerEnclave(attestationDoc)` — adds the enclave signer to the
   grow-only `validSigner` set.
4. `registerAssets(...)` — commits per-asset quorum (`min_sources`)
   mirroring `config/assets.json` in the Rust enclave. Without this
   step `updatePrice` reverts with `AssetNotRegistered`.
5. Deploy the five `KaskadAggregatorV3` wrappers (ETH/BTC/KAS/USDC/IGRA).

## Layout

```
src/       # production contracts
test/      # forge tests + PoC regression guards
script/    # Deploy (prod) + DeployLocal (anvil)
lib/       # forge-std (vendored), nitro-prover + OpenZeppelin (submodules)
external/  # wrappers used by host integrations (Aave UI, etc.)
deployments/  # recorded per-network deploy addresses
```

## License

Apache-2.0.
