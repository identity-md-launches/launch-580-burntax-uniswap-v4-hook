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

The revised campaign also mixes deferred exact-input sells with these existing
actions. It leaves BTAX synchronized across the swap, then checks delivery to
DEAD after input settlement, including repeated completion. Attempts to omit
completion or call it while BTAX is still synchronized must revert atomically.
Random idle completion calls must preserve donations and cannot replay a burn.
The existing independent balance ledgers and event oracle cover these new actions;
both settlement routers must finish with zero balances and currency deltas.

A deterministic reachability test drives all nine handler entry points, every
trade mode, all actors, and every donation destination. Expected reverts are
checked inside the handler; unexpected reverts fail the invariant campaign.
Run counts are inline on the concrete test contracts so they apply to inherited
test functions without editing `foundry.toml`.

`DeferredBurnProperties.t.sol` checks an open BTAX sync across all four modes in
both currency orderings, including buys where BTAX is the output. It verifies
the interim hook credit against the manager's swap event, confirms that closing
the sync credits zero payment, and requires actual token delivery exactly once
before unlock returns. Each ordering runs 1,000 fuzz cases, deterministic minor-unit
rounding boundaries, and rollback checks when completion is omitted in each mode.

## Limits and settlement requirements

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
- The earlier DEAD-balance finding is resolved in the current implementation.
  `FreshManager.t.sol` verifies that selling `1e18` BTAX into a fresh ETH-only
  position now sends `1e16` actual BTAX to DEAD. The hook no longer substitutes
  ERC-6909 claims for token delivery; the suite requires zero claims for DEAD
  and the hook.
- If the manager lacks BTAX before input settlement or a BTAX sync is open,
  delivery is deferred as a positive hook currency delta. The router must close
  that sync, settle input, and call `settleBurn()` inside the same unlock.
  Omitting completion reverts with `CurrencyNotSettled`; premature completion
  with outstanding credit reverts with `OpenTokenSync`. Generic routers that
  omit this integration cannot execute deferred burns. Repeated completion
  neither pays the caller nor charges the trader twice.
- Fresh-manager reserve exhaustion is covered by deterministic regressions.
  Random sequences cover funded immediate and open-sync deferred settlement;
  their bounded trades do not exhaust the base position. Local passing results
  do not establish production-router compatibility or a live-chain rehearsal.

## Verification

From the repository root:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

The output/cache flags keep generated files inside the assignment's scratch
directory; they do not alter compilation or test semantics. Plain `forge build`
and `forge test` work with the existing project settings as well.

Local tooling: Foundry 1.8.3, Solidity 0.8.26, Cancun EVM. This revision extends
the accepted stateful suite, adds deferred-settlement properties, and corrects
the obsolete finding description. No source contract, configuration, or vendored
dependency is changed.
