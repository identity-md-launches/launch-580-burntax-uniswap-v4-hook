# Vendored dependencies

These are ordinary source files, not submodules. No package manager or network access is required to compile or run the tests. Only source and license files were copied; upstream CI, git metadata, configuration and tests were not installed. Files in the subsets below are unmodified upstream copies.

| Path | Upstream revision | Included subset | License |
| --- | --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75), `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | `src/` excluding `src/test/`, `licenses/` | See `licenses/` and per-file SPDX (BUSL-1.1 / MIT) |
| `lib/forge-std` | [foundry-rs/forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505), `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `src/`, root licenses | MIT / Apache-2.0 |
| `lib/openzeppelin-contracts` | [OpenZeppelin/openzeppelin-contracts v5.2.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/acd4ff74de833399287ed6b31b4debf6b2b35527), `acd4ff74de833399287ed6b31b4debf6b2b35527` | ERC20, IERC20, IERC20Metadata, Context, draft-IERC6093, LICENSE | MIT |
| `lib/solmate` | [transmissions11/solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647), `4b47a19038b798b4a33d9749d25e570443520647` | `src/auth/Owned.sol`, LICENSE; revision pinned by v4-core | AGPL-3.0-only root license; Owned.sol SPDX AGPL-3.0-only |

The real PoolManager used by tests inherits Solmate Owned for its own protocol-fee administration. Neither BurnTax contract inherits Owned or adds an administrator.
