// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline CREATE2 salt calculation. Does not broadcast or read environment variables.
contract MineHook {
    error SearchExhausted();

    /// @param deployer The actual CREATE2 deployer, not necessarily the transaction signer.
    /// @param start First candidate salt as an integer.
    /// @param attempts Maximum candidates to examine. Continue at start + attempts if exhausted.
    function run(address deployer, IPoolManager manager, address token, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(BurnTaxHook).creationCode, abi.encode(manager, token)));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, initCodeHash)))));
            if (HookFlags.matches(predicted, HookFlags.BURN_TAX)) return (salt, predicted);
        }
        revert SearchExhausted();
    }
}
