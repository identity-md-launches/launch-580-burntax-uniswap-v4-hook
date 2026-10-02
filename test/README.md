# BurnTax test suite

The assignment's rule is a fixed 1% of the gross BTAX leg, floored in token minor
units, sent to `0x000000000000000000000000000000000000dEaD`. A buy receives BTAX;
a sell pays BTAX, regardless of currency ordering. The pool's LP fee is separate
and unchanged. `Burned(poolId, isBuy, amount)` must describe the executed trade.
The ERC-20 has name BurnTax, symbol BTAX, and a fixed supply of 1,000,000,000 tokens
with 18 decimals. Transfers to DEAD do not reduce `totalSupply()`.

| Mode | Trader-facing result |
| --- | --- |
| Exact-input buy | Pays the specified quote; receives AMM BTAX output minus its 1% burn |
| Exact-output buy | Receives the specified net BTAX; AMM output includes the burn |
| Exact-input sell | Pays the specified gross BTAX; the remainder after the burn enters the AMM |
| Exact-output sell | Receives the specified quote; pays AMM BTAX input plus the burn |

## Additions to the accepted suite

`BurnTaxProperties.t.sol` runs with BTAX in both currency positions. Its 1,000-run
fuzz property compares the manager's actual pre-hook `Swap` event with the
router's returned deltas, trader balances, the hook's event, and DEAD's token
balance. It uses executed buy output or observed seller payment as the tax base;
it does not copy the hook's `/99` gross-up calculation. Zero, partial, and excess
input prefunding exercise settlement and refunds. The shared event assertions
also check the emitter, full pool ID, direction, LP fee, event count, and the
unchanged quote leg.

Failure tests require the precise allowance, balance, price-limit, or slippage
error and check rollback of balances, burn/claim balances, pool price, ticks,
fee growth, and settlement state. An empty-liquidity test checks that quote-specified
swaps cannot generate a phantom burn. Existing deterministic rounding, permission,
unrelated-pool, fresh-manager, partial-fill, and deployment tests are retained.

`StatefulBurnTax.t.sol` adds three funded actors in each token ordering, with
256 sequences of depth 64 per invariant. Random actions cover all four swap
modes, input prefunding, buy/sell round trips, ordinary transfers, direct
donations to DEAD/the hook, liquidity additions and removals, allowance failures,
and unauthorized mint attempts. Inputs include one minor unit and rounding dust;
trade amounts are bounded to `1e20`, and liquidity additions to `1e21`. Against
`1e24` base liquidity and `1e24` of each asset per actor, these bounds let every
sequence execute within the funded range instead of mostly reverting. Extreme
amounts, exhaustion, and partial fills remain covered by deterministic tests.

The stateful properties check:

- Fixed supply and conservation across every funded holder, manager, DEAD, and hook.
- Each actor's independent running BTAX and quote balance ledger.
- Cumulative per-swap tax, separately from voluntary transfers to DEAD.
- No swap proceeds retained by the hook; only tracked unsolicited donations remain there.
- Exact requested amounts, correct events, and no profitable immediate buy/sell round trip.
- No stranded router balances, hook claims, unsettled currency deltas, or unlocked manager.
- Unchanged LP fee and position liquidity matching the handler's ledger.
- Successful full withdrawal of every generated LP position after each campaign.

A deterministic reachability test drives all six handler entry points, every
trade mode, all actors, and every donation destination. Expected reverts are
checked inside the handler; unexpected reverts fail the invariant campaign.
Run counts are inline on the concrete test contracts so they apply to inherited
test functions without editing `foundry.toml`.

## Limits and reported discrepancy

- The suite uses actual vendored Uniswap v4 `PoolManager` bytecode, mined CREATE2
  hooks, the production token, and a standard mock quote token. No RPC, fork,
  FFI, environment mutation, dependency installation, or network is needed.
  Production routers and live chain deployment have not been rehearsed here.
- The tax is per swap and floors to minor units. Gross amounts below 100 units
  can burn zero; splitting dust trades can reduce rounded tax. Ordinary token
  transfers, liquidity operations, unrelated pools, and pools with no hook are
  untaxed. This is not a token-wide transfer tax.
- The implementation rejects partial fills when BTAX is the specified currency
  (exact-input sells and exact-output buys). The accepted tests document this
  restriction. Quote-specified trades tax only the executed amount.
- **Reported medium finding:** if the manager lacks BTAX before settlement, or
  a BTAX sync is open, the hook assigns ERC-6909 claims to DEAD instead of sending
  BTAX there. Those claims lock backing value, but DEAD's ERC-20 balance does not
  receive the promised tax. There is no redemption path that subsequently sends
  that BTAX to DEAD. The inherited README and tests describe/accept this alternative;
  this contribution reports the mismatch with the assignment instead of adding
  new tests that treat it as the requested token transfer.
- The independently runnable failing test is embedded in the root
  `.imd-findings.json` report. On a fresh ETH-only position, a successful sale of
  `1e18` BTAX delivers `0` to DEAD instead of `1e16`. It was run and failed on the
  unmodified implementation. Its source stays outside the passing delivered
  `.t.sol` files. Restore the report's `proof` as
  `test/scratch/DeadBalanceProof.t.sol` and run `forge test --match-path` on that
  path to reproduce. Scratch files are removed by the verifier.
- The new stateful campaign covers the funded, closed-sync transfer path.
  Underfunded and open-sync paths are covered by the inherited examples and the
  reported failing proof; passing these invariants does not resolve that finding.

## Verification

From the repository root:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

The output/cache flags keep generated files inside the assignment's scratch
directory; they do not alter compilation or test semantics. Plain `forge build`
and `forge test` work with the existing project settings as well.

Implementation reviewed: `97d845ba4955869dfdd3e0109b4c50f025daff6f`.
Local tooling: Foundry 1.7.1, Solidity 0.8.26, Cancun EVM. No source contract,
configuration, vendored dependency, or existing accepted test was changed.
