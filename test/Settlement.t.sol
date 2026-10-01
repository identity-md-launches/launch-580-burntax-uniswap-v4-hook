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

/// @dev Keeps the input sync/settle pair open across an exact-input swap.
contract OpenSyncRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address payer, PoolKey memory key, SwapParams memory params) =
            abi.decode(data, (address, PoolKey, SwapParams));
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        uint256 amount = uint256(-params.amountSpecified);
        manager.sync(input);
        require(IERC20(Currency.unwrap(input)).transferFrom(payer, address(manager), amount));
        BalanceDelta delta = manager.swap(key, params, "");
        require(manager.settle() == amount, "input settlement under-credited");
        int128 received = params.zeroForOne ? delta.amount1() : delta.amount0();
        manager.take(output, payer, uint256(int256(received)));
        return abi.encode(delta);
    }
}

abstract contract SettlementTests is HookFixture {
    using TransientStateLibrary for IPoolManager;

    function test_openTokenSyncAcrossSellPreservesFullSettlement() public {
        OpenSyncRouter openRouter = new OpenSyncRouter(manager);
        token.approve(address(openRouter), 1 ether);
        uint256 beforeToken = token.balanceOf(address(this));
        uint256 beforeQuote = quote.balanceOf(address(this));
        uint256 beforeManager = token.balanceOf(address(manager));
        BalanceDelta delta = openRouter.swap(key, _params(false, true, 1 ether));
        assertEq(beforeToken - token.balanceOf(address(this)), 1 ether);
        assertEq(token.balanceOf(address(manager)) - beforeManager, 1 ether);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(manager.balanceOf(DEAD, uint160(address(token))), 0.01 ether);
        assertEq(tokenIs0 ? delta.amount0() : delta.amount1(), -1 ether);
        assertEq(
            quote.balanceOf(address(this)) - beforeQuote,
            uint256(int256(tokenIs0 ? delta.amount1() : delta.amount0()))
        );
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(manager).isUnlocked());
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
