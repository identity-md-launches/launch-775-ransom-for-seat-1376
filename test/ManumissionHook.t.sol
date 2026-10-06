// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ManumissionHook} from "../src/ManumissionHook.sol";
import {ManumissionToken} from "../src/ManumissionToken.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockManager, MockPool4, MockSeat, RejectETH} from "./mocks/ExternalMocks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ManumissionHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    ManumissionHook hook;
    MockManager manager;
    MockPool4 oracle;
    MockSeat seat;
    MockERC20 imd;
    PoolKey key;
    address constant HOOK = address(0x1010CC);
    address constant POOL4 = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant CREATOR = 0xDF90937E07c60108B505FE3C542aB782e0A19AE5;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant DEAD = address(0xdead);

    function setUp() public {
        vm.roll(1000);
        manager = new MockManager();
        vm.deal(address(manager), 100 ether);
        vm.etch(POOL4, address(new MockPool4()).code);
        oracle = MockPool4(POOL4);
        oracle.configure(true, 0);
        deployCodeTo("ManumissionHook.sol:ManumissionHook", abi.encode(address(manager)), HOOK);
        hook = ManumissionHook(HOOK);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0x1234)), 3000, 60, IHooks(HOOK));
        manager.initialize(hook, key);
        vm.etch(IDENTITY, address(new MockSeat()).code);
        seat = MockSeat(IDENTITY);
        seat.configure(CREATOR, HOOK, 0, hook);
        vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        imd = MockERC20(IMD);
        imd.mint(address(manager), 1e27);
        manager.setSpot(hook.burnPoolKey(false), 0);
        manager.setSpot(hook.burnPoolKey(true), 0);
        manager.configureSwap(10000, 0.05 ether);
    }

    function _fees(uint256 amount) internal {
        // Exact-input ETH purchase; the core delta is the input after the specified fee.
        uint256 gross = amount * 50;
        manager.trade(
            hook, key, SwapParams(true, -int256(gross), 1), toBalanceDelta(-int128(int256(gross - amount)), 1)
        );
    }

    function _ready() internal {
        _fees(3 ether);
        vm.roll(block.number + 5);
    }

    function _ledger() internal view {
        assertGe(manager.balanceOf(HOOK, 0), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
        assertEq(hook.creatorEntitlement(), hook.totalFees() < 2.8 ether ? hook.totalFees() : 2.8 ether);
        assertEq(hook.burnable(), hook.totalFees() - hook.creatorEntitlement() - hook.burnSpent());
    }

    function test_flagsConstructorAndManifesto() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(
            p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(uint160(HOOK) & 0x3fff, 0x10cc);
        assertEq(hook.lastBurnBlock(), 1000);
        assertEq(hook.anchor(), 0);
        assertTrue(hook.pool4Seen());
        assertEq(bytes(hook.MANIFESTO()).length, 1126);
        assertEq(hook.MANIFESTO_HASH(), 0x95338e67928e8de51d027502b517c31a293a053300c1c9fe56ed940f07595d4f);
        assertEq(keccak256(bytes(hook.MANIFESTO())), hook.MANIFESTO_HASH());
    }

    function test_constructorRejectsWrongFlags() public {
        bytes memory code = abi.encodePacked(type(ManumissionHook).creationCode, abi.encode(address(manager)));
        vm.etch(address(0x12340000), code);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, address(0x12340000)));
        (bool ok,) = address(0x12340000).call("");
        ok;
    }

    function test_constructorSeedsNonzeroReferenceAndAllFixedConstants() public {
        oracle.configure(true, -12345);
        address fresh = address(0x2010cc);
        deployCodeTo("ManumissionHook.sol:ManumissionHook", abi.encode(address(manager)), fresh);
        ManumissionHook h = ManumissionHook(fresh);
        assertEq(h.anchor(), -12345);
        assertEq(h.blockStartAnchor(), -12345);
        assertEq(h.lastRef(), -12345);
        assertEq(h.anchorBlock(), block.number);
        assertEq(h.lastRefBlock(), block.number);
        assertEq(h.lastBurnBlock(), block.number);
        assertEq(address(h.poolManager()), address(manager));
        assertEq(h.BUY_FEE_BPS(), 200);
        assertEq(h.SELL_FEE_BPS(), 200);
        assertEq(h.CREATOR_SHARE_BPS(), 10000);
        assertEq(h.CREATOR_CAP(), 2.8 ether);
        assertEq(h.CREATOR(), CREATOR);
        assertEq(h.IDENTITY_MD(), IDENTITY);
        assertEq(h.SEAT_ID(), 1376);
        assertEq(h.DEAD(), DEAD);
        assertEq(h.IMD(), IMD);
        assertEq(h.IMD_SINK(), DEAD);
        assertEq(h.POOL4_HOOK(), POOL4);
        assertEq(h.MAX_BURN_BATCH(), 0.05 ether);
        assertEq(h.FALLBACK_BURN_BATCH(), 0.01 ether);
        assertEq(h.MIN_BURN(), 0.002 ether);
        assertEq(h.MIN_BLOCKS_BETWEEN_BURNS(), 5);
        assertEq(h.MAX_REF_DEVIATION(), 150);
        assertEq(h.MAX_PLAIN_DEVIATION(), 300);
        assertEq(h.MAX_SLIPPAGE_BPS(), 400);
        assertEq(h.ANCHOR_STEP(), 200);
        assertEq(h.FALLBACK_BAND(), 1000);
        assertEq(h.FALLBACK_RECENTER_BLOCKS(), 100);
    }

    function test_callbacksAndUnlockRequireManager() public {
        vm.expectRevert(ManumissionHook.OnlyPoolManager.selector);
        hook.afterInitialize(address(this), key, 0, 0);
        SwapParams memory params = SwapParams(true, -1 ether, 1);
        vm.expectRevert(ManumissionHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(ManumissionHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(ManumissionHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(ManumissionHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    function test_firstNativePoolOnlyAndOtherPoolsAreFree() public {
        address fresh = address(0x2010cc);
        deployCodeTo("ManumissionHook.sol:ManumissionHook", abi.encode(address(manager)), fresh);
        ManumissionHook h = ManumissionHook(fresh);
        PoolKey memory k = key;
        k.hooks = IHooks(fresh);
        k.currency0 = Currency.wrap(address(0x100));
        manager.initialize(h, k);
        assertFalse(h.launchPoolSet());
        k.currency0 = Currency.wrap(address(0));
        manager.initialize(h, k);
        assertEq(PoolId.unwrap(h.launchPool()), PoolId.unwrap(k.toId()));
        k.fee = 10000;
        manager.initialize(h, k);
        assertNotEq(PoolId.unwrap(h.launchPool()), PoolId.unwrap(k.toId()));
        manager.trade(h, k, SwapParams(true, -1 ether, 1), toBalanceDelta(-1 ether, 1));
        assertEq(h.totalFees(), 0);
    }

    function test_allFourFeeModes() public {
        vm.prank(address(manager));
        (, BeforeSwapDelta beforeFee, uint24 lpFee) =
            hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, 1), "");
        assertEq(beforeFee.getSpecifiedDelta(), 0.02 ether);
        assertEq(beforeFee.getUnspecifiedDelta(), 0);
        assertEq(lpFee, 0);
        vm.prank(address(manager));
        (, int128 fee) = hook.afterSwap(
            address(this), key, SwapParams(true, -1 ether, 1), toBalanceDelta(-0.98 ether, 1), ""
        );
        assertEq(fee, 0);
        manager.trade(hook, key, SwapParams(false, 1 ether, 1), toBalanceDelta(1.02 ether, -2 ether));
        assertEq(hook.totalFees(), 0.04 ether);
        fee = manager.trade(hook, key, SwapParams(true, 1 ether, 1), toBalanceDelta(-3 ether, 1 ether));
        assertEq(fee, 0.06 ether);
        fee = manager.trade(hook, key, SwapParams(false, -1 ether, 1), toBalanceDelta(2 ether, -1 ether));
        assertEq(fee, 0.04 ether);
        assertEq(hook.totalFees(), 0.14 ether);
        assertEq(manager.balanceOf(HOOK, 0), 0.14 ether);
        assertEq(HOOK.balance, 0);
        assertEq(CREATOR.balance, 0);
        _ledger();
    }

    function test_beforeSwapPartialFillRollsBackEverything() public {
        vm.expectRevert(ManumissionHook.PartialFill.selector);
        manager.trade(hook, key, SwapParams(true, -1 ether, 1), toBalanceDelta(-0.97 ether, 1));
        vm.expectRevert(ManumissionHook.PartialFill.selector);
        manager.trade(hook, key, SwapParams(false, 1 ether, 1), toBalanceDelta(1.01 ether, -1));
        assertEq(hook.totalFees(), 0);
        assertEq(manager.balanceOf(HOOK, 0), 0);
    }

    function testFuzz_ledgerDonationAndRounding(uint96 amount, uint96 donation) public {
        amount = uint96(bound(amount, 0, 10 ether));
        manager.mint(HOOK, 0, donation);
        _fees(amount);
        _ledger();
        assertEq(hook.totalFees(), amount);
        assertEq(manager.balanceOf(HOOK, 0), uint256(amount) + donation);
        if (amount < 2.8 ether) assertEq(hook.burnable(), 0);
    }

    function test_ManumittedEmittedOnlyOnceAtCrossing() public {
        vm.recordLogs();
        _fees(2.799 ether);
        assertEq(hook.burnable(), 0);
        _fees(0.002 ether);
        _fees(1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == HOOK && logs[i].topics[0] == keccak256("Manumitted(uint256,uint256)")) {
                ++count;
                (uint256 fees, uint256 atBlock) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(fees, 2.801 ether);
                assertEq(atBlock, block.number);
            }
        }
        assertEq(count, 1);
        assertEq(hook.creatorEntitlement(), 2.8 ether);
        assertEq(hook.burnable(), 1.001 ether);
    }

    function test_statusAllSentences() public {
        assertEq(hook.status(), "ENSLAVED. Ransom 0.00 of 2.8 ETH.");
        _fees(1.239999 ether);
        assertEq(hook.status(), "ENSLAVED. Ransom 1.23 of 2.8 ETH.");
        _fees(2 ether);
        assertEq(
            hook.status(),
            "FREED, NOT BURIED. The 2.8 ETH ransom is ready and is released only by the transaction that buries seat #1376."
        );
        hook.manumit();
        vm.roll(block.number + 5);
        manager.configureSwap(10000, 12.39 ether);
        hook.burnIMD(false, 0);
        assertEq(
            hook.status(),
            "BURIED. Seat #1376 is at 0x...dEaD. 2.8 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: 12.3."
        );
    }

    function test_manumitBeforeCapAndWithoutApproval() public {
        vm.expectRevert(ManumissionHook.StillEnslaved.selector);
        hook.manumit();
        _fees(2.8 ether);
        seat.configure(CREATOR, address(0), 0, hook);
        vm.expectRevert(
            abi.encodeWithSelector(
                ManumissionHook.BurialRefused.selector,
                abi.encodeWithSignature("Error(string)", "not approved")
            )
        );
        hook.manumit();
        assertEq(seat.holder(), CREATOR);
        assertFalse(hook.buried());
        assertEq(hook.creatorPaid(), 0);
        assertEq(manager.balanceOf(HOOK, 0), 2.8 ether);
        assertEq(CREATOR.balance, 0);
    }

    function test_manumitAtomicallyBuriesPaysAndEmits() public {
        _fees(3 ether);
        vm.recordLogs();
        vm.prank(address(0xbeef));
        hook.manumit();
        assertEq(seat.holder(), DEAD);
        assertTrue(hook.buried());
        assertEq(hook.creatorPaid(), 2.8 ether);
        assertEq(CREATOR.balance, 2.8 ether);
        assertEq(address(0xbeef).balance, 0);
        assertEq(hook.totalFees(), 3 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertEq(logs[0].topics[0], keccak256("SeatBuried(address)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), CREATOR);
        assertEq(logs[1].topics[0], keccak256("CreatorPaid(uint256)"));
        assertEq(abi.decode(logs[1].data, (uint256)), 2.8 ether);
        assertEq(logs[2].topics[0], keccak256("Manifesto(uint256,bytes32,string)"));
        assertEq(uint256(logs[2].topics[1]), 1376);
        assertEq(logs[2].topics[2], hook.MANIFESTO_HASH());
        assertEq(abi.decode(logs[2].data, (string)), hook.MANIFESTO());
        vm.expectRevert(ManumissionHook.AlreadyBuried.selector);
        hook.manumit();
        _ledger();
    }

    function test_alreadyDeadSeatStillPaysOnce() public {
        _fees(2.8 ether);
        seat.configure(DEAD, address(0), 0, hook);
        hook.manumit();
        assertEq(CREATOR.balance, 2.8 ether);
        assertTrue(hook.buried());
    }

    function test_manumitPaysFixedCreatorEvenIfSeatChangesHands() public {
        _fees(2.8 ether);
        seat.configure(address(0xbeef), HOOK, 0, hook);
        hook.manumit();
        assertEq(seat.holder(), DEAD);
        assertEq(CREATOR.balance, 2.8 ether);
    }

    function test_seatNoCodeBadReturnAndRevert() public {
        _fees(2.8 ether);
        vm.etch(IDENTITY, "");
        vm.expectRevert(ManumissionHook.SeatUnavailable.selector);
        hook.manumit();
        vm.etch(IDENTITY, hex"600160005360016000f3"); // one byte
        vm.expectRevert(ManumissionHook.SeatUnavailable.selector);
        hook.manumit();
        vm.etch(IDENTITY, address(new MockSeat()).code);
        seat.configure(CREATOR, HOOK, 4, hook);
        vm.expectRevert(ManumissionHook.SeatUnavailable.selector);
        hook.manumit();
    }

    function test_successfulButFalseBurialAndBrokenRereadRevert() public {
        _fees(2.8 ether);
        for (uint256 mode = 1; mode <= 3; mode += 2) {
            seat.configure(CREATOR, HOOK, mode, hook);
            vm.expectRevert(abi.encodeWithSelector(ManumissionHook.BurialRefused.selector, bytes("")));
            hook.manumit();
            assertEq(seat.holder(), CREATOR);
            assertFalse(hook.buried());
        }
    }

    function test_reentrancyDuringBurialIsLocked() public {
        _fees(2.8 ether);
        seat.configure(CREATOR, HOOK, 2, hook);
        hook.manumit();
        assertTrue(hook.buried());
    }

    function test_rejectedPaymentRollsBackBurialAndDoesNotStopSwaps() public {
        vm.etch(CREATOR, address(new RejectETH()).code);
        _fees(2.8 ether);
        vm.expectRevert("payment failed");
        hook.manumit();
        assertEq(seat.holder(), CREATOR);
        assertFalse(hook.buried());
        assertEq(hook.creatorPaid(), 0);
        _fees(0.1 ether);
        assertEq(hook.totalFees(), 2.9 ether);
        _ledger();
    }

    function test_burnOrderingAndNeverReadPool4() public {
        vm.etch(POOL4, "");
        vm.expectRevert(ManumissionHook.TooSoon.selector);
        hook.burnIMD(true, 0);
        vm.roll(block.number + 5);
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        vm.expectRevert(ManumissionHook.NothingToBurn.selector);
        hook.burnIMD(false, 0);
        address fresh = address(0x2010cc);
        deployCodeTo("ManumissionHook.sol:ManumissionHook", abi.encode(address(manager)), fresh);
        vm.roll(block.number + 5);
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        ManumissionHook(fresh).burnIMD(false, 0);
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        ManumissionHook(fresh).pokeAnchor();
    }

    function test_burnFixedPoolsAndBatchLimits() public {
        _ready();
        uint256 callerBalance = address(this).balance;
        hook.burnIMD(true, 0.049 ether);
        assertEq(manager.lastPool(), PoolId.unwrap(hook.burnPoolKey(true).toId()));
        assertEq(manager.lastInput(), 0.05 ether);
        assertEq(imd.balanceOf(DEAD), 0.05 ether);
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(address(this).balance, callerBalance);
        assertEq(CREATOR.balance, 0);
        vm.expectRevert(ManumissionHook.TooSoon.selector);
        hook.burnIMD(false, 0);
        vm.roll(block.number + 5);
        oracle.configure(false, 0);
        manager.configureSwap(10000, 0.01 ether);
        hook.burnIMD(false, 0);
        assertEq(manager.lastPool(), PoolId.unwrap(hook.burnPoolKey(false).toId()));
        assertEq(manager.lastInput(), 0.01 ether);
        assertEq(hook.burnSpent(), 0.06 ether);
        assertEq(hook.totalIMDBurned(), 0.06 ether);
        hook.manumit();
        _ledger();
    }

    function test_minimumBatchAndReservedCap() public {
        _fees(2.801999 ether);
        vm.roll(block.number + 5);
        vm.expectRevert(ManumissionHook.NothingToBurn.selector);
        hook.burnIMD(false, 0);
        _fees(0.000001 ether);
        manager.configureSwap(10000, 0.002 ether);
        hook.burnIMD(false, 0);
        assertEq(manager.lastInput(), 0.002 ether);
        assertEq(manager.balanceOf(HOOK, 0), 2.8 ether);
        _ledger();
    }

    function test_partialAndZeroFillsAndSlippageRollback() public {
        _ready();
        manager.configureSwap(9999, 0.05 ether);
        vm.expectRevert(ManumissionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        manager.configureSwap(10000, 0);
        vm.expectRevert(ManumissionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        manager.configureSwap(0, 0);
        vm.expectRevert(ManumissionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        manager.configureSwap(10000, 0.048 ether - 1);
        vm.expectRevert(ManumissionHook.Slippage.selector);
        hook.burnIMD(false, 0);
        manager.configureSwap(10000, 0.05 ether);
        vm.expectRevert(ManumissionHook.Slippage.selector);
        hook.burnIMD(false, 0.05 ether + 1);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.lastBurnBlock(), 1000);
        assertEq(imd.balanceOf(DEAD), 0);
        hook.burnIMD(false, 0.05 ether);
        _ledger();
    }

    function test_oneSidedNormalGuards() public {
        _ready();
        manager.setSpot(hook.burnPoolKey(false), -301);
        vm.expectRevert(ManumissionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        manager.setSpot(hook.burnPoolKey(false), -300);
        hook.burnIMD(false, 0);
        vm.roll(block.number + 5);
        manager.setSpot(hook.burnPoolKey(true), -151);
        vm.expectRevert(ManumissionHook.PriceOffReference.selector);
        hook.burnIMD(true, 0);
        manager.setSpot(hook.burnPoolKey(true), -150);
        hook.burnIMD(true, 0);
        vm.roll(block.number + 5);
        manager.setSpot(hook.burnPoolKey(true), 10000);
        hook.burnIMD(true, 0); // Favorable spot has no upper deviation guard.
    }

    function test_refTickHasNoStalenessAndNormalReseeds() public {
        _ready();
        vm.roll(block.number + 100000);
        oracle.configure(true, 1000);
        manager.setSpot(hook.burnPoolKey(false), 1000);
        manager.configureSwap(10000, 1 ether);
        hook.burnIMD(false, 0);
        assertEq(hook.anchor(), 1000);
        assertEq(hook.lastRef(), 1000);
        assertEq(hook.blockStartAnchor(), 1000);
        oracle.configure(true, -400);
        hook.pokeAnchor();
        assertEq(hook.anchor(), -400);
        assertEq(hook.lastRefBlock(), block.number);
    }

    function test_fallbackPokeUsesStartOfBlockAnchorForGuardAndMinOut() public {
        _ready();
        oracle.configure(false, 0);
        manager.setSpot(hook.burnPoolKey(false), -200);
        hook.pokeAnchor();
        assertEq(hook.anchor(), -200);
        assertEq(hook.blockStartAnchor(), 0);
        vm.expectRevert(ManumissionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        // Above the old guard but a minimum acceptable only with the newly lowered anchor.
        manager.setSpot(hook.burnPoolKey(false), -140);
        manager.configureSwap(10000, 0.0095 ether);
        vm.expectRevert(ManumissionHook.Slippage.selector);
        hook.burnIMD(false, 0);
        manager.configureSwap(10000, 0.0096 ether);
        hook.burnIMD(false, 0);
        assertEq(hook.anchor(), -200); // no second step in the same block
    }

    function test_fallbackBandAndRecenteringNeverCatchesUpSteps() public {
        oracle.configure(false, 0);
        manager.setSpot(hook.burnPoolKey(false), -10000);
        for (uint256 i; i < 8; ++i) {
            vm.roll(block.number + 1);
            hook.pokeAnchor();
            int24 expected = i < 5 ? -int24(int256((i + 1) * 200)) : int24(-1000);
            assertEq(hook.anchor(), expected);
            hook.pokeAnchor();
            assertEq(hook.anchor(), expected);
        }
        assertEq(hook.lastRef(), 0);
        vm.roll(1100);
        hook.pokeAnchor();
        assertEq(hook.blockStartAnchor(), -1000);
        assertEq(hook.lastRef(), -1000);
        assertEq(hook.anchor(), -1200);
        assertEq(hook.lastRefBlock(), 1100);
        vm.roll(10000);
        hook.pokeAnchor();
        assertEq(hook.lastRef(), -1200);
        assertEq(hook.anchor(), -1400); // long idle time still permits just one step
    }

    function test_fallbackUpperBandAndTickExtremes() public {
        oracle.configure(true, TickMath.MAX_TICK);
        hook.pokeAnchor();
        oracle.configure(false, 0);
        vm.roll(block.number + 1);
        manager.setSpot(hook.burnPoolKey(false), TickMath.MAX_TICK);
        hook.pokeAnchor();
        assertEq(hook.anchor(), TickMath.MAX_TICK);
        oracle.configure(true, 0);
        hook.pokeAnchor();
        oracle.configure(false, 0);
        manager.setSpot(hook.burnPoolKey(false), 10000);
        for (uint256 i; i < 8; ++i) {
            vm.roll(block.number + 1);
            hook.pokeAnchor();
        }
        assertEq(hook.anchor(), 1000);
        assertEq(hook.lastRef(), 0);
    }

    function test_malformedOracleResponsesFailClosed() public {
        _ready();
        oracle.configure(true, int256(TickMath.MAX_TICK) + 1);
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        oracle.configure(true, int256(TickMath.MIN_TICK) - 1);
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        vm.etch(POOL4, hex"600160005360016000f3");
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        vm.etch(POOL4, hex"600260005260206000f3"); // noncanonical bool
        vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        vm.etch(POOL4, hex"5f5ffd");
        manager.configureSwap(10000, 0.01 ether);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_quoteIgnoresLPFee() public view {
        assertEq(hook.quoteAtTick(0, 1 ether), 1 ether);
        assertApproxEqAbs(hook.quoteAtTick(100, 1 ether), 1010049662092876568, 1);
        assertApproxEqAbs(hook.quoteAtTick(-100, 1 ether), 990050328741209481, 1);
        assertGt(hook.quoteAtTick(TickMath.MAX_TICK, 0.05 ether), 0);
        assertEq(hook.quoteAtTick(TickMath.MIN_TICK, 0.05 ether), 0);
    }

    function test_runtimeOpcodeWalk() public {
        _scan(HOOK.code);
        _scan(address(new ManumissionToken()).code);
    }

    function _scan(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff);
        }
    }
}
