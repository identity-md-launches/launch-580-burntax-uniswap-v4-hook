// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MineHook} from "../script/MineHook.s.sol";
import {BurnTaxHook} from "../src/BurnTaxHook.sol";
import {BurnTaxToken} from "../src/BurnTaxToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract DeploymentTest is Test {
    function test_minedAddressDeploysActualCreationCode() public {
        PoolManager manager = new PoolManager(address(this));
        BurnTaxToken token = new BurnTaxToken();
        MineHook miner = new MineHook();
        (bytes32 salt, address predicted) = miner.run(address(this), manager, address(token), 0, 200_000);
        BurnTaxHook deployed = new BurnTaxHook{salt: salt}(manager, address(token));
        assertEq(address(deployed), predicted);
        assertEq(HookFlags.flagsOf(predicted), 0x20cc);
        assertEq(deployed.launchedToken(), address(token));
        assertEq(address(deployed.poolManager()), address(manager));
    }

    function test_exhaustedSearchReverts() public {
        MineHook miner = new MineHook();
        vm.expectRevert(MineHook.SearchExhausted.selector);
        miner.run(address(this), IPoolManager(address(1)), address(2), 0, 0);
    }
}
