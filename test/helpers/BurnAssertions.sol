// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev Uses the real manager's pre-hook Swap event as the AMM oracle.
abstract contract BurnAssertions is Test {
    using PoolIdLibrary for PoolKey;

    struct Observation {
        int128 amount0;
        int128 amount1;
        uint160 price;
        uint128 liquidity;
        int24 tick;
        uint24 fee;
    }

    function _assertSwapLogs(
        Vm.Log[] memory logs,
        PoolKey memory key,
        address manager,
        address router,
        bool tokenIs0,
        bool buy,
        BalanceDelta traderDelta
    ) internal pure returns (uint256 burn) {
        uint256 swaps;
        uint256 burns;
        uint256 emittedBurn;
        Observation memory raw;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter == manager
                    && entry.topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                assertEq(entry.topics.length, 3);
                assertEq(entry.topics[1], PoolId.unwrap(key.toId()), "AMM pool id");
                assertEq(entry.topics[2], bytes32(uint256(uint160(router))), "AMM caller");
                raw = abi.decode(entry.data, (Observation));
                ++swaps;
            }
            if (entry.emitter == address(key.hooks)) {
                assertEq(entry.topics.length, 3);
                assertEq(entry.topics[0], keccak256("Burned(bytes32,bool,uint256)"));
                assertEq(entry.topics[1], PoolId.unwrap(key.toId()), "burn pool id");
                assertEq(entry.topics[2], bytes32(uint256(buy ? 1 : 0)), "trader-facing direction");
                emittedBurn = abi.decode(entry.data, (uint256));
                ++burns;
            }
        }
        assertEq(swaps, 1, "one AMM swap");
        assertEq(burns, 1, "one burn event, including zero tax");
        assertEq(raw.fee, key.fee, "pool fee is unchanged");
        int256 rawToken = tokenIs0 ? int256(raw.amount0) : int256(raw.amount1);
        int256 netToken = tokenIs0 ? int256(traderDelta.amount0()) : int256(traderDelta.amount1());
        int256 netQuote = tokenIs0 ? int256(traderDelta.amount1()) : int256(traderDelta.amount0());
        if (buy) {
            assertGe(rawToken, 0);
            assertGe(netToken, 0);
            burn = uint256(rawToken) / 100;
        } else {
            assertLe(rawToken, 0);
            assertLe(netToken, 0);
            burn = uint256(-netToken) / 100;
        }
        assertEq(netToken, rawToken - int256(burn), "only BTAX delta pays the tax");
        assertEq(netQuote, tokenIs0 ? int256(raw.amount1) : int256(raw.amount0), "quote delta unchanged");
        assertEq(emittedBurn, burn, "event equals one percent of executed gross leg");
    }
}
