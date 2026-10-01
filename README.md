# BurnTax

BurnTax is an immutable Uniswap v4 hook and a fixed-supply ERC-20. Every successful swap through this hook in a pool containing the configured token sends **1% of the gross BTAX leg**, rounded down in minor units, to `0x000000000000000000000000000000000000dEaD`. A buy receives BTAX; a sell pays BTAX. Currency ordering does not change that definition.

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

`Burned(bytes32 indexed poolId, bool indexed isBuy, uint256 amount)` identifies the full pool key by its v4 pool ID and reports the trader-facing direction and actual BTAX sent to DEAD. It is emitted once per successful relevant swap, including a zero amount when rounding produces no tax. It does not claim to identify the end user: v4's callback sender is normally a router. Unrelated pools return zero deltas and emit no burn event.

## Limits and integration responsibilities

- **Partial fills:** BTAX-specified trades (exact-input sells and exact-output buys) must fill completely, otherwise the transaction reverts with `PartialFillOnSpecifiedToken`, wrapped by v4. Their fee must be reserved in `beforeSwap`, and v4's `afterSwap` return can only adjust the other currency. Reverting avoids charging tax on unfilled volume. Exact-input buys and exact-output sells support partial fills and tax only executed volume. Integrators must enforce their required output and price limits.
- **Immediate transfer funding:** the PoolManager must already hold enough BTAX for `take` when the hook runs. Token-seeded launches satisfy this for the tested first buys, including a manager holding zero native ETH. If a sell starts with insufficient BTAX in the manager, its router must pre-settle sufficient BTAX inside the same unlock before calling `swap`, and settle/refund its remaining deltas afterward. Without that, the whole swap reverts; no burn remains. There are no deferred claims or redemption/withdraw functions. The test router demonstrates pre-settlement but is not a production router.
- **Rounding:** tax is floored, so a gross leg below 100 minor units can burn zero. Splitting extremely small swaps can reduce the rounded tax. No minimum tax is imposed.
- **Scope:** applies to every pool containing the configured token and this hook. Transfers, liquidity changes, donations, pools without BTAX, and BTAX pools using a different/no hook are untaxed. This is not an enforceable token-wide transfer tax.
- **Asset assumptions:** deploy with the supplied standard ERC-20 as `launchedToken`. Rebasing, transfer-tax, callback-enabled, paused or blocklisted substitutes are unsupported. The paired currency must also be compatible with v4; native ETH is supported. No fee is taken in ETH, and DEAD is only an ERC-20 recipient.
- **Numeric bounds:** BTAX-specified requests and their grossed-up amount must fit positive `int128`; larger requests revert explicitly. The token's whole supply is far below that bound.
- **Immutability:** no owner, roles, admin, fee setter, pause, upgrade, withdrawal or rescue. Tokens or ETH accidentally forced into the hook cannot be recovered. There is no keeper or maintenance transaction. PoolManager protocol-fee governance is external to these contracts.

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

The launch factory should deploy the hook and initialize its pool **atomically**. The initialization callback prevents initialization at the predicted address before code exists; it does not reserve initialization for an owner once code is deployed. Choose and review the initial price and liquidity allocation. The default launch assumption is LP fee **3000 (0.3%)**, tick spacing **60**, BTAX paired with the chain's chosen quote currency, with currencies sorted by address. Fees **500**, **3000** and **10000** are all accepted and tested; the hook neither sets nor overrides LP fees. This project does not impose an extra fee-tier restriction on unrelated pools.

No launch manifest, chain address, live pool price or liquidity allocation is invented here. If the launch process writes a manifest, its manager constructor argument must resolve from `$poolManager`, its token argument from the actual token deployment, and its hook flags from `0x20cc`.

## Design and accounting

The hook implements the three enabled IHooks selectors directly. Unsupported selectors revert. All callbacks authenticate `msg.sender == poolManager` and the pool key's hook address. The launch token and manager are immutable. No user identity, hook data, mutable fee state, oracle, external router or access-control list is used.

When BTAX is specified, `beforeSwap` returns the positive token fee as its specified delta and always returns zero LP-fee override. It reserves 1% on exact-input sells or grosses up exact-output buys. `afterSwap` verifies full execution, sends that reserved amount to DEAD, and returns zero to avoid a second charge. When BTAX is unspecified, `beforeSwap` returns zero; `afterSwap` computes the fee from the actual AMM delta and returns it as a positive unspecified delta.

For every successful swap, `take(BTAX, DEAD, fee)` debits the hook by `fee` and the return delta credits it by the same `fee`. The trader's token delta is reduced by `fee`; the quote delta is unchanged. The hook holds no swap proceeds or ERC-6909 claims. This follows the accounting in the pinned [v4 Hooks implementation](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/libraries/Hooks.sol) and [PoolManager](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/PoolManager.sol).

The high-risk `beforeSwapReturnDelta` permission is limited to this fixed fee: there is no custom AMM execution, whole-input capture, untrusted target call or administrative path. External token transfers go through the configured PoolManager to a constant recipient. The supplied token has no callbacks, and the hook has no mutable accounting state to reenter.

## Build and verification

```sh
forge build
forge test
forge fmt --check
```

All Solidity dependencies are ordinary vendored files with pinned upstream revisions in `DEPENDENCIES.md`. No dependency installation, RPC, keys, FFI, filesystem cheatcodes or environment variables are needed by the tests. The verifier needs Foundry and the pinned compiler already available; no compiler binary is bundled.

The tests deploy real v4 PoolManagers, actual CREATE2 hooks, and the fixed-supply token. They compare hooked swaps with identical plain pools, checking both currency orderings, all four modes, exact amounts, rounding boundaries, events, DEAD balances, pool LP fees, unrelated pools, initialization permissions, liquidity removal, settlement and slippage rollback, malformed/oversized requests, partial fills, and token-only/quote-only fresh managers. Fuzz tests cover amounts and modes. Stateful invariants check supply conservation, cumulative burn, and zero unsettled deltas/claims over repeated mixed swaps.

Before public use, the operator is responsible for independent adversarial review, verifying deployed bytecode and arguments, rehearsing with the actual chain's manager and production router, setting user-facing slippage bounds, atomic pool initialization, and monitoring burn events. This assignment performs local tests and source review; it does not deploy, execute a fork rehearsal, or claim an external security audit or formal verification.
