# Robinhood Milestone HODL Token (RMHT) — contracts

Smart contracts for **$RMHT**, deployed on Robinhood Chain (chain ID 4663).
Fork of the Milestone HODL Token model: an ERC-20 vault that releases tokens to
holders every time market cap crosses a new on-chain, TWAP-verified milestone.

## Deployed addresses — Robinhood Chain (chain ID 4663)

Deployed on **4 September 2026**. Configuration locked, then ownership renounced on all four contracts.

| Contract | Address |
|---|---|
| `RMHT` ($RMHT token) | [`0xbD4487dad62d23e0677E6a94c99cB0AE45328bA4`](https://robinhoodchain.blockscout.com/address/0xbD4487dad62d23e0677E6a94c99cB0AE45328bA4) |
| `RMHTAirdropCustodian` | [`0xdEc68344a41Cc6104ed5ff2C88F2D16a794688C1`](https://robinhoodchain.blockscout.com/address/0xdEc68344a41Cc6104ed5ff2C88F2D16a794688C1) |
| `RMHTFounderCustodian` | [`0x4C944c27160A1532b9De3a69d0Ec64164a6f03d8`](https://robinhoodchain.blockscout.com/address/0x4C944c27160A1532b9De3a69d0Ec64164a6f03d8) |
| `RMHTLiquidityCustodian` | [`0x50336e2a1396364895702a5222faC47bD0d38407`](https://robinhoodchain.blockscout.com/address/0x50336e2a1396364895702a5222faC47bD0d38407) |
| Uniswap V3 pool (RMHT/WETH) | [`0xabe3B1fF5Fc6a9638D0c46f2379B20f7e6173bEe`](https://robinhoodchain.blockscout.com/address/0xabe3B1fF5Fc6a9638D0c46f2379B20f7e6173bEe) |

All contracts are verified on Blockscout. Official site: [rmht.apexpad.io](https://rmht.apexpad.io) — any other $RMHT address is not ours.

This repository contains the contracts and their test suite only. Deployment
scripts, operational tooling, and transaction history are kept out of the
public repository intentionally (see below).

## Contracts (`src/`)

- `RMHT.sol` — ERC-20 token, milestone vault, TWAP oracle integration
- `RMHTAirdropCustodian.sol` — airdrop allocations, 1-year lock or milestone 5, whichever comes first
- `RMHTFounderCustodian.sol` — founder allocation, immutable 1-year lock, no early-release path
- `RMHTLiquidityCustodian.sol` — holds the Uniswap V3 liquidity position NFT, unruggable by design
- `libraries/UniswapV3TWAP.sol` — Solidity 0.8.36 port of Uniswap V3's TickMath + `consult()`

## Tests (`test/`)

Unit tests, fuzz tests, and invariant tests (`test/invariants/`, Foundry handler-based,
128 runs × 200 depth). Mocks used by the suite live in `test/mocks/`.

Two deployment-focused test files (`DeployMainnetAllocations.t.sol`,
`DeployMainnetPoolPrice.t.sol`) are excluded here because they import the
deployment script, which is not published — see below.

```bash
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
forge build
forge test
```

Toolchain: Foundry, solc 0.8.36 (pinned in `foundry.toml`), `evm_version = "osaka"`
(confirmed to match Robinhood Chain's ArbOS 61 "Elara" support — see comments in
`foundry.toml`).

## `echidna/`

Fuzzing harness for Echidna (`RMHTEchidnaInvariants_20260814_1543.sol`), points at
`../src/RMHT.sol`.

## `audit/`

Latest internal audit-tooling pass (Slither, Solhint, Sūrya, Aderyn, Mythril, Wake,
forge coverage). **This is not a third-party audit.** No professional third-party
audit of these contracts has been completed.

## What's not in this repository, and why

- **Deployment scripts** (`*.s.sol`) and **operational shell scripts** (`*.sh`) —
  they hardcode deployment-time parameters, RPC preferences, and operational
  sequencing that aren't useful outside the team running them, and separating
  them keeps this repo focused on the contracts themselves.
- **`broadcast/`** — on-chain transaction history from deployment and testing runs.
- **Two test files** that import the (unpublished) deployment script — see above.

## Status

- Live on Robinhood Chain mainnet (chain ID 4663).
- No privileged address anywhere in the protocol post-launch: ownership renounced
  on every contract, liquidity held by `RMHTLiquidityCustodian` (also renounced).
- No third-party audit completed. This repository's `audit/` folder reflects
  internal tooling only, not a professional review.
