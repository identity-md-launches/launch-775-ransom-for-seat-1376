// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ManumissionHook} from "src/ManumissionHook.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockManager, MockPool4} from "./mocks/ExternalMocks.sol";
import {AdversarialFixture} from "./mocks/AdversarialFixture.sol";

contract AnchorSequenceHandler is Test {
    ManumissionHook public immutable hook;
    MockManager public immutable manager;
    MockPool4 public immutable oracle;
    uint256 public reseeds;
    uint256 public fallbackCalls;

    struct Snapshot {
        int256 anchor;
        int256 start;
        int256 referenceTick;
        uint256 anchorBlock;
        uint256 referenceBlock;
    }

    constructor(ManumissionHook h, MockManager m) {
        hook = h;
        manager = m;
        oracle = MockPool4(h.POOL4_HOOK());
    }

    function reseed(int24 rawTick, uint8 callerSeed) external {
        int24 tick = _tick(rawTick);
        oracle.configure(true, tick);
        vm.prank(_actor(callerSeed));
        hook.pokeAnchor();
        assertEq(hook.anchor(), tick);
        assertEq(hook.blockStartAnchor(), tick);
        assertEq(hook.lastRef(), tick);
        assertEq(hook.lastRefBlock(), block.number);
        assertEq(hook.anchorBlock(), block.number);
        ++reseeds;
    }

    function fallbackStep(int24 rawSpot, uint16 idleBlocks, uint8 callerSeed) external {
        int24 spot = _tick(rawSpot);
        Snapshot memory before_ = Snapshot(
            hook.anchor(), hook.blockStartAnchor(), hook.lastRef(), hook.anchorBlock(), hook.lastRefBlock()
        );
        vm.roll(block.number + idleBlocks); // zero, 99/100, and long idle periods are all reachable
        oracle.configure(false, 0);
        manager.setSpot(hook.burnPoolKey(false), spot);
        vm.prank(_actor(callerSeed));
        hook.pokeAnchor();
        ++fallbackCalls;
        if (before_.anchorBlock == block.number) {
            assertEq(hook.anchor(), before_.anchor);
            assertEq(hook.blockStartAnchor(), before_.start);
            assertEq(hook.lastRef(), before_.referenceTick);
            assertEq(hook.lastRefBlock(), before_.referenceBlock);
        } else {
            assertEq(hook.blockStartAnchor(), before_.anchor);
            if (block.number - before_.referenceBlock >= 100) {
                assertEq(hook.lastRef(), before_.anchor);
                assertEq(hook.lastRefBlock(), block.number);
            } else {
                assertEq(hook.lastRef(), before_.referenceTick);
                assertEq(hook.lastRefBlock(), before_.referenceBlock);
            }
            int256 movement = int256(hook.anchor()) - before_.anchor;
            assertLe(_abs(movement), 200, "idle time must never multiply the allowed step");
            // The new anchor must lie between its previous value and the band-clamped spot.
            int256 target = spot;
            int256 referenceTick = hook.lastRef();
            if (target < referenceTick - 1000) target = referenceTick - 1000;
            if (target > referenceTick + 1000) target = referenceTick + 1000;
            if (target >= before_.anchor) {
                assertGe(hook.anchor(), before_.anchor);
                assertLe(hook.anchor(), target);
            } else {
                assertLe(hook.anchor(), before_.anchor);
                assertGe(hook.anchor(), target);
            }
            if (_abs(target - before_.anchor) <= 200) assertEq(hook.anchor(), target);
            else assertEq(_abs(movement), 200);
        }
        assertEq(hook.anchorBlock(), block.number);
        // A second caller with an opposite spot cannot make an additional step in this block.
        Snapshot memory after_ = Snapshot(
            hook.anchor(), hook.blockStartAnchor(), hook.lastRef(), hook.anchorBlock(), hook.lastRefBlock()
        );
        manager.setSpot(hook.burnPoolKey(false), -spot);
        vm.prank(_actor(callerSeed + uint256(1)));
        hook.pokeAnchor();
        assertEq(hook.anchor(), after_.anchor);
        assertEq(hook.blockStartAnchor(), after_.start);
        assertEq(hook.lastRef(), after_.referenceTick);
        assertEq(hook.lastRefBlock(), after_.referenceBlock);
    }

    function _tick(int24 raw) private pure returns (int24) {
        return int24(bound(int256(raw), int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK)));
    }

    function _abs(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }

    function _actor(uint256 seed) private pure returns (address) {
        return address(uint160(0x60000 + seed % 4));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract AnchorTransitionsTest is AdversarialFixture {
    AnchorSequenceHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new AnchorSequenceHandler(hook, manager);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.reseed.selector;
        selectors[1] = handler.fallbackStep.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// @notice Spec 7: fallback stays in the reference band and valid tick range after arbitrary reseeds.
    function invariant_anchorBandAndLedgerIsolation() public view {
        assertGe(hook.anchor(), TickMath.MIN_TICK);
        assertLe(hook.anchor(), TickMath.MAX_TICK);
        assertGe(int256(hook.anchor()), int256(hook.lastRef()) - 1000);
        assertLe(int256(hook.anchor()), int256(hook.lastRef()) + 1000);
        assertLe(hook.lastRefBlock(), block.number);
        assertLe(hook.anchorBlock(), block.number);
        assertTrue(hook.pool4Seen());
        assertEq(hook.totalFees(), 0);
        assertEq(hook.burnable(), 0);
        _unspent();
    }

    function test_recenterAtExactly100BlocksAndOnlyOneStepAfterLongIdle() public {
        handler.reseed(0, 0);
        handler.fallbackStep(10000, 1, 0);
        assertEq(hook.anchor(), 200);
        handler.fallbackStep(10000, 98, 1);
        assertEq(hook.anchor(), 400);
        assertEq(hook.lastRef(), 0);
        handler.fallbackStep(10000, 1, 2);
        assertEq(hook.lastRef(), 400);
        assertEq(hook.blockStartAnchor(), 400);
        assertEq(hook.anchor(), 600);
        handler.fallbackStep(-10000, 60000, 3);
        assertEq(hook.lastRef(), 600);
        assertEq(hook.anchor(), 400);
        assertEq(handler.fallbackCalls(), 4);
        invariant_anchorBandAndLedgerIsolation();
    }

    function test_minimumTickAndSameBlockNormalRecovery() public {
        handler.reseed(TickMath.MIN_TICK, 0);
        handler.fallbackStep(TickMath.MIN_TICK, 1, 1);
        assertEq(hook.anchor(), TickMath.MIN_TICK);
        handler.reseed(TickMath.MAX_TICK, 2);
        handler.fallbackStep(0, 0, 3);
        assertEq(hook.anchor(), TickMath.MAX_TICK);
        assertEq(handler.reseeds(), 2);
        invariant_anchorBandAndLedgerIsolation();
    }
}
