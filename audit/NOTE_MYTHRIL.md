# Why there are two Mythril logs in this folder

Short answer: the first run failed for a toolchain reason, the second one worked, and both are published rather than only the flattering one.

## `mythril.log` — the campaign as it actually ran

This is the Mythril step of the full audit campaign of **29 August 2026, 15:50**. In it, Mythril analysed only **1 of the 5 source files**.

The four others failed with `NameResolutionError`. The cause has nothing to do with the contracts: Mythril asks `py-solc-x` to fetch the Solidity compiler it needs, and `py-solc-x` still points at `solc-bin.ethereum.org`, a host that no longer resolves (the current one is `binaries.soliditylang.org`). No compiler, no analysis.

`RMHTLiquidityCustodian` is the one that passed, because it requires `--via-ir` and therefore goes through the bytecode branch of the script, which does not need that download.

## `mythril-corrected-2026-08-29_1609.log` — the repaired run

Same day, **16:09**, after copying the `solc 0.8.36` binary to `~/.solcx/solc-v0.8.36`, where `py-solc-x` looks before trying to download anything.

The four remaining files were analysed:

- `src/RMHT.sol`
- `src/RMHTAirdropCustodian.sol`
- `src/RMHTFounderCustodian.sol`
- `src/libraries/UniswapV3TWAP.sol`

All four returned **"The analysis was completed successfully. No issues were detected."** — no `NameResolutionError`, no `SolidityVersionMismatch`. Total runtime about 69 minutes.

Together, the two logs cover all five files.

## What "no issues were detected" is worth

Mythril prints that same line whether it explored the state space exhaustively **or** stopped on its execution timeout. On contracts of this size, bounded symbolic execution does not cover everything.

So the honest reading is **"nothing found within the budget given"**, not "proven sound". It is consistent with Slither, Wake and Aderyn, none of which found anything new either — but it is not a proof, and it is not presented as one.

## Reproducing it

The helper script used for the second run is `run_mythril_only_20260829_1710.sh` (not published here, it is operational tooling). It refuses to start unless `~/.solcx/solc-v0.8.36` exists, regenerates the remappings with `forge remappings`, then analyses the four source-mode files. `MYTHRIL_TIMEOUT=…` adjusts the timeout, which defaults to 600 seconds per file.
