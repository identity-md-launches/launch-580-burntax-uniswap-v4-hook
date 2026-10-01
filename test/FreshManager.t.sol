// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {BurnTaxToken} from "../src/BurnTaxToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract FreshManagerTest is HookFixture {
    function _fresh(bool tokensOnly) internal {
        manager = new PoolManager(address(this));
        router = new PoolRouter(manager);
        token = new BurnTaxToken();
        tokenIs0 = false;
        hook = _deployHook(manager, address(token));
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook))
        );
        manager.initialize(key, PRICE);
        token.approve(address(router), token.totalSupply());
        vm.deal(address(this), 100 ether);
        if (tokensOnly) {
            router.modify(key, ModifyLiquidityParams(-120, -60, 1e22, bytes32(0)));
            assertEq(address(manager).balance, 0);
            assertGt(token.balanceOf(address(manager)), 0);
        } else {
            router.modify{value: 100 ether}(key, ModifyLiquidityParams(60, 120, 1e22, bytes32(0)));
            assertEq(token.balanceOf(address(manager)), 0);
            assertGt(address(manager).balance, 0);
        }
    }

    function test_firstBuyExactInputOnTokenOnlyFreshManager() public {
        _fresh(true);
        uint256 beforeToken = token.balanceOf(address(this));
        BalanceDelta delta = router.swap{value: 1 ether}(key, _params(true, true, 1 ether), 0, 1 ether, 0);
        uint256 net = token.balanceOf(address(this)) - beforeToken;
        uint256 burned = token.balanceOf(DEAD);
        assertGt(net, 0);
        assertGt(burned, 0);
        assertEq(burned, (net + burned) / 100);
        assertEq(delta.amount0(), -1 ether);
        assertEq(address(manager).balance, 1 ether);
        assertEq(address(DEAD).balance, 0);
    }

    function test_firstBuyExactOutputOnTokenOnlyFreshManager() public {
        _fresh(true);
        BalanceDelta delta =
            router.swap{value: 2 ether}(key, _params(true, false, 1 ether), 1 ether, 2 ether, 0);
        assertEq(delta.amount1(), 1 ether);
        assertEq(token.balanceOf(DEAD), uint256(1 ether) / 99);
        assertEq(address(manager).balance, uint256(-int256(delta.amount0())));
    }

    function test_sellWithoutReservesOrPrefundingRevertsAtomically() public {
        _fresh(false);
        uint256 nativeBefore = address(manager).balance;
        uint256 tokenBefore = token.balanceOf(address(this));
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        router.swap(key, _params(false, true, 1 ether), 0, 1 ether, 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(this)), tokenBefore);
        assertEq(address(manager).balance, nativeBefore);
    }

    function test_sellExactInputIntoQuoteOnlyPoolWithPrefunding() public {
        _fresh(false);
        uint256 beforeToken = token.balanceOf(address(this));
        BalanceDelta delta = router.swap(key, _params(false, true, 1 ether), 0, 1 ether, 1 ether);
        assertEq(delta.amount1(), -1 ether);
        assertGt(delta.amount0(), 0);
        assertEq(token.balanceOf(DEAD), 0.01 ether);
        assertEq(token.balanceOf(address(manager)), 0.99 ether);
        assertEq(beforeToken - token.balanceOf(address(this)), 1 ether);
    }

    function test_sellExactOutputIntoQuoteOnlyPoolWithPrefunding() public {
        _fresh(false);
        uint256 beforeToken = token.balanceOf(address(this));
        BalanceDelta delta = router.swap(key, _params(false, false, 1 ether), 1 ether, 2 ether, 2 ether);
        uint256 paid = beforeToken - token.balanceOf(address(this));
        assertEq(delta.amount0(), 1 ether);
        assertEq(token.balanceOf(DEAD), paid / 100);
        assertEq(uint256(-int256(delta.amount1())), paid);
        assertLt(paid, 2 ether);
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(DEAD), paid);
        assertEq(token.balanceOf(address(router)), 0);
    }
}
