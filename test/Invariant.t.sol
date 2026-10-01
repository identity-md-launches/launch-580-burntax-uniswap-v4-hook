// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {BurnTaxToken} from "../src/BurnTaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract SwapHandler is Test {
    PoolRouter public immutable router;
    BurnTaxToken public immutable token;
    PoolKey internal key;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public expectedBurn;
    uint256 public trades;

    constructor(PoolRouter router_, BurnTaxToken token_, MockERC20 quote_, PoolKey memory key_) {
        router = router_;
        token = token_;
        key = key_;
        token_.approve(address(router_), 1e24);
        quote_.approve(address(router_), 1e24);
    }

    function trade(uint96 amount, bool buy, bool exactInput) external {
        amount = uint96(bound(amount, 100, 1e20));
        // This invariant fixture puts BTAX in currency0.
        bool zeroForOne = !buy;
        SwapParams memory params = SwapParams(
            zeroForOne,
            exactInput ? -int256(uint256(amount)) : int256(uint256(amount)),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 managerBefore = token.balanceOf(address(router.manager()));
        uint256 actorBefore = token.balanceOf(address(this));
        BalanceDelta delta = router.swap(key, params, 0, type(uint128).max, 0);
        uint256 gross = buy
            ? managerBefore - token.balanceOf(address(router.manager()))
            : actorBefore - token.balanceOf(address(this));
        expectedBurn += gross / 100;
        assertEq(token.balanceOf(DEAD), expectedBurn);
        assertEq(int256(token.balanceOf(address(this))) - int256(actorBefore), int256(delta.amount0()));
        ++trades;
    }
}

contract BurnTaxInvariantTest is HookFixture {
    using TransientStateLibrary for IPoolManager;
    SwapHandler internal handler;

    function setUp() public {
        _setup(true);
        handler = new SwapHandler(router, token, quote, key);
        token.transfer(address(handler), 1e24);
        quote.transfer(address(handler), 1e24);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SwapHandler.trade.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_supplyBalancesAndBurnConserved() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(DEAD), handler.expectedBurn());
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(handler))
                + token.balanceOf(address(manager)) + token.balanceOf(DEAD),
            1e27
        );
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(
            quote.balanceOf(address(this)) + quote.balanceOf(address(handler))
                + quote.balanceOf(address(manager)),
            quote.totalSupply()
        );
    }

    function invariant_noUnsettledDeltasOrClaims() public view {
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(manager).isUnlocked());
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency1), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(router), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(router), key.currency1), 0);
    }
}
