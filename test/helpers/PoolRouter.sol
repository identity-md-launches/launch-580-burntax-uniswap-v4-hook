// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BurnTaxHook} from "../../src/BurnTaxHook.sol";

/// @dev Test-only settlement router. Supports slippage checks and optional input pre-settlement.
contract PoolRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    error Slippage();
    error Unauthorized();
    IPoolManager public immutable manager;

    struct Request {
        address payer;
        PoolKey key;
        bool liquidity;
        ModifyLiquidityParams position;
        SwapParams trade;
        uint256 minOut;
        uint256 maxIn;
        uint256 prefund;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory position)
        external
        payable
        returns (BalanceDelta)
    {
        Request memory r;
        r.payer = msg.sender;
        r.key = key;
        r.liquidity = true;
        r.position = position;
        return _execute(r);
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        uint256 minOut,
        uint256 maxIn,
        uint256 prefund
    ) external payable returns (BalanceDelta) {
        Request memory r;
        r.payer = msg.sender;
        r.key = key;
        r.trade = params;
        r.minOut = minOut;
        r.maxIn = maxIn;
        r.prefund = prefund;
        return _execute(r);
    }

    function _execute(Request memory r) private returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(r)), (BalanceDelta));
        if (address(this).balance != 0) {
            (bool ok,) = r.payer.call{value: address(this).balance}("");
            require(ok, "refund failed");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert Unauthorized();
        Request memory r = abi.decode(data, (Request));
        BalanceDelta delta;
        if (r.liquidity) {
            (delta,) = manager.modifyLiquidity(r.key, r.position, "");
        } else {
            if (r.prefund != 0) {
                _pay(r.trade.zeroForOne ? r.key.currency0 : r.key.currency1, r.payer, r.prefund);
            }
            delta = manager.swap(r.key, r.trade, "");
            int256 input = r.trade.zeroForOne ? int256(delta.amount0()) : int256(delta.amount1());
            int256 output = r.trade.zeroForOne ? int256(delta.amount1()) : int256(delta.amount0());
            if (uint256(-input) > r.maxIn || uint256(output) < r.minOut) revert Slippage();
        }
        _settle(r.key.currency0, r.payer);
        _settle(r.key.currency1, r.payer);
        if (!r.liquidity && address(r.key.hooks) != address(0)) {
            BurnTaxHook(address(r.key.hooks)).settleBurn();
        }
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) _pay(currency, payer, uint256(-delta));
        else if (delta > 0) manager.take(currency, payer, uint256(delta));
    }

    function _pay(Currency currency, address payer, uint256 amount) private {
        if (Currency.unwrap(currency) == address(0)) {
            manager.sync(currency);
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount));
            manager.settle();
        }
    }

    receive() external payable {}
}
