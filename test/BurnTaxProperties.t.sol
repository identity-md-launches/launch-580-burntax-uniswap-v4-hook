// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {BurnAssertions} from "./helpers/BurnAssertions.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

abstract contract BurnTaxProperties is HookFixture, BurnAssertions {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_executedVolumeOracle(uint96 seed, bool buy, bool exactInput, uint8 prefundMode) public {
        uint256 amount = bound(seed, 1, 1e21);
        uint256 beforeToken = token.balanceOf(address(this));
        uint256 beforeQuote = quote.balanceOf(address(this));
        uint256 beforeDead = token.balanceOf(DEAD);
        // Exercise no prefunding, partial prefunding, and an overpayment that must be refunded.
        uint256 prefund = prefundMode % 3 == 0 ? 0 : (prefundMode % 3 == 1 ? amount / 2 : amount * 2);
        vm.recordLogs();
        BalanceDelta delta = router.swap(key, _params(buy, exactInput, amount), 0, type(uint128).max, prefund);
        uint256 burn = _assertSwapLogs(
            vm.getRecordedLogs(), key, address(manager), address(router), tokenIs0, buy, delta
        );
        int256 tokenDelta = tokenIs0 ? int256(delta.amount0()) : int256(delta.amount1());
        int256 quoteDelta = tokenIs0 ? int256(delta.amount1()) : int256(delta.amount0());
        assertEq(int256(token.balanceOf(address(this))) - int256(beforeToken), tokenDelta);
        assertEq(int256(quote.balanceOf(address(this))) - int256(beforeQuote), quoteDelta);
        assertEq(token.balanceOf(DEAD) - beforeDead, burn);
        assertEq(
            exactInput ? (buy ? -quoteDelta : -tokenDelta) : (buy ? tokenDelta : quoteDelta), int256(amount)
        );
        assertEq(token.balanceOf(address(router)), 0, "prefunding refunded");
        assertEq(quote.balanceOf(address(router)), 0);
        assertEq(manager.balanceOf(DEAD, uint160(address(token))), 0);
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
    }

    function test_failedBuySettlementRevertsExactAllowanceErrorAndAllAccounting() public {
        quote.approve(address(router), 1 ether - 1);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 1 ether - 1, 1 ether
            )
        );
        router.swap(key, _params(true, true, 1 ether), 0, 1 ether, 0);
        assertEq(_stateDigest(), beforeState, "failed buy is atomic");
    }

    function test_failedSellSettlementRevertsExactBalanceErrorAndAllAccounting() public {
        address poorTrader = address(0xBAD);
        token.transfer(poorTrader, 1 ether - 1);
        vm.prank(poorTrader);
        token.approve(address(router), 1 ether);
        bytes32 beforeState = _stateDigest();
        vm.prank(poorTrader);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, poorTrader, 1 ether - 1, 1 ether
            )
        );
        router.swap(key, _params(false, true, 1 ether), 0, 1 ether, 0);
        assertEq(_stateDigest(), beforeState, "failed sell is atomic");
        assertEq(token.balanceOf(poorTrader), 1 ether - 1);
        assertEq(token.allowance(poorTrader, address(router)), 1 ether, "allowance restored too");
    }

    function test_maxInputSlippageRestoresPrefundingBurnAndFeeGrowth() public {
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            bytes32 beforeState = _stateDigest();
            vm.expectRevert(PoolRouter.Slippage.selector);
            router.swap(key, _params(buy, i < 2, 1 ether), 0, 0, 2 ether);
            assertEq(_stateDigest(), beforeState, "overpaid input restored on revert");
        }
    }

    function test_invalidPriceLimitDoesNotReserveOrBurnTokens() public {
        bytes32 beforeState = _stateDigest();
        for (uint256 i; i < 4; ++i) {
            SwapParams memory params = _params(i % 2 == 0, i < 2, 1 ether);
            params.sqrtPriceLimitX96 = PRICE;
            vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, PRICE, PRICE));
            router.swap(key, params, 0, type(uint128).max, 0);
            assertEq(_stateDigest(), beforeState);
        }
    }

    function test_quoteSpecifiedSwapsWithNoLiquidityHaveNoPhantomBurn() public {
        router.modify(key, ModifyLiquidityParams(-600, 600, -1e24, bytes32(0)));
        uint256 beforeToken = token.balanceOf(address(this));
        uint256 beforeQuote = quote.balanceOf(address(this));
        for (uint256 i; i < 2; ++i) {
            bool buy = i == 0;
            vm.recordLogs();
            BalanceDelta delta = router.swap(key, _params(buy, buy, 1 ether), 0, type(uint128).max, 0);
            assertEq(BalanceDelta.unwrap(delta), 0);
            assertEq(
                _assertSwapLogs(
                    vm.getRecordedLogs(), key, address(manager), address(router), tokenIs0, buy, delta
                ),
                0
            );
        }
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(this)), beforeToken);
        assertEq(quote.balanceOf(address(this)), beforeQuote);
    }

    function _stateDigest() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(manager).getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = IPoolManager(manager).getFeeGrowthGlobals(key.toId());
        bytes32 poolState = keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1));
        bytes32 balances = keccak256(
            abi.encode(
                token.balanceOf(address(this)),
                quote.balanceOf(address(this)),
                token.balanceOf(address(manager)),
                quote.balanceOf(address(manager)),
                token.balanceOf(DEAD),
                manager.balanceOf(DEAD, uint160(address(token))),
                token.balanceOf(address(router)),
                quote.balanceOf(address(router))
            )
        );
        return keccak256(
            abi.encode(
                poolState,
                balances,
                IPoolManager(manager).getNonzeroDeltaCount(),
                IPoolManager(manager).isUnlocked()
            )
        );
    }
}

/// forge-config: default.fuzz.runs = 1000
contract BurnTaxPropertiesToken0Test is BurnTaxProperties {
    function setUp() public {
        _setup(true);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract BurnTaxPropertiesToken1Test is BurnTaxProperties {
    function setUp() public {
        _setup(false);
    }
}
