# BurnTax

BurnTax is an immutable Uniswap v4 hook and a fixed-supply ERC-20. Every successful swap through this hook in a pool containing the configured token sends **1% of the gross BTAX leg**, rounded down in minor units, as actual BTAX to `0x000000000000000000000000000000000000dEaD` before the PoolManager unlock completes. Deferred delivery requires the router settlement integration below. A buy receives BTAX; a sell pays BTAX. Currency ordering does not change that definition.

`BurnTaxToken` has name **BurnTax**, symbol **BTAX**, 18 decimals, and exactly **1,000,000,000 tokens (10^27 minor units)** minted to its constructor caller. It has no constructor arguments and no further mint function. Ordinary transfers have no tax. Sending tokens to DEAD locks them there under the usual assumption that nobody controls that address; it **does not reduce ERC-20 `totalSupply()`**.

## Swap rule

The 1% is a split of the gross token amount: gross buy output before deduction, or the seller's total token payment including tax. The LP fee remains the pool's own fee and is separate. All arithmetic below uses token minor units and floors division.

| Trade | AMM execution | Burn | Trader result |
| --- | --- | --- | --- |
| Buy, exact input | Spend specified quote input; AMM outputs `G` BTAX | `G / 100` | Receives `G - burn` BTAX |
| Buy, exact output `N` BTAX | Request `N + N / 99` BTAX from AMM | `N / 99` | Receives exactly `N` BTAX |
| Sell, exact input `G` BTAX | Send `G - G / 100` BTAX into AMM | `G / 100` | Pays exactly `G` BTAX |
| Sell, exact output | AMM requires `P` BTAX input for specified quote output | `P / 99` | Pays `P + burn` BTAX |

For example, a sell with 100 BTAX exact input burns 1 BTAX and sends 99 BTAX into the pool. A buy for exactly 99 BTAX requests 100 BTAX from the pool, burns 1 and delivers 99. A sell whose AMM input is 99 BTAX costs 100 BTAX including the 1 BTAX burn. The `/99` gross-up ensures the burn is 1% of the total token leg rather than adding 1% of a smaller base.

`Burned(bytes32 indexed poolId, bool indexed isBuy, uint256 amount)` identifies the full pool key by its v4 pool ID and reports the trader-facing direction and BTAX units sent to DEAD. It is emitted once per successful relevant swap, including a zero amount when rounding produces no tax. The log precedes delivery when settlement is deferred, but can commit only if delivery completes within the same unlock; otherwise the swap and its logs revert. It does not claim to identify the end user: v4's callback sender is normally a router. Unrelated pools return zero deltas and emit no burn event.

## Limits and integration responsibilities

- **Partial fills:** BTAX-specified trades (exact-input sells and exact-output buys) must fill completely, otherwise the transaction reverts with `PartialFillOnSpecifiedToken`, wrapped by v4. Their fee must be reserved in `beforeSwap`, and v4's `afterSwap` return can only adjust the other currency. Reverting avoids charging tax on unfilled volume. Exact-input buys and exact-output sells support partial fills and tax only executed volume. Integrators must enforce their required output and price limits.
- **Burn funding and mandatory completion:** the hook uses `take` to transfer BTAX directly when the manager holds at least the burn amount and has no open BTAX `sync`. Otherwise it leaves the tax as a positive hook currency delta, without minting claims. The router must call `hook.settleBurn()` after settling input and closing any BTAX sync, **inside the same unlock callback**. That function sends the outstanding credit only to DEAD. It is permissionless, has no configurable recipient, and cannot pay the caller. The manager refuses to finish the unlock while any hook credit remains: omitting delivery reverts the whole transaction, including payment and events. A later keeper call cannot complete an earlier swap. Monitor `BTAX.balanceOf(DEAD)` and burn events; ERC-6909 claims are never used.
- **Settlement ordering and router compatibility:** v4 has no post-settlement hook callback. Generic routers that omit `settleBurn()` can still execute directly funded burns, but revert with `CurrencyNotSettled` on deferred burns, including fresh-manager sells and open BTAX syncs. Integrate the call for reliable support of every swap mode. Pre-settlement is optional; if used, close `sync → transfer → settle` before swapping, then settle/refund remaining deltas. Open BTAX syncs across a swap are supported when the router closes them before finalization; early finalization reverts with `OpenTokenSync`. Calls with no outstanding credit do nothing, and repeating completion cannot charge twice. Each call drains at most `type(int128).max` minor units, matching v4's `take` limit; repeat for larger batched credits. The supplied token's entire supply is much smaller. Routers remain responsible for slippage, correct synchronization and final settlement; the included routers are test helpers, not production routers.
- **Rounding:** tax is floored, so a gross leg below 100 minor units can burn zero. Splitting extremely small swaps can reduce the rounded tax. No minimum tax is imposed.
- **Scope:** applies to every pool containing the configured token and this hook. Transfers, liquidity changes, donations, pools without BTAX, and BTAX pools using a different/no hook are untaxed. This is not an enforceable token-wide transfer tax.
- **Asset assumptions:** deploy with the supplied standard ERC-20 as `launchedToken`. Rebasing, transfer-tax, callback-enabled, paused or blocklisted substitutes are unsupported. The paired currency must also be compatible with v4; native ETH is supported. No fee is taken in ETH; DEAD receives only BTAX, so its ability to receive ETH is irrelevant.
- **Numeric bounds:** BTAX-specified requests and their grossed-up amount must fit positive `int128`; larger requests revert explicitly. The token's whole supply is far below that bound.
- **Immutability:** no owner, roles, admin, fee setter, pause, upgrade, withdrawal or rescue. Tokens or ETH accidentally forced into the hook cannot be recovered. There is no keeper or maintenance transaction. PoolManager protocol-fee governance is external to these contracts.

The integration point is after normal settlement, before returning from the router's authenticated `unlockCallback`:

```solidity
BalanceDelta delta = manager.swap(key, params, hookData);
// Enforce slippage, settle all input debts, take outputs and close any BTAX sync.
settleCurrency(key.currency0);
settleCurrency(key.currency1);
hook.settleBurn(); // actual deferred BTAX delivery; no-op if already delivered
return abi.encode(delta);
```

For batched swaps, finalize every BurnTax hook involved before returning. See `test/helpers/PoolRouter.sol` for swap-then-settle integration and `test/Settlement.t.sol` for open-sync and batched settlement examples. The manager's positive hook credit remains mandatory even if an untrusted router attempts to skip this step.

## Contracts and deployment parameters

| Artifact | Constructor | Purpose |
| --- | --- | --- |
| `src/BurnTaxToken.sol:BurnTaxToken` | None | Mints the full supply to its deployer, normally the launch factory |
| `src/BurnTaxHook.sol:BurnTaxHook` | `(IPoolManager manager_, address token_)` | Fixes the chain's manager and the deployed BTAX token permanently |
| `script/MineHook.s.sol:MineHook` | None | Offline salt search; no deployment or broadcasting |

Use Solidity **0.8.26**, the settings in `foundry.toml`, and a chain supporting **Cancun** (v4 requires transient storage). Supply and independently verify the destination chain's genuine PoolManager; no manager address is hardcoded. Both constructor addresses must be nonzero. Constructor code does not attest that those addresses contain the intended code; verifying them is the deployer's responsibility.

Deploy the token first. Mine the hook's CREATE2 address using the actual CREATE2 deployer and the exact creation bytecode plus ABI-encoded constructor arguments. Its low 14 address bits must equal **`0x20cc` (8396)**. This enables `beforeInitialize`, `beforeSwap`, `afterSwap`, and the two swap-return-delta flags. Every other flag is false. The hook constructor checks that its address matches these permissions.

The included miner takes explicit arguments and runs locally, for example:

```sh
forge script script/MineHook.s.sol:MineHook \
  --sig 'run(address,address,address,uint256,uint256)' \
  <CREATE2_DEPLOYER> <POOL_MANAGER> <BTAX_TOKEN> 0 200000
```

Replace the placeholders with reviewed addresses. If the search is exhausted, continue from the next salt range. Use the returned salt and identical init code with the chosen CREATE2 factory; a factory that transforms salts needs its own address calculation. Remine after any bytecode, compiler-setting, deployer or constructor-argument change. `test/Deployment.t.sol` tests the miner's result against an actual CREATE2 deployment.

The launch factory should deploy the hook and initialize its pool **atomically**. The initialization callback prevents initialization at the predicted address before code exists; it does not reserve initialization for an owner once code is deployed. Choose and review the initial price and liquidity allocation. The default launch assumption is LP fee **3000 (0.3%)**, tick spacing **60**, BTAX paired with the chain's chosen quote currency, with currencies sorted by address. Launch fees **500**, **3000** and **10000** are all accepted and tested; the hook neither sets nor overrides LP fees. Other static fees allowed by v4 remain accepted by the contract, although they are outside the launch policy. BTAX pools with the dynamic-fee flag revert with `UnsupportedFee`: this immutable hook has no dynamic-fee updater, which would leave those pools at zero LP fee forever. Pools without BTAX retain their existing initialization behavior, including dynamic fees.

No launch manifest, chain address, live pool price or liquidity allocation is invented here. If the launch process writes a manifest, its manager constructor argument must resolve from `$poolManager`, its token argument from the actual token deployment, and its hook flags from `0x20cc`.

## Design and accounting

The hook implements the three enabled IHooks selectors directly. Unsupported selectors revert. All callbacks authenticate `msg.sender == poolManager` and the pool key's hook address. The launch token and manager are immutable. No user identity, hook data, mutable fee state, oracle, external router or access-control list is used.

When BTAX is specified, `beforeSwap` returns the positive token fee as its specified delta and always returns zero LP-fee override. It reserves 1% on exact-input sells or grosses up exact-output buys. `afterSwap` verifies full execution, transfers the reserved amount to DEAD if safe (otherwise defers delivery until settlement), and returns zero to avoid a second charge. When BTAX is unspecified, `beforeSwap` returns zero; `afterSwap` computes the fee from the actual AMM delta and returns it as a positive unspecified delta.

For every successful swap, `take(BTAX, DEAD, fee)` debits the hook by `fee` and the return delta credits it by the same `fee`. The take occurs immediately or in `settleBurn()` after funding. The trader's token delta is reduced by `fee`; the quote delta is unchanged. Only the hook can debit its own positive currency delta, and its only completion path sends actual BTAX to DEAD. There are no claims or persistent pending-burn balances. Failed settlement, missing finalization or slippage checks roll back token transfers and events atomically. This follows the accounting in the pinned [v4 Hooks implementation](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/libraries/Hooks.sol) and [PoolManager](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/PoolManager.sol).

The high-risk `beforeSwapReturnDelta` permission is limited to this fixed fee: there is no custom AMM execution, whole-input capture, untrusted target call or administrative path. External token transfers go through the configured PoolManager to a constant recipient. The supplied token has no callbacks, and the hook has no mutable accounting state to reenter.

## Build and verification

```sh
forge build
forge test
forge fmt --check
```

All Solidity dependencies are ordinary vendored files with pinned upstream revisions in `DEPENDENCIES.md`. No dependency installation, RPC, keys, FFI, filesystem cheatcodes or environment variables are needed by the tests. The verifier needs Foundry and the pinned compiler already available; no compiler binary is bundled.

The tests deploy real v4 PoolManagers, actual CREATE2 hooks, and the fixed-supply token. They compare hooked swaps with identical plain pools, checking both currency orderings, all four modes, exact amounts, rounding boundaries, events, DEAD balances, pool LP fees, unrelated pools, initialization permissions, liquidity removal, settlement and slippage rollback, malformed/oversized requests, partial fills, and token-only/quote-only fresh managers. Regression tests cover sells after buying out the launch range, both sides of the reserve/fee boundary, immediate and deferred actual BTAX delivery, rollback and access control, open BTAX sync settlement, missing/early/repeated finalization, batched burns, and dynamic-fee rejection. Fuzz tests cover amounts and modes. Stateful invariants check supply conservation, cumulative burn, and zero unsettled deltas/hook-owned claims over repeated mixed swaps.

Before public use, the operator is responsible for independent adversarial review, verifying deployed bytecode and arguments, integrating and rehearsing `settleBurn()` with the actual chain's manager and production router (including a zero-BTAX-reserve sell), setting user-facing slippage bounds, atomic pool initialization, and monitoring burn events. This assignment performs local tests and source review; it does not deploy, execute a fork rehearsal, or claim an external security audit or formal verification.
