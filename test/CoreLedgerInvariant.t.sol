// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ManumissionHook} from "src/ManumissionHook.sol";
import {ManumissionToken} from "src/ManumissionToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {LifecycleRouter} from "./mocks/LifecycleRouter.sol";
import {MockPool4, MockSeat} from "./mocks/ExternalMocks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Real core performs swaps, mints/burns claims and enforces zero outstanding deltas.
/// External seat, IMD and POOL4 contracts are local doubles at the fixed addresses.
contract CoreLedgerHandler is Test {
    using PoolIdLibrary for PoolKey;
    ManumissionHook public immutable hook;
    IPoolManager public immutable manager;
    LifecycleRouter public immutable router;
    PoolKey internal key;
    uint256 public fees;
    uint256 public donations;
    uint256 public spent;
    uint256 public imdReceived;
    uint256 public paymentCount;
    uint256 public crossingCount;
    uint256 public successfulBurns;
    uint256 public lastBurn;

    constructor(ManumissionHook h, IPoolManager m, LifecycleRouter r, PoolKey memory k) {
        hook = h;
        manager = m;
        router = r;
        key = k;
        lastBurn = block.number;
    }

    function actor(uint8 seed) public pure returns (address) {
        return address(uint160(0x50000 + uint256(seed % 4)));
    }

    function trade(uint96 raw, bool buy, bool exactIn, uint8 callerSeed) external {
        uint256 amount = bound(raw, 1e6, 50 ether);
        vm.recordLogs();
        vm.prank(actor(callerSeed));
        BalanceDelta result = router.swap(
            key,
            SwapParams(
                buy,
                exactIn ? -int256(amount) : int256(amount),
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        uint256 fee;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter == address(manager)
                    && entry.topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                assertEq(entry.topics[1], PoolId.unwrap(key.toId()));
                (int128 rawETH, int128 rawToken,,,,) =
                    abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
                uint256 magnitude = uint256(rawETH < 0 ? -int256(rawETH) : int256(rawETH));
                fee = buy == exactIn ? amount / 50 : magnitude / 50;
                assertEq(int256(result.amount0()) + int256(fee), int256(rawETH));
                assertEq(result.amount1(), rawToken);
                found = true;
            }
            if (entry.emitter == address(hook) && entry.topics[0] == keccak256("Manumitted(uint256,uint256)"))
            {
                ++crossingCount;
                (, uint256 atBlock) = abi.decode(entry.data, (uint256, uint256));
                assertEq(atBlock, block.number);
            }
        }
        assertTrue(found, "core Swap event missing");
        fees += fee;
        assertEq(crossingCount, fees >= 2.8 ether ? 1 : 0);
    }

    function donate(uint96 raw) external {
        uint256 amount = bound(raw, 0, 3 ether);
        router.donateClaims(key, address(hook), amount);
        donations += amount;
    }

    function advance(uint8 blocks_) external {
        vm.roll(block.number + blocks_);
    }

    function manumit(uint8 callerSeed, bool approved) external {
        if (fees < 2.8 ether) {
            vm.expectRevert(ManumissionHook.StillEnslaved.selector);
        } else if (paymentCount != 0) {
            vm.expectRevert(ManumissionHook.AlreadyBuried.selector);
        } else {
            MockSeat(hook.IDENTITY_MD())
                .configure(hook.CREATOR(), approved ? address(hook) : address(0), 0, hook);
            if (!approved) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        ManumissionHook.BurialRefused.selector,
                        abi.encodeWithSignature("Error(string)", "not approved")
                    )
                );
            }
        }
        vm.prank(actor(callerSeed));
        hook.manumit();
        if (fees >= 2.8 ether && paymentCount == 0 && approved) ++paymentCount;
    }

    function burn(bool viaPool4, bool normal, bool impossibleMinimum, uint8 callerSeed) external {
        MockPool4(hook.POOL4_HOOK()).configure(normal, 0);
        uint256 available = fees > 2.8 ether ? fees - 2.8 ether - spent : 0;
        uint256 batch = normal ? 0.05 ether : 0.01 ether;
        if (batch > available) batch = available;
        uint256 beforeIMD = MockERC20(hook.IMD()).balanceOf(hook.DEAD());
        bool succeeds;
        if (block.number < lastBurn + 5) vm.expectRevert(ManumissionHook.TooSoon.selector);
        else if (!normal && viaPool4) vm.expectRevert(ManumissionHook.Pool4Unavailable.selector);
        else if (batch < 0.002 ether) vm.expectRevert(ManumissionHook.NothingToBurn.selector);
        else if (impossibleMinimum) vm.expectRevert(ManumissionHook.Slippage.selector);
        else succeeds = true;
        vm.prank(actor(callerSeed));
        hook.burnIMD(viaPool4, impossibleMinimum ? type(uint256).max : 0);
        if (succeeds) {
            uint256 output = MockERC20(hook.IMD()).balanceOf(hook.DEAD()) - beforeIMD;
            assertGt(output, 0);
            spent += batch;
            imdReceived += output;
            lastBurn = block.number;
            ++successfulBurns;
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract CoreLedgerInvariantTest is Test {
    using TransientStateLibrary for IPoolManager;
    IPoolManager manager;
    ManumissionHook hook;
    ManumissionToken token;
    LifecycleRouter router;
    CoreLedgerHandler handler;

    function setUp() public {
        vm.roll(1000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        address oracle = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
        vm.etch(oracle, address(new MockPool4()).code);
        MockPool4(oracle).configure(true, 0);
        address at = address(0x1010cc);
        deployCodeTo("ManumissionHook.sol:ManumissionHook", abi.encode(manager), at);
        hook = ManumissionHook(at);
        token = new ManumissionToken();
        router = new LifecycleRouter(manager);
        vm.deal(address(router), 1e30);
        token.transfer(address(router), 1e27);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(at));
        manager.initialize(key, uint160(1) << 96);
        router.liquidity(key, -60000, 60000, 100000 ether);
        vm.etch(hook.IDENTITY_MD(), address(new MockSeat()).code);
        MockSeat(hook.IDENTITY_MD()).configure(hook.CREATOR(), at, 0, hook);
        vm.etch(hook.IMD(), address(new MockERC20("IMD", "IMD", 0)).code);
        MockERC20(hook.IMD()).mint(address(router), 1e27);
        for (uint256 i; i < 2; ++i) {
            PoolKey memory burnKey = hook.burnPoolKey(i == 1);
            manager.initialize(burnKey, uint160(1) << 96);
            router.liquidity(burnKey, -60000, 60000, 100000 ether);
        }
        handler = new CoreLedgerHandler(hook, manager, router, key);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.manumit.selector;
        selectors[4] = handler.burn.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// @notice Spec 4-7: earned fees, donated claims, payments and burns conserve native claims.
    function invariant_coreClaimsCoverIndependentFeeLedger() public view {
        uint256 paid = handler.paymentCount() * 2.8 ether;
        assertEq(hook.totalFees(), handler.fees());
        assertEq(hook.creatorPaid(), paid);
        assertEq(hook.burnSpent(), handler.spent());
        assertEq(hook.lastBurnBlock(), handler.lastBurn());
        assertEq(
            manager.balanceOf(address(hook), 0), handler.fees() + handler.donations() - paid - handler.spent()
        );
        uint256 reserved = handler.fees() < 2.8 ether ? handler.fees() : 2.8 ether;
        assertEq(hook.creatorEntitlement(), reserved);
        assertEq(hook.burnable() + handler.spent() + reserved, handler.fees());
    }

    /// @notice No open core unlock or currency debt survives any complete user transaction.
    function invariant_settlementAndRecipientIsolation() public view {
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(hook.IMD())), 0);
        assertEq(hook.totalIMDBurned(), handler.imdReceived());
        assertEq(MockERC20(hook.IMD()).balanceOf(hook.DEAD()), handler.imdReceived());
        assertEq(hook.CREATOR().balance, handler.paymentCount() * 2.8 ether);
        assertLe(handler.paymentCount(), 1);
        assertEq(hook.buried(), handler.paymentCount() == 1);
        assertEq(MockSeat(hook.IDENTITY_MD()).holder(), hook.buried() ? hook.DEAD() : hook.CREATOR());
        assertEq(address(hook).balance, 0);
        assertEq(MockERC20(hook.IMD()).balanceOf(address(hook)), 0);
        for (uint8 i; i < 4; ++i) {
            assertEq(handler.actor(i).balance, 0);
            assertEq(MockERC20(hook.IMD()).balanceOf(handler.actor(i)), 0);
        }
    }

    function test_sequenceExercisesReservedRansomFailuresAndPostBurialBurns() public {
        handler.donate(3 ether);
        handler.manumit(0, true); // claims alone cannot buy freedom
        for (uint256 i; i < 3; ++i) {
            handler.trade(50 ether, true, true, 0);
        }
        handler.advance(5);
        handler.burn(false, true, true, 1); // failed slippage leaves the batch available
        handler.burn(true, true, false, 1); // burn excess while ransom remains reserved
        handler.manumit(2, false);
        handler.manumit(3, true);
        handler.manumit(0, true);
        handler.advance(5);
        handler.burn(true, false, false, 2); // POOL4 unavailable in fallback
        handler.burn(false, false, false, 2);
        assertEq(handler.successfulBurns(), 2);
        assertEq(handler.paymentCount(), 1);
        assertEq(handler.crossingCount(), 1);
        invariant_coreClaimsCoverIndependentFeeLedger();
        invariant_settlementAndRecipientIsolation();
    }
}
