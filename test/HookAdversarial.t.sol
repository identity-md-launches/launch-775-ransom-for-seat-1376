// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ManumissionHook} from "src/ManumissionHook.sol";
import {AdversarialFixture, PaymentObserver} from "./mocks/AdversarialFixture.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// forge-config: default.fuzz.runs = 1000
contract HookAdversarialTest is AdversarialFixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    function testFuzz_allFeeModesRoundDownInETH(uint128 raw, bool buy, bool exactIn) public {
        // Leave headroom for exact-output sells' raw ETH amount + fee to fit int128.
        uint256 gross = bound(raw, 1, uint256(uint128(type(int128).max)) / 2);
        _checkFee(gross, buy, exactIn);
    }

    function test_feeDustBoundariesAndZeroGrossETH() public {
        uint256[7] memory amounts = [uint256(0), 1, 49, 50, 51, 99, 100];
        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 mode; mode < 4; ++mode) {
                _checkFee(amounts[i], mode < 2, mode % 2 == 0);
            }
        }
    }

    function _checkFee(uint256 gross, bool buy, bool exactIn) private {
        uint256 feesBefore = hook.totalFees();
        uint256 expected = gross / 50;
        // A zero specified amount is tested separately from mode classification: core rejects it.
        if (gross == 0) {
            manager.trade(
                hook,
                key,
                SwapParams(buy, exactIn ? int256(-1) : int256(1), 1),
                toBalanceDelta(buy == exactIn ? (buy ? int128(-1) : int128(1)) : int128(0), 0)
            );
            assertEq(hook.totalFees(), feesBefore);
            return;
        }
        SwapParams memory params = SwapParams(buy, exactIn ? -int256(gross) : int256(gross), 1);
        {
            vm.prank(address(manager));
            (bytes4 selector, BeforeSwapDelta beforeFee, uint24 lpOverride) =
                hook.beforeSwap(address(0xbeef), key, params, hex"deadbeef");
            assertEq(selector, IHooks.beforeSwap.selector);
            assertEq(beforeFee.getSpecifiedDelta(), buy == exactIn ? int256(expected) : int256(0));
            assertEq(beforeFee.getUnspecifiedDelta(), 0);
            assertEq(lpOverride, 0);
        }
        int256 rawETH = buy ? -int256(gross) : int256(gross);
        if (buy == exactIn) rawETH += int256(expected);
        vm.prank(address(manager));
        (bytes4 afterSelector, int128 afterFee) = hook.afterSwap(
            address(0xbeef),
            key,
            params,
            toBalanceDelta(int128(rawETH), buy ? type(int128).max : type(int128).min),
            ""
        );
        assertEq(afterSelector, IHooks.afterSwap.selector);
        assertEq(afterFee, buy == exactIn ? int256(0) : int256(expected));
        assertEq(hook.totalFees(), feesBefore + expected);
        assertEq(manager.balanceOf(HOOK, 0), hook.totalFees());
        assertEq(manager.balanceOf(HOOK, uint256(uint160(Currency.unwrap(key.currency1)))), 0);
        assertEq(hook.CREATOR().balance, 0);
    }

    function test_afterFeeHandlesMostNegativeInt128() public {
        manager.trade(hook, key, SwapParams(true, 1, 1), toBalanceDelta(type(int128).min, 1));
        assertEq(hook.totalFees(), (uint256(1) << 127) / 50);
        assertEq(manager.balanceOf(HOOK, 0), hook.totalFees());
    }

    function testFuzz_everyPoolKeyFieldParticipatesInFeeIsolation(uint8 fieldSeed, uint8 modeSeed) public {
        PoolKey memory other = key;
        uint256 field = fieldSeed % 5;
        if (field == 0) other.currency0 = Currency.wrap(address(1));
        else if (field == 1) other.currency1 = Currency.wrap(address(0x5678));
        else if (field == 2) other.fee = 10000;
        else if (field == 3) other.tickSpacing = 200;
        else other.hooks = IHooks(address(0x2010cc));
        manager.initialize(hook, other);
        bool buy = modeSeed % 4 < 2;
        bool exactIn = modeSeed % 2 == 0;
        int128 fee = manager.trade(
            hook,
            other,
            SwapParams(buy, exactIn ? -int256(1 ether) : int256(1 ether), 1),
            toBalanceDelta(buy ? -int128(1 ether) : int128(1 ether), buy ? int128(1) : int128(-1))
        );
        assertEq(fee, 0);
        assertEq(hook.totalFees(), 0);
        _unspent();
    }

    function test_specifiedFeeOutsideInt128RevertsWithoutMinting() public {
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        manager.trade(hook, key, SwapParams(true, type(int256).min, 1), BalanceDelta.wrap(0));
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        manager.trade(hook, key, SwapParams(false, type(int256).max, 1), BalanceDelta.wrap(0));
        assertEq(hook.totalFees(), 0);
        _unspent();
    }

    function testFuzz_oneWeiRawFillMismatchRollsBack(uint96 raw, bool buy, bool overfill) public {
        uint256 gross = bound(raw, 50, 100 ether);
        int256 required = (buy ? -int256(gross) : int256(gross)) + int256(gross / 50);
        required += overfill ? int256(1) : int256(-1);
        vm.expectRevert(ManumissionHook.PartialFill.selector);
        manager.trade(
            hook,
            key,
            SwapParams(buy, buy ? -int256(gross) : int256(gross), 1),
            toBalanceDelta(int128(required), buy ? int128(1) : int128(-1))
        );
        assertEq(hook.totalFees(), 0);
        _unspent();
    }

    function testFuzz_seatRejectsEveryNonWordLength(uint8 rawLength) public {
        _earn(2.8 ether);
        uint256 length = rawLength % 66;
        if (length == 32) length = 33;
        vm.mockCall(
            hook.IDENTITY_MD(), abi.encodeWithSignature("ownerOf(uint256)", uint256(1376)), new bytes(length)
        );
        vm.expectRevert(ManumissionHook.SeatUnavailable.selector);
        hook.manumit();
        _unspent();
    }

    function test_seatRejectsZeroAndDirtyAddressWords() public {
        _earn(2.8 ether);
        bytes memory callData = abi.encodeWithSignature("ownerOf(uint256)", uint256(1376));
        vm.mockCall(hook.IDENTITY_MD(), callData, abi.encode(uint256(0)));
        vm.expectRevert(ManumissionHook.SeatUnavailable.selector);
        hook.manumit();
        vm.mockCall(hook.IDENTITY_MD(), callData, abi.encode(uint256(1) << 160));
        vm.expectRevert(ManumissionHook.SeatUnavailable.selector);
        hook.manumit();
        _unspent();
    }

    function testFuzz_transferFailurePreservesRawReasonAndCanBeRetried(bytes memory reason) public {
        _earn(2.8 ether);
        vm.mockCallRevert(
            hook.IDENTITY_MD(),
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", hook.CREATOR(), hook.DEAD(), uint256(1376)
            ),
            reason
        );
        vm.expectRevert(abi.encodeWithSelector(ManumissionHook.BurialRefused.selector, reason));
        hook.manumit();
        _unspent();
        assertEq(seat.holder(), hook.CREATOR());
        vm.clearMockedCalls();
        hook.manumit(); // same transaction: failed call must not leave the transient lock set
        assertTrue(hook.buried());
        assertEq(hook.CREATOR().balance, 2.8 ether);
    }

    function test_paymentObservesBurialAndRejectsCrossFunctionReentrancy() public {
        _ready();
        vm.etch(hook.CREATOR(), address(new PaymentObserver(hook)).code);
        hook.manumit();
        assertEq(PaymentObserver(payable(hook.CREATOR())).received(), 2.8 ether);
        assertEq(hook.creatorPaid(), 2.8 ether);
        hook.burnIMD(false, 0); // the successful payment must also release the lock
        assertEq(hook.burnSpent(), 0.05 ether);
        vm.expectRevert(ManumissionHook.AlreadyBuried.selector);
        hook.manumit();
    }

    function testFuzz_pool4BadReturnDoesNotSeedConstructor(uint8 rawLength, bool badOpen) public {
        uint256 length = rawLength % 66;
        if (length == 32) length = 33;
        vm.mockCall(POOL4, abi.encodeWithSignature(badOpen ? "marketOpen()" : "refTick()"), new bytes(length));
        address fresh = address(0x2010cc);
        deployCodeTo("ManumissionHook.sol:ManumissionHook", abi.encode(address(manager)), fresh);
        ManumissionHook h = ManumissionHook(fresh);
        assertFalse(h.pool4Seen());
        assertEq(h.anchorBlock(), 0);
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        h.pokeAnchor();
        vm.roll(block.number + 5);
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        h.burnIMD(false, 0);
        vm.clearMockedCalls();
        oracle.configure(true, -123);
        h.pokeAnchor();
        assertTrue(h.pool4Seen());
        assertEq(h.anchor(), -123);
        assertEq(h.lastRef(), -123);
    }

    function testFuzz_pool4NoncanonicalBoolNeverBecomesOpen(uint256 rawWord) public {
        uint256 word = bound(rawWord, 2, type(uint256).max);
        _ready();
        vm.mockCall(POOL4, abi.encodeWithSignature("marketOpen()"), abi.encode(word));
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        _unspent();
        manager.configureSwap(10000, 0.01 ether);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_pool4RefRevertUsesFallbackButCannotUsePool4Route() public {
        _ready();
        vm.mockCallRevert(POOL4, abi.encodeWithSignature("refTick()"), hex"abcdef");
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        manager.configureSwap(10000, 0.01 ether);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_uninitializedOrOutOfRangeBurnPoolRollsBack() public {
        _ready();
        bytes memory extsload = abi.encodeWithSignature("extsload(bytes32)");
        vm.mockCall(address(manager), extsload, abi.encode(bytes32(0)));
        vm.expectRevert(ManumissionHook.PoolUnavailable.selector);
        hook.burnIMD(false, 0);
        uint256 malformedSlot = uint256(1) | (uint256(uint24(TickMath.MAX_TICK + 1)) << 160);
        vm.mockCall(address(manager), extsload, abi.encode(malformedSlot));
        vm.expectRevert(ManumissionHook.PoolUnavailable.selector);
        hook.burnIMD(false, 0);
        _unspent();
    }

    function test_slippageBoundaryOverfillAndNegativeOutput() public {
        _ready();
        manager.configureSwap(10001, 0.05 ether);
        vm.expectRevert(ManumissionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        // The mock narrows this exact 128-bit word to -1.
        manager.configureSwap(10000, type(uint128).max);
        vm.expectRevert(ManumissionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        _unspent();
        manager.configureSwap(10000, 0.048 ether);
        hook.burnIMD(false, 0.048 ether);
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(imd.balanceOf(hook.DEAD()), 0.048 ether);
    }

    function testFuzz_quoteMonotoneAndAdditiveWithinOneWei(int24 tickSeed, uint96 rawA, uint96 rawB)
        public
        view
    {
        int24 tick = int24(bound(int256(tickSeed), int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK - 1)));
        uint256 a = bound(rawA, 0, 0.05 ether);
        uint256 b = bound(rawB, 0, 0.05 ether);
        uint256 combined = hook.quoteAtTick(tick, a + b);
        uint256 separate = hook.quoteAtTick(tick, a) + hook.quoteAtTick(tick, b);
        assertGe(combined, separate);
        assertLe(combined - separate, 1);
        assertGe(hook.quoteAtTick(tick + 1, a), hook.quoteAtTick(tick, a));
        assertEq(hook.quoteAtTick(tick, 0), 0);
    }
}
