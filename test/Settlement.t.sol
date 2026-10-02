// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Keeps the input sync/settle pair open across an exact-input swap.
contract OpenSyncRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    enum Mode {
        Complete,
        Omit,
        BeforeSettle,
        Twice
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return
            abi.decode(manager.unlock(abi.encode(msg.sender, key, params, Mode.Complete, 1)), (BalanceDelta));
    }

    function swapWithMode(PoolKey memory key, SwapParams memory params, Mode mode, uint256 count)
        external
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(msg.sender, key, params, mode, count)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address payer, PoolKey memory key, SwapParams memory params, Mode mode, uint256 count) =
            abi.decode(data, (address, PoolKey, SwapParams, Mode, uint256));
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        uint256 amount = uint256(-params.amountSpecified) * count;
        manager.sync(input);
        require(IERC20(Currency.unwrap(input)).transferFrom(payer, address(manager), amount));
        BalanceDelta delta;
        for (uint256 i; i < count; ++i) {
            delta = delta + manager.swap(key, params, "");
        }
        BurnTaxHook hook = BurnTaxHook(address(key.hooks));
        if (mode == Mode.BeforeSettle) hook.settleBurn();
        require(manager.settle() == amount, "input settlement under-credited");
        if (mode != Mode.Omit) hook.settleBurn();
        if (mode == Mode.Twice) hook.settleBurn();
        int128 received = params.zeroForOne ? delta.amount1() : delta.amount0();
        manager.take(output, payer, uint256(int256(received)));
        return abi.encode(delta);
    }
}

abstract contract SettlementTests is HookFixture {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    function test_openTokenSyncAcrossSellPreservesFullSettlement() public {
        OpenSyncRouter openRouter = new OpenSyncRouter(manager);
        token.approve(address(openRouter), 1 ether);
        uint256 beforeToken = token.balanceOf(address(this));
        uint256 beforeQuote = quote.balanceOf(address(this));
        uint256 beforeManager = token.balanceOf(address(manager));
        BalanceDelta delta = openRouter.swap(key, _params(false, true, 1 ether));
        assertEq(beforeToken - token.balanceOf(address(this)), 1 ether);
        assertEq(token.balanceOf(address(manager)) - beforeManager, 0.99 ether);
        assertEq(token.balanceOf(DEAD), 0.01 ether);
        assertEq(manager.balanceOf(DEAD, uint160(address(token))), 0);
        assertEq(tokenIs0 ? delta.amount0() : delta.amount1(), -1 ether);
        assertEq(
            quote.balanceOf(address(this)) - beforeQuote,
            uint256(int256(tokenIs0 ? delta.amount1() : delta.amount0()))
        );
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(manager).isUnlocked());
    }

    function test_omittingDeferredBurnRevertsEntireSwap() public {
        OpenSyncRouter openRouter = new OpenSyncRouter(manager);
        token.approve(address(openRouter), 1 ether);
        uint256 beforeToken = token.balanceOf(address(this));
        uint256 beforeManager = token.balanceOf(address(manager));
        (uint160 beforePrice,,,) = IPoolManager(manager).getSlot0(key.toId());
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        openRouter.swapWithMode(key, _params(false, true, 1 ether), OpenSyncRouter.Mode.Omit, 1);
        assertEq(token.balanceOf(address(this)), beforeToken);
        assertEq(token.balanceOf(address(manager)), beforeManager);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(manager.balanceOf(DEAD, uint160(address(token))), 0);
        (uint160 afterPrice,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(afterPrice, beforePrice);
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(manager).isUnlocked());
    }

    function test_cannotFinalizeDuringOpenTokenSync() public {
        OpenSyncRouter openRouter = new OpenSyncRouter(manager);
        token.approve(address(openRouter), 1 ether);
        vm.expectRevert(BurnTaxHook.OpenTokenSync.selector);
        openRouter.swapWithMode(key, _params(false, true, 1 ether), OpenSyncRouter.Mode.BeforeSettle, 1);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
    }

    function test_finalizeBatchedBurnsOnceWithoutDoubleCharging() public {
        OpenSyncRouter openRouter = new OpenSyncRouter(manager);
        token.approve(address(openRouter), 2 ether);
        uint256 beforeToken = token.balanceOf(address(this));
        uint256 beforeManager = token.balanceOf(address(manager));
        BalanceDelta delta =
            openRouter.swapWithMode(key, _params(false, true, 1 ether), OpenSyncRouter.Mode.Twice, 2);
        assertEq(tokenIs0 ? delta.amount0() : delta.amount1(), -2 ether);
        assertEq(beforeToken - token.balanceOf(address(this)), 2 ether);
        assertEq(token.balanceOf(address(manager)) - beforeManager, 1.98 ether);
        assertEq(token.balanceOf(DEAD), 0.02 ether);
        assertEq(manager.balanceOf(DEAD, uint160(address(token))), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(manager).isUnlocked());
        // A later arbitrary caller cannot collect, repeat or redirect a completed burn.
        vm.prank(address(0xBEEF));
        hook.settleBurn();
        assertEq(token.balanceOf(DEAD), 0.02 ether);
        assertEq(token.balanceOf(address(0xBEEF)), 0);
    }
}

contract SettlementToken0Test is SettlementTests {
    function setUp() public {
        _setup(true);
    }
}

contract SettlementToken1Test is SettlementTests {
    function setUp() public {
        _setup(false);
    }
}
