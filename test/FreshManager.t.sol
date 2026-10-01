// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {BurnTaxToken} from "../src/BurnTaxToken.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract FreshManagerTest is HookFixture {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

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

    function test_sellExactInputWithoutReservesOrPrefundingCommitsBurn() public {
        _fresh(false);
        _checkSell(true, true);
    }

    function test_sellExactOutputWithoutReservesOrPrefundingCommitsBurn() public {
        _fresh(false);
        _checkSell(false, true);
    }

    function test_sellExactInputAfterBuyingOutLaunchRange() public {
        _buyOutRange();
        _checkSell(true, true);
        // Once the first seller settles, subsequent burns can again transfer directly.
        _checkSell(true, false);
    }

    function test_sellExactOutputAfterBuyingOutLaunchRange() public {
        _buyOutRange();
        _checkSell(false, true);
        _checkSell(false, false);
    }

    function _buyOutRange() internal {
        _fresh(true);
        vm.deal(address(this), 1000 ether);
        router.swap{value: 500 ether}(key, _params(true, true, 500 ether), 0, 500 ether, 0);
        assertEq(token.balanceOf(address(manager)), 1);
    }

    function test_balanceJustBelowFeeCommitsClaim() public {
        _fresh(false);
        token.transfer(address(manager), 0.01 ether - 1);
        _checkSell(true, true);
    }

    function test_balanceEqualToFeeTransfersDirectly() public {
        _fresh(false);
        token.transfer(address(manager), 0.01 ether);
        _checkSell(true, false);
    }

    function _checkSell(bool exactInput, bool claims) internal {
        uint256 traderBefore = token.balanceOf(address(this));
        uint256 managerBefore = token.balanceOf(address(manager));
        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 claimBefore = manager.balanceOf(DEAD, uint160(address(token)));
        vm.recordLogs();
        BalanceDelta delta =
            router.swap(key, _params(false, exactInput, exactInput ? 1 ether : 0.1 ether), 0, 2 ether, 0);
        uint256 paid = traderBefore - token.balanceOf(address(this));
        uint256 fee = paid / 100;
        assertGt(fee, 0);
        if (exactInput) assertEq(paid, 1 ether);
        else assertEq(delta.amount0(), 0.1 ether);
        assertEq(uint256(-int256(delta.amount1())), paid);
        assertGt(delta.amount0(), 0);
        assertEq(token.balanceOf(DEAD) - deadBefore, claims ? 0 : fee);
        assertEq(manager.balanceOf(DEAD, uint160(address(token))) - claimBefore, claims ? fee : 0);
        assertEq(token.balanceOf(address(manager)) - managerBefore, claims ? paid : paid - fee);
        _assertBurnEvent(vm.getRecordedLogs(), fee);
        _assertSettled();
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(manager)) + token.balanceOf(DEAD),
            token.totalSupply()
        );
    }

    function _assertBurnEvent(Vm.Log[] memory logs, uint256 fee) internal view {
        uint256 events;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("Burned(bytes32,bool,uint256)"));
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            assertEq(logs[i].topics[2], bytes32(0));
            assertEq(abi.decode(logs[i].data, (uint256)), fee);
            ++events;
        }
        assertEq(events, 1);
    }

    function test_failedSettlementRollsBackClaimBurnAndPrice() public {
        _fresh(false);
        token.approve(address(router), 0);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        router.swap(key, _params(false, true, 1 ether), 0, 1 ether, 0);
        _assertFailedSell();
    }

    function test_slippageFailureRollsBackClaimBurnAndPrice() public {
        _fresh(false);
        vm.expectRevert(PoolRouter.Slippage.selector);
        router.swap(key, _params(false, true, 1 ether), 2 ether, 1 ether, 0);
        _assertFailedSell();
    }

    function _assertFailedSell() internal view {
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(manager.balanceOf(DEAD, uint160(address(token))), 0);
        (uint160 price,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(price, PRICE);
        _assertSettled();
    }

    function test_neitherDeployerNorHookCanTransferDeadClaims() public {
        _fresh(false);
        _checkSell(true, true);
        uint256 id = uint160(address(token));
        vm.expectRevert(stdError.arithmeticError);
        manager.transferFrom(DEAD, address(this), id, 1);
        vm.prank(address(hook));
        vm.expectRevert(stdError.arithmeticError);
        manager.transferFrom(DEAD, address(hook), id, 1);
        assertEq(manager.balanceOf(DEAD, id), 0.01 ether);
    }

    function _assertSettled() internal view {
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency1), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(router), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(router), key.currency1), 0);
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(manager).isUnlocked());
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
