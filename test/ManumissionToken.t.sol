// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ManumissionToken} from "../src/ManumissionToken.sol";

contract ManumissionTokenTest is Test {
    ManumissionToken token;
    address constant ALICE = address(0xa11ce);

    function setUp() public {
        token = new ManumissionToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Ransom for Seat 1376");
        assertEq(token.symbol(), "FREE1376");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowancesAndBurns() public {
        token.approve(ALICE, 10 ether);
        vm.startPrank(ALICE);
        token.transferFrom(address(this), ALICE, 4 ether);
        token.burnFrom(address(this), 6 ether);
        token.burn(1 ether);
        vm.expectRevert(ManumissionToken.InsufficientAllowance.selector);
        token.burnFrom(address(this), 1);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 3 ether);
        assertEq(token.totalSupply(), 1e27 - 7 ether);
        assertEq(token.allowance(address(this), ALICE), 0);
    }

    function test_infiniteAllowanceAndSelfTransfer() public {
        token.transfer(address(this), 2 ether);
        assertEq(token.balanceOf(address(this)), 1e27);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.burnFrom(address(this), 1 ether);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
    }

    function test_invalidTransfersAndBurns() public {
        vm.expectRevert(ManumissionToken.InvalidAddress.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(ManumissionToken.InsufficientBalance.selector);
        token.burn(1e27 + 1);
        vm.prank(ALICE);
        vm.expectRevert(ManumissionToken.InsufficientBalance.selector);
        token.transfer(address(this), 1);
    }
}
