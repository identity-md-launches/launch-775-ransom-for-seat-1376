// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ManumissionHook} from "../src/ManumissionHook.sol";
import {ManumissionToken} from "../src/ManumissionToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockPool4, MockSeat} from "./mocks/ExternalMocks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {LifecycleRouter} from "./mocks/LifecycleRouter.sol";

contract LifecycleTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    IPoolManager manager;
    ManumissionHook hook;
    ManumissionToken token;
    LifecycleRouter router;
    PoolKey key;
    address constant HOOK = address(0x1010cc);

    function setUp() public {
        vm.roll(1000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        deployCodeTo("ManumissionHook.sol:ManumissionHook", abi.encode(address(manager)), HOOK);
        hook = ManumissionHook(HOOK);
        token = new ManumissionToken();
        router = new LifecycleRouter(manager);
        vm.deal(address(router), 1e30);
        token.transfer(address(router), 1e27);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(HOOK));
        manager.initialize(key, uint160(1) << 96);
    }

    function _seed() private {
        router.liquidity(key, -60000, 60000, 100000 ether);
    }

    function _params(bool buy, bool exactIn, uint256 amount) private pure returns (SwapParams memory) {
        return SwapParams(
            buy,
            exactIn ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _settled() private view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(manager.balanceOf(HOOK, 0), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
        assertEq(manager.currencyDelta(HOOK, Currency.wrap(address(0))), 0);
    }

    function test_tokenOnlyLaunchFirstBuySucceedsWithZeroManagerETH() public {
        // Entire position is token1 at tick zero. A buy moves down into that liquidity.
        router.liquidity(key, -60000, 0, 100000 ether);
        assertEq(address(manager).balance, 0);
        BalanceDelta result = router.swap(key, _params(true, true, 1 ether));
        assertEq(result.amount0(), -1 ether);
        assertGt(result.amount1(), 0);
        assertEq(manager.balanceOf(HOOK, 0), 0.02 ether);
        assertEq(hook.totalFees(), 0.02 ether);
        _settled();
    }

    function testFuzz_feeDeltasMatchRealCore(bool buy, bool exactIn, uint96 input) public {
        uint256 amount = bound(input, 1e6, 10 ether);
        _seed();
        vm.recordLogs();
        BalanceDelta result = router.swap(key, _params(buy, exactIn, amount));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int128 rawETH;
        int128 rawToken;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                (rawETH, rawToken,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found);
        uint256 fee = buy == exactIn
            ? amount * 200 / 10000
            : uint256(rawETH < 0 ? -int256(rawETH) : int256(rawETH)) * 200 / 10000;
        assertEq(result.amount0(), int256(rawETH) - int256(fee));
        assertEq(result.amount1(), rawToken);
        assertEq(manager.balanceOf(HOOK, 0), fee);
        assertEq(hook.totalFees(), fee);
        if (buy == exactIn) assertEq(result.amount0(), exactIn ? -int256(amount) : int256(amount));
        assertEq(hook.CREATOR().balance, 0);
        _settled();
    }

    function test_beforeFeePartialFillRevertsForBothDirections() public {
        _seed();
        SwapParams memory p = _params(true, true, 1000 ether);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(-1);
        _expectPartial();
        router.swap(key, p);
        p = _params(false, false, 1000 ether);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(1);
        _expectPartial();
        router.swap(key, p);
        assertEq(hook.totalFees(), 0);
        _settled();
    }

    function _expectPartial() private {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                HOOK,
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(ManumissionHook.PartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_otherNativePoolTradesFeeFreeAndLiquidityCanExit() public {
        _seed();
        PoolKey memory other = key;
        other.fee = 10000;
        manager.initialize(other, uint160(1) << 96);
        router.liquidity(other, -60000, 60000, 1000 ether);
        router.swap(other, _params(true, true, 1 ether));
        assertEq(hook.totalFees(), 0);
        router.liquidity(other, -60000, 60000, -1000 ether);
        router.liquidity(key, -60000, 60000, -100000 ether);
        _settled();
    }

    function test_donationsCannotPayRansomOrBeSpent() public {
        _seed();
        router.donateClaims(key, HOOK, 5 ether);
        assertEq(manager.balanceOf(HOOK, 0), 5 ether);
        assertEq(hook.totalFees(), 0);
        assertEq(hook.burnable(), 0);
        vm.expectRevert(ManumissionHook.StillEnslaved.selector);
        hook.manumit();
        router.swap(key, _params(true, true, 1 ether));
        assertEq(manager.balanceOf(HOOK, 0), 5.02 ether);
        assertEq(hook.totalFees(), 0.02 ether);
    }

    function test_realBurialAndBothBurnRoutes() public {
        _seed();
        router.swap(key, _params(true, true, 150 ether));
        assertEq(hook.totalFees(), 3 ether);
        vm.etch(hook.IDENTITY_MD(), address(new MockSeat()).code);
        MockSeat seat = MockSeat(hook.IDENTITY_MD());
        seat.configure(hook.CREATOR(), HOOK, 0, hook);
        hook.manumit();
        assertEq(seat.holder(), hook.DEAD());
        assertEq(hook.CREATOR().balance, 2.8 ether);
        _settled();

        vm.etch(hook.IMD(), address(new MockERC20("IMD", "IMD", 0)).code);
        MockERC20 imd = MockERC20(hook.IMD());
        imd.mint(address(router), 1e25);
        vm.etch(hook.POOL4_HOOK(), address(new MockPool4()).code);
        MockPool4(hook.POOL4_HOOK()).configure(true, 0);
        PoolKey memory plain = hook.burnPoolKey(false);
        PoolKey memory pool4 = hook.burnPoolKey(true);
        manager.initialize(plain, uint160(1) << 96);
        manager.initialize(pool4, uint160(1) << 96);
        router.liquidity(plain, -60000, 60000, 1000 ether);
        router.liquidity(pool4, -60000, 60000, 1000 ether);
        vm.roll(block.number + 5);
        hook.burnIMD(false, 0.048 ether);
        assertGt(imd.balanceOf(hook.IMD_SINK()), 0.048 ether);
        assertEq(hook.totalIMDBurned(), imd.balanceOf(hook.IMD_SINK()));
        assertEq(hook.burnSpent(), 0.05 ether);
        _settled();
        vm.roll(block.number + 5);
        hook.burnIMD(true, 0.048 ether);
        assertEq(hook.burnSpent(), 0.1 ether);
        assertEq(hook.totalIMDBurned(), imd.balanceOf(hook.IMD_SINK()));
        _settled();
        vm.roll(block.number + 5);
        MockPool4(hook.POOL4_HOOK()).configure(false, 0);
        hook.burnIMD(false, 0.0096 ether);
        assertEq(hook.burnSpent(), 0.11 ether);
        _settled();
    }

    function test_burnCannotRunInsideSomeoneElsesUnlock() public {
        _seed();
        router.swap(key, _params(true, true, 150 ether));
        vm.etch(hook.POOL4_HOOK(), address(new MockPool4()).code);
        MockPool4(hook.POOL4_HOOK()).configure(true, 0);
        // manumit needs its own unlock, even when the NFT already sits at DEAD.
        vm.etch(hook.IDENTITY_MD(), address(new MockSeat()).code);
        MockSeat(hook.IDENTITY_MD()).configure(hook.DEAD(), address(0), 0, hook);
        manager.initialize(hook.burnPoolKey(false), uint160(1) << 96);
        vm.roll(block.number + 5);
        manager.unlock("");
        assertFalse(hook.buried());
        assertEq(hook.burnSpent(), 0);
        _settled();
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        hook.manumit();
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        hook.burnIMD(false, 0);
        return "";
    }
}
