// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {BurnAssertions} from "./helpers/BurnAssertions.sol";
import {BurnTaxHook} from "src/BurnTaxHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Opens a BTAX sync with no payment across either swap direction. In particular,
/// buys must not take output or burn from the synced balance until that sync is closed.
contract DeferredBurnRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct Result {
        BalanceDelta delta;
        int256 pendingBurn;
        uint256 deadDuringSwap;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bool complete)
        external
        returns (Result memory)
    {
        return abi.decode(manager.unlock(abi.encode(msg.sender, key, params, complete)), (Result));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (address payer, PoolKey memory key, SwapParams memory params, bool complete) =
            abi.decode(data, (address, PoolKey, SwapParams, bool));
        BurnTaxHook hook = BurnTaxHook(address(key.hooks));
        Currency taxed = Currency.wrap(hook.launchedToken());
        manager.sync(taxed);
        Result memory result;
        result.delta = manager.swap(key, params, "");
        result.pendingBurn = manager.currencyDelta(address(hook), taxed);
        result.deadDuringSwap = taxed.balanceOf(hook.DEAD());
        require(manager.settle() == 0, "swap corrupted the open BTAX sync");
        _settle(key.currency0, payer);
        _settle(key.currency1, payer);
        if (complete) {
            hook.settleBurn();
            hook.settleBurn();
        }
        return abi.encode(result);
    }

    function _settle(Currency currency, address payer) internal {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(delta));
        }
    }
}

abstract contract DeferredBurnProperties is HookFixture, BurnAssertions {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    DeferredBurnRouter internal deferredRouter;

    function _setupDeferred(bool tokenFirst) internal {
        _setup(tokenFirst);
        deferredRouter = new DeferredBurnRouter(manager);
        token.approve(address(deferredRouter), type(uint256).max);
        quote.approve(address(deferredRouter), type(uint256).max);
    }

    function testFuzz_openTokenSyncDefersOnlyTheExecutedBurn(uint96 seed, bool buy, bool exactInput) public {
        _checkDeferred(bound(seed, 1, 1e21), buy, exactInput);
    }

    function test_allModesAndRoundingEdgesDeliverActualTokens() public {
        uint256[5] memory amounts = [uint256(1), 99, 100, 101, 1 ether];
        for (uint256 mode; mode < 4; ++mode) {
            for (uint256 i; i < amounts.length; ++i) {
                _checkDeferred(amounts[i], mode % 2 == 0, mode < 2);
            }
        }
    }

    function _checkDeferred(uint256 amount, bool buy, bool exactInput) internal {
        uint256 beforeToken = token.balanceOf(address(this));
        uint256 beforeQuote = quote.balanceOf(address(this));
        uint256 beforeDead = token.balanceOf(DEAD);
        vm.recordLogs();
        DeferredBurnRouter.Result memory result =
            deferredRouter.swap(key, _params(buy, exactInput, amount), true);
        uint256 burn = _assertSwapLogs(
            vm.getRecordedLogs(), key, address(manager), address(deferredRouter), tokenIs0, buy, result.delta
        );
        assertEq(result.pendingBurn, int256(burn), "entire tax remains mandatory until settlement");
        assertEq(result.deadDuringSwap, beforeDead, "no burn during an open BTAX sync");
        assertEq(token.balanceOf(DEAD) - beforeDead, burn, "completion delivers BTAX exactly once");
        int256 tokenDelta = tokenIs0 ? int256(result.delta.amount0()) : int256(result.delta.amount1());
        int256 quoteDelta = tokenIs0 ? int256(result.delta.amount1()) : int256(result.delta.amount0());
        assertEq(int256(token.balanceOf(address(this))) - int256(beforeToken), tokenDelta);
        assertEq(int256(quote.balanceOf(address(this))) - int256(beforeQuote), quoteDelta);
        assertEq(
            exactInput ? (buy ? -quoteDelta : -tokenDelta) : (buy ? tokenDelta : quoteDelta), int256(amount)
        );
        _assertSettled();
    }

    function test_omittingCompletionCannotCommitAnyMode() public {
        for (uint256 mode; mode < 4; ++mode) {
            bytes32 beforeState = _stateDigest();
            vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
            deferredRouter.swap(key, _params(mode % 2 == 0, mode < 2, 1 ether), false);
            assertEq(_stateDigest(), beforeState, "failed completion rolls back pool and token accounting");
            _assertSettled();
        }
    }

    function _assertSettled() internal view {
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(manager).isUnlocked());
        assertEq(manager.balanceOf(DEAD, uint160(address(token))), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(deferredRouter)), 0);
        assertEq(quote.balanceOf(address(deferredRouter)), 0);
    }

    function _stateDigest() internal view returns (bytes32) {
        (uint160 price, int24 tick,,) = IPoolManager(manager).getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = IPoolManager(manager).getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                growth0,
                growth1,
                token.balanceOf(address(this)),
                quote.balanceOf(address(this)),
                token.balanceOf(address(manager)),
                quote.balanceOf(address(manager)),
                token.balanceOf(DEAD)
            )
        );
    }
}

/// forge-config: default.fuzz.runs = 1000
contract DeferredBurnToken0Test is DeferredBurnProperties {
    function setUp() public {
        _setupDeferred(true);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract DeferredBurnToken1Test is DeferredBurnProperties {
    function setUp() public {
        _setupDeferred(false);
    }
}
