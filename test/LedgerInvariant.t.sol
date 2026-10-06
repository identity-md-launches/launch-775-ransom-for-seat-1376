// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ManumissionHook} from "../src/ManumissionHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockManager, MockPool4, MockSeat} from "./mocks/ExternalMocks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract LedgerHandler is Test {
    ManumissionHook public hook;
    MockManager public manager;
    PoolKey internal key;
    uint256 public donations;
    uint256 public observedFees;

    constructor(ManumissionHook h, MockManager m, PoolKey memory k) {
        hook = h;
        manager = m;
        key = k;
    }

    function trade(uint96 rawAmount, bool buy, bool exactIn) external {
        uint256 amount = bound(rawAmount, 1, 50 ether);
        uint256 fee = amount / 50;
        int256 rawETH = buy ? -int256(amount) : int256(amount);
        if (buy == exactIn) rawETH += int256(fee);
        manager.trade(
            hook,
            key,
            SwapParams(buy, exactIn ? -int256(amount) : int256(amount), 1),
            toBalanceDelta(int128(rawETH), buy ? int128(1) : int128(-1))
        );
        observedFees += fee;
    }

    function donate(uint96 amount) external {
        manager.mint(address(hook), 0, amount);
        donations += amount;
    }

    function burn(bool viaPool4, bool fallbackMode) external {
        vm.roll(block.number + 5);
        MockPool4(hook.POOL4_HOOK()).configure(!fallbackMode, 0);
        if (fallbackMode && viaPool4) return;
        if (hook.burnable() < hook.MIN_BURN()) return;
        manager.configureSwap(10000, 0.05 ether);
        hook.burnIMD(viaPool4, 0);
    }

    function manumit() external {
        if (hook.totalFees() < hook.CREATOR_CAP() || hook.buried()) return;
        hook.manumit();
    }
}

contract LedgerInvariantTest is StdInvariant, Test {
    ManumissionHook hook;
    MockManager manager;
    LedgerHandler handler;
    MockERC20 imd;

    function setUp() public {
        manager = new MockManager();
        vm.deal(address(manager), 100 ether);
        address oracle = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
        vm.etch(oracle, address(new MockPool4()).code);
        MockPool4(oracle).configure(true, 0);
        address at = address(0x1010cc);
        deployCodeTo("ManumissionHook.sol:ManumissionHook", abi.encode(address(manager)), at);
        hook = ManumissionHook(at);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0x1234)), 3000, 60, IHooks(at));
        manager.initialize(hook, key);
        vm.etch(hook.IDENTITY_MD(), address(new MockSeat()).code);
        MockSeat(hook.IDENTITY_MD()).configure(hook.CREATOR(), at, 0, hook);
        vm.etch(hook.IMD(), address(new MockERC20("IMD", "IMD", 0)).code);
        imd = MockERC20(hook.IMD());
        imd.mint(address(manager), 1e27);
        manager.setSpot(hook.burnPoolKey(false), 0);
        manager.setSpot(hook.burnPoolKey(true), 0);
        handler = new LedgerHandler(hook, manager, key);
        targetContract(address(handler));
    }

    function invariant_claimsCoverAllOutstandingObligations() public view {
        uint256 outstanding = hook.totalFees() - hook.creatorPaid() - hook.burnSpent();
        assertEq(manager.balanceOf(address(hook), 0), outstanding + handler.donations());
        assertEq(hook.totalFees(), handler.observedFees());
        assertEq(hook.burnable() + hook.burnSpent() + hook.creatorEntitlement(), hook.totalFees());
        assertLe(hook.creatorPaid(), 2.8 ether);
        assertEq(hook.CREATOR().balance, hook.creatorPaid());
        assertEq(hook.creatorPaid(), hook.buried() ? 2.8 ether : 0);
        assertEq(hook.totalIMDBurned(), imd.balanceOf(hook.DEAD()));
        if (hook.buried()) assertEq(MockSeat(hook.IDENTITY_MD()).holder(), hook.DEAD());
        if (hook.totalFees() < 2.8 ether) assertEq(hook.burnable(), 0);
    }
}
