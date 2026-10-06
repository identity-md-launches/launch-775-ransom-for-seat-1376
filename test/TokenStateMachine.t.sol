// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ManumissionToken} from "src/ManumissionToken.sol";

/// @dev The model is updated from requested operations, never from resulting token balances.
contract TokenSequenceHandler is Test {
    ManumissionToken public immutable token;
    address[4] public actors = [address(0xa11ce), address(0xb0b), address(0xca11), address(0xd00d)];
    uint256[4] public expectedBalance;
    uint256[4][4] public expectedAllowance;
    uint256 public burned;
    uint256 public successfulCalls;
    uint256 public refusedCalls;

    constructor() {
        token = new ManumissionToken();
        for (uint256 i; i < 4; ++i) {
            expectedBalance[i] = 1e27 / 4;
            token.transfer(actors[i], expectedBalance[i]);
        }
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 raw, uint8 mode) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 amount = mode % 3 == 0 ? 0 : mode % 3 == 1 ? type(uint256).max : bound(raw, 0, 1e27);
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        expectedAllowance[owner][spender] = amount;
        ++successfulCalls;
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 raw, uint8 mode) external {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = _amount(raw, mode, expectedBalance[from]);
        vm.prank(actors[from]);
        (bool ok, bytes memory result) =
            address(token).call(abi.encodeCall(token.transfer, (actors[to], amount)));
        if (amount > expectedBalance[from]) {
            _refused(ok, result, ManumissionToken.InsufficientBalance.selector);
        } else {
            assertTrue(ok);
            assertTrue(abi.decode(result, (bool)));
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
            ++successfulCalls;
        }
    }

    function burn(uint8 ownerSeed, uint256 raw, uint8 mode) external {
        uint256 owner = ownerSeed % 4;
        uint256 amount = _amount(raw, mode, expectedBalance[owner]);
        vm.prank(actors[owner]);
        (bool ok, bytes memory result) = address(token).call(abi.encodeCall(token.burn, (amount)));
        if (amount > expectedBalance[owner]) {
            _refused(ok, result, ManumissionToken.InsufficientBalance.selector);
        } else {
            assertTrue(ok);
            expectedBalance[owner] -= amount;
            burned += amount;
            ++successfulCalls;
        }
    }

    function spend(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 raw, uint8 mode, bool destroy)
        external
    {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = _amount(raw, mode, expectedBalance[owner]);
        uint256 approved = expectedAllowance[owner][spender];
        bytes memory data = destroy
            ? abi.encodeCall(token.burnFrom, (actors[owner], amount))
            : abi.encodeCall(token.transferFrom, (actors[owner], actors[to], amount));
        vm.prank(actors[spender]);
        (bool ok, bytes memory result) = address(token).call(data);
        if (approved < amount) {
            _refused(ok, result, ManumissionToken.InsufficientAllowance.selector);
        } else if (expectedBalance[owner] < amount) {
            _refused(ok, result, ManumissionToken.InsufficientBalance.selector);
        } else {
            assertTrue(ok);
            if (approved != type(uint256).max) expectedAllowance[owner][spender] -= amount;
            expectedBalance[owner] -= amount;
            if (destroy) {
                burned += amount;
            } else {
                assertTrue(abi.decode(result, (bool)));
                expectedBalance[to] += amount;
            }
            ++successfulCalls;
        }
    }

    function _amount(uint256 raw, uint8 mode, uint256 balance) private pure returns (uint256) {
        mode %= 6;
        if (mode == 0) return 0;
        if (mode == 1) return 1;
        if (mode == 2) return balance;
        if (mode == 3) return balance + 1;
        if (mode == 4) return type(uint256).max;
        return bound(raw, 0, balance);
    }

    function _refused(bool ok, bytes memory result, bytes4 expected) private {
        assertFalse(ok, "invalid operation succeeded");
        assertEq(result, abi.encodeWithSelector(expected));
        ++refusedCalls;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract TokenStateMachineTest is Test {
    TokenSequenceHandler handler;
    ManumissionToken token;

    function setUp() public {
        handler = new TokenSequenceHandler();
        token = handler.token();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.approve.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.burn.selector;
        selectors[3] = handler.spend.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// @notice Spec 1: fixed initial supply, exact transfers, and only authorized burns reduce supply.
    function invariant_supplyAndEveryAccountMatchIndependentModel() public view {
        uint256 balances;
        for (uint256 i; i < 4; ++i) {
            uint256 actual = token.balanceOf(handler.actors(i));
            assertEq(actual, handler.expectedBalance(i), "actor balance");
            balances += actual;
        }
        assertEq(balances, token.totalSupply());
        assertEq(token.totalSupply() + handler.burned(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// @notice ERC-20 delegation: approvals replace, finite spends decrease, failed spends roll back.
    function invariant_allowancesMatchAllPriorApprovalsAndSpends() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                assertEq(
                    token.allowance(handler.actors(i), handler.actors(j)), handler.expectedAllowance(i, j)
                );
            }
        }
    }

    function test_sequenceRevocationFailureRollbackAndFullSupplyBurn() public {
        handler.approve(0, 1, 10, 2);
        handler.spend(0, 1, 2, 4, 5, false);
        handler.approve(0, 1, 0, 0);
        handler.spend(0, 1, 2, 1, 1, true); // revoked approval
        handler.approve(0, 1, 0, 1); // unlimited
        handler.spend(0, 1, 2, 0, 3, true); // insufficient balance; allowance survives
        handler.spend(0, 1, 2, 0, 2, true); // full remaining balance
        for (uint8 i = 1; i < 4; ++i) {
            handler.burn(i, 0, 2);
        }
        handler.burn(0, 0, 0); // zero supply remains usable for zero operations
        assertEq(handler.refusedCalls(), 2);
        assertGt(handler.successfulCalls(), 0);
        assertEq(token.totalSupply(), 0);
        invariant_supplyAndEveryAccountMatchIndependentModel();
        invariant_allowancesMatchAllPriorApprovalsAndSpends();
    }
}

contract TokenFailurePathsTest is Test {
    ManumissionToken token;
    address constant SPENDER = address(0xbeef);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function setUp() public {
        token = new ManumissionToken();
    }

    function test_zeroValueTransferAndApprovalEmitEvents() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), SPENDER, 0);
        assertTrue(token.transfer(SPENDER, 0));
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, 0);
        assertTrue(token.approve(SPENDER, 0));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), SPENDER, 0));
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_invalidAddressesAndInsufficientBalanceNeverConsumeApproval() public {
        vm.expectRevert(ManumissionToken.InvalidAddress.selector);
        token.approve(address(0), 0);
        token.approve(SPENDER, type(uint256).max - 1);
        vm.startPrank(SPENDER);
        vm.expectRevert(ManumissionToken.InvalidAddress.selector);
        token.transferFrom(address(this), address(0), 1);
        vm.expectRevert(ManumissionToken.InsufficientBalance.selector);
        token.transferFrom(address(this), SPENDER, 1e27 + 1);
        vm.expectRevert(ManumissionToken.InsufficientBalance.selector);
        token.burnFrom(address(this), 1e27 + 1);
        vm.expectRevert(ManumissionToken.InvalidAddress.selector);
        token.burnFrom(address(0), 0);
        vm.expectRevert(ManumissionToken.InvalidAddress.selector);
        token.transferFrom(address(0), SPENDER, 0);
        vm.stopPrank();
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max - 1);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }
}
