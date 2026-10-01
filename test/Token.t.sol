// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BurnTaxToken} from "../src/BurnTaxToken.sol";

contract TokenTest is Test {
    BurnTaxToken internal token;
    address internal alice = address(0xA11CE);

    function setUp() public {
        token = new BurnTaxToken();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "BurnTax");
        assertEq(token.symbol(), "BTAX");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceAndTransferFrom() public {
        token.approve(alice, 10 ether);
        vm.prank(alice);
        token.transferFrom(address(this), address(0xBEEF), 7 ether);
        assertEq(token.allowance(address(this), alice), 3 ether);
        assertEq(token.balanceOf(address(0xBEEF)), 7 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.transferFrom(address(this), alice, 4 ether);
    }

    function test_invalidTransfersRevert() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(address(this), 1);
    }

    function test_noMintAdminOrUpgradeEvenForDeployer() public {
        bytes4[8] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("mint(uint256)")),
            bytes4(keccak256("setMinter(address)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("initialize(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("withdraw()"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], alice, 1 ether));
            assertFalse(ok);
            vm.prank(alice);
            (ok,) = address(token).call(abi.encodeWithSelector(selectors[i], alice, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(alice), 0);
    }
}
