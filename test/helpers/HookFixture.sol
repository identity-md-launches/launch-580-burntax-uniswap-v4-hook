// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BurnTaxToken} from "../../src/BurnTaxToken.sol";
import {BurnTaxHook} from "../../src/BurnTaxHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolRouter} from "./PoolRouter.sol";

abstract contract HookFixture is Test {
    uint160 internal constant PRICE = 1 << 96;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    PoolManager internal manager;
    PoolRouter internal router;
    BurnTaxToken internal token;
    MockERC20 internal quote;
    BurnTaxHook internal hook;
    PoolKey internal key;
    PoolKey internal referenceKey;
    bool internal tokenIs0;

    function _setup(bool tokenFirst) internal {
        manager = new PoolManager(address(this));
        router = new PoolRouter(manager);
        token = new BurnTaxToken();
        for (uint256 i; i < 100; ++i) {
            quote = new MockERC20{salt: bytes32(i)}("Quote", "Q", 1e30);
            if ((address(token) < address(quote)) == tokenFirst) break;
        }
        tokenIs0 = address(token) < address(quote);
        assertEq(tokenIs0, tokenFirst);
        hook = _deployHook(manager, address(token));
        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(token) : address(quote)),
            currency1: Currency.wrap(tokenIs0 ? address(quote) : address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        referenceKey = key;
        referenceKey.hooks = IHooks(address(0));
        token.approve(address(router), token.totalSupply());
        quote.approve(address(router), quote.totalSupply());
        manager.initialize(key, PRICE);
        manager.initialize(referenceKey, PRICE);
        router.modify(key, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)));
        router.modify(referenceKey, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)));
    }

    function _deployHook(IPoolManager manager_, address token_) internal returns (BurnTaxHook deployed) {
        bytes memory code = abi.encodePacked(type(BurnTaxHook).creationCode, abi.encode(manager_, token_));
        bytes32 codeHash = keccak256(code);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, codeHash))))
            );
            if (HookFlags.matches(predicted, HookFlags.BURN_TAX)) {
                deployed = new BurnTaxHook{salt: salt}(manager_, token_);
                assertEq(address(deployed), predicted);
                return deployed;
            }
        }
        revert("salt search exhausted");
    }

    function _params(bool buy, bool exactInput, uint256 amount) internal view returns (SwapParams memory) {
        bool zeroForOne = buy != tokenIs0;
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    receive() external payable {}
}
