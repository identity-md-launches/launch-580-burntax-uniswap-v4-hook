// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

abstract contract HookTests is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    event Burned(PoolId indexed poolId, bool indexed isBuy, uint256 amount);

    function test_buyExactInput() public {
        _check(true, true, 100 ether);
    }

    function test_buyExactOutput() public {
        _check(true, false, 100 ether);
    }

    function test_sellExactInput() public {
        _check(false, true, 100 ether);
    }

    function test_sellExactOutput() public {
        _check(false, false, 100 ether);
    }

    function testFuzz_allFourModes(uint96 amount, bool buy, bool exactInput) public {
        _check(buy, exactInput, bound(uint256(amount), 1, 1e21));
    }

    function test_roundingBoundaries() public {
        uint256[6] memory amounts = [uint256(1), 98, 99, 100, 101, 199];
        for (uint256 i; i < amounts.length; ++i) {
            _check(true, true, amounts[i]);
            _check(true, false, amounts[i]);
            _check(false, true, amounts[i]);
            _check(false, false, amounts[i]);
        }
    }

    function _tokenDelta(BalanceDelta d) internal view returns (int256) {
        return tokenIs0 ? int256(d.amount0()) : int256(d.amount1());
    }

    function _quoteDelta(BalanceDelta d) internal view returns (int256) {
        return tokenIs0 ? int256(d.amount1()) : int256(d.amount0());
    }

    function _check(bool buy, bool exactInput, uint256 amount) internal {
        SwapParams memory requested = _params(buy, exactInput, amount);
        SwapParams memory rawParams = _params(buy, exactInput, amount);
        if (buy && !exactInput) rawParams.amountSpecified = int256(amount + amount / 99);
        if (!buy && exactInput) rawParams.amountSpecified = -int256(amount - amount / 100);
        BalanceDelta raw = router.swap(referenceKey, rawParams, 0, type(uint128).max, 0);
        int256 rawToken = _tokenDelta(raw);
        uint256 fee = buy ? uint256(rawToken) / 100 : (exactInput ? amount / 100 : uint256(-rawToken) / 99);

        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 traderBefore = token.balanceOf(address(this));
        uint256 managerBefore = token.balanceOf(address(manager));
        uint256 quoteBefore = quote.balanceOf(address(this));
        vm.expectEmit(true, true, false, true, address(hook));
        emit Burned(key.toId(), buy, fee);
        BalanceDelta actual = router.swap(key, requested, 0, type(uint128).max, 0);
        assertEq(_tokenDelta(actual), rawToken - int256(fee), "trader token delta");
        assertEq(_quoteDelta(actual), _quoteDelta(raw), "quote leg unaffected");
        assertEq(int256(token.balanceOf(address(this))) - int256(traderBefore), _tokenDelta(actual));
        assertEq(int256(quote.balanceOf(address(this))) - int256(quoteBefore), _quoteDelta(actual));
        assertEq(int256(token.balanceOf(address(manager))) - int256(managerBefore), -rawToken);
        assertEq(token.balanceOf(DEAD) - deadBefore, fee);
        uint256 grossToken = buy ? uint256(rawToken) : uint256(-_tokenDelta(actual));
        assertEq(fee, grossToken / 100, "one percent of gross token leg");
        int256 specified = exactInput
            ? (buy ? _quoteDelta(actual) : _tokenDelta(actual))
            : (buy ? _tokenDelta(actual) : _quoteDelta(actual));
        assertEq(specified, requested.amountSpecified, "exact amount respected");
        assertEq(token.totalSupply(), 1e27);
        _assertSettled();
        (uint160 actualPrice,, uint24 protocolFee, uint24 lpFee) = IPoolManager(manager).getSlot0(key.toId());
        (uint160 rawPrice,,,) = IPoolManager(manager).getSlot0(referenceKey.toId());
        assertEq(actualPrice, rawPrice, "same AMM execution");
        assertEq(lpFee, key.fee);
        assertEq(protocolFee, 0);
    }

    function _assertSettled() internal view {
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency1), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(router), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(router), key.currency1), 0);
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(manager).isUnlocked());
    }

    function test_permissionsAndInitialization() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertEq(HookFlags.flagsOf(address(hook)), 0x20cc);
        (uint160 price,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(price, PRICE);
        assertEq(hook.launchedToken(), address(token));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.TAX_BPS(), 100);
    }

    function test_allEnabledCallbacksRejectUnauthorizedCallers() public {
        SwapParams memory params = _params(true, true, 1 ether);
        vm.expectRevert(BurnTaxHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, PRICE);
        vm.expectRevert(BurnTaxHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(BurnTaxHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(PoolRouter.Unauthorized.selector);
        router.unlockCallback("");
    }

    function test_wrongKeyRejected() public {
        SwapParams memory params = _params(true, true, 1 ether);
        vm.startPrank(address(manager));
        vm.expectRevert(BurnTaxHook.WrongHook.selector);
        hook.beforeInitialize(address(this), referenceKey, PRICE);
        vm.expectRevert(BurnTaxHook.WrongHook.selector);
        hook.beforeSwap(address(this), referenceKey, params, "");
        vm.expectRevert(BurnTaxHook.WrongHook.selector);
        hook.afterSwap(address(this), referenceKey, params, BalanceDelta.wrap(0), "");
        vm.stopPrank();
    }

    function test_initializationBeforeCodeDeploymentFails() public {
        PoolKey memory undeployed = key;
        undeployed.hooks = IHooks(address(uint160(0x120cc)));
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(undeployed, PRICE);
    }

    function test_constructorRejectsZeroParameters() public {
        vm.expectRevert(BurnTaxHook.ZeroAddress.selector);
        new BurnTaxHook(IPoolManager(address(0)), address(token));
        vm.expectRevert(BurnTaxHook.ZeroAddress.selector);
        new BurnTaxHook(manager, address(0));
    }

    function test_wrongDeploymentFlagsRejected() public {
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector);
        new BurnTaxHook(manager, address(token));
    }

    function test_noAdministrativeSelectors() public {
        bytes4[5] memory selectors = [
            bytes4(keccak256("setTax(uint256)")),
            bytes4(keccak256("withdraw(address,uint256)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("pause()"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSelector(selectors[i], address(this), 0));
            assertFalse(ok);
        }
    }

    function test_zeroSwapRevertsWithoutBurn() public {
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.swap(key, _params(true, true, 0), 0, 1 ether, 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_largeSpecifiedAmountsRejectBeforeNegationOrNarrowing() public {
        int256[3] memory amounts = [type(int256).min, int256(type(int128).max), type(int256).max];
        for (uint256 i; i < amounts.length; ++i) {
            SwapParams memory params = _params(amounts[i] > 0, amounts[i] < 0, 1);
            params.amountSpecified = amounts[i];
            vm.expectRevert(
                _wrapped(IHooks.beforeSwap.selector, BurnTaxHook.SpecifiedAmountTooLarge.selector)
            );
            router.swap(key, params, 0, type(uint128).max, 0);
        }
    }

    function test_specifiedTokenPartialFillsRevertAtomically() public {
        for (uint256 i; i < 2; ++i) {
            SwapParams memory params = _params(i == 0, i != 0, 1e22);
            params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-1) : int24(1));
            uint256 beforeBalance = token.balanceOf(address(this));
            vm.expectRevert(
                _wrapped(IHooks.afterSwap.selector, BurnTaxHook.PartialFillOnSpecifiedToken.selector)
            );
            router.swap(key, params, 0, type(uint128).max, 0);
            assertEq(token.balanceOf(address(this)), beforeBalance);
            assertEq(token.balanceOf(DEAD), 0);
            (uint160 price,,,) = IPoolManager(manager).getSlot0(key.toId());
            assertEq(price, PRICE);
            _assertSettled();
        }
    }

    function test_unspecifiedTokenPartialFillsTaxOnlyExecutedAmount() public {
        for (uint256 i; i < 2; ++i) {
            bool buy = i == 0;
            SwapParams memory params = _params(buy, buy, 1e22);
            params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-1) : int24(1));
            BalanceDelta raw = router.swap(referenceKey, params, 0, type(uint128).max, 0);
            uint256 expectedFee = buy ? uint256(_tokenDelta(raw)) / 100 : uint256(-_tokenDelta(raw)) / 99;
            uint256 beforeDead = token.balanceOf(DEAD);
            vm.expectEmit(true, true, false, true, address(hook));
            emit Burned(key.toId(), buy, expectedFee);
            BalanceDelta actual = router.swap(key, params, 0, type(uint128).max, 0);
            assertEq(_tokenDelta(actual), _tokenDelta(raw) - int256(expectedFee));
            assertEq(_quoteDelta(actual), _quoteDelta(raw));
            assertLt(buy ? uint256(-_quoteDelta(actual)) : uint256(_quoteDelta(actual)), 1e22);
            assertEq(token.balanceOf(DEAD) - beforeDead, expectedFee);
            _assertSettled();
        }
    }

    function test_slippageFailureRollsBackBurnAndPrice() public {
        uint256 beforeBalance = token.balanceOf(address(this));
        vm.expectRevert(PoolRouter.Slippage.selector);
        router.swap(key, _params(true, true, 1 ether), 1 ether, 1 ether, 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(this)), beforeBalance);
        (uint160 price,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(price, PRICE);
        _assertSettled();
    }

    function test_allLaunchFeeTiersAcceptedAndUnchanged() public {
        uint24[2] memory otherFees = [uint24(500), uint24(10000)];
        for (uint256 i; i < otherFees.length; ++i) {
            key.fee = otherFees[i];
            referenceKey.fee = otherFees[i];
            manager.initialize(key, PRICE);
            manager.initialize(referenceKey, PRICE);
            router.modify(key, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)));
            router.modify(referenceKey, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)));
            _check(true, true, 10 ether);
            _check(false, false, 10 ether);
        }
    }

    function test_dynamicTokenPoolRejectedBeforeInitialization() public {
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.prank(address(0xBEEF));
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, BurnTaxHook.UnsupportedFee.selector));
        manager.initialize(key, PRICE);
        (uint160 price,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(price, 0);
    }

    function test_otherStaticFeeStillAcceptedAndUnchanged() public {
        key.fee = 1234;
        referenceKey.fee = 1234;
        manager.initialize(key, PRICE);
        manager.initialize(referenceKey, PRICE);
        router.modify(key, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)));
        router.modify(referenceKey, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)));
        _check(false, true, 10 ether);
    }

    function test_dynamicPoolWithoutTokenRemainsUnaffected() public {
        MockERC20 other = new MockERC20("Other", "O", 1e30);
        other.approve(address(router), 1e30);
        (address first, address second) = address(other) < address(quote)
            ? (address(other), address(quote))
            : (address(quote), address(other));
        PoolKey memory unrelated = PoolKey(
            Currency.wrap(first),
            Currency.wrap(second),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(hook))
        );
        manager.initialize(unrelated, PRICE);
        router.modify(unrelated, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)));
        vm.recordLogs();
        router.swap(unrelated, _params(true, true, 10 ether), 0, type(uint128).max, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(hook));
        }
        (,,, uint24 lpFee) = IPoolManager(manager).getSlot0(unrelated.toId());
        assertEq(lpFee, 0);
        assertEq(token.balanceOf(DEAD), 0);
        _assertSettled();
    }

    function test_poolWithoutTokenIsUnaffectedInAllModes() public {
        MockERC20 other = new MockERC20("Other", "O", 1e30);
        other.approve(address(router), 1e30);
        (address first, address second) = address(other) < address(quote)
            ? (address(other), address(quote))
            : (address(quote), address(other));
        PoolKey memory unrelated =
            PoolKey(Currency.wrap(first), Currency.wrap(second), 3000, 60, IHooks(address(hook)));
        PoolKey memory plain =
            PoolKey(Currency.wrap(first), Currency.wrap(second), 3000, 60, IHooks(address(0)));
        manager.initialize(unrelated, PRICE);
        manager.initialize(plain, PRICE);
        router.modify(unrelated, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)));
        router.modify(plain, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)));
        for (uint256 i; i < 4; ++i) {
            SwapParams memory params = _params(i % 2 == 0, i < 2, 10 ether);
            BalanceDelta raw = router.swap(plain, params, 0, type(uint128).max, 0);
            vm.recordLogs();
            BalanceDelta actual = router.swap(unrelated, params, 0, type(uint128).max, 0);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j; j < logs.length; ++j) {
                assertNotEq(logs[j].emitter, address(hook));
            }
            assertEq(BalanceDelta.unwrap(raw), BalanceDelta.unwrap(actual));
        }
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_liquidityCanBeRemovedWithoutTax() public {
        router.modify(key, ModifyLiquidityParams(-600, 600, -1e24, bytes32(0)));
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(IPoolManager(manager).getLiquidity(key.toId()), 0);
        _assertSettled();
    }

    function test_failedInputSettlementRollsBackBurn() public {
        token.approve(address(router), 0);
        vm.expectRevert();
        router.swap(key, _params(false, true, 1 ether), 0, 1 ether, 0);
        assertEq(token.balanceOf(DEAD), 0);
        (uint160 price,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(price, PRICE);
        _assertSettled();
    }

    function test_runtimeHasNoProxyOrDestructionOpcodes() public view {
        _checkRuntime(address(hook).code);
        _checkRuntime(address(token).code);
    }

    function _checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function _wrapped(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}

contract HookToken0Test is HookTests {
    function setUp() public {
        _setup(true);
    }
}

contract HookToken1Test is HookTests {
    function setUp() public {
        _setup(false);
    }
}
