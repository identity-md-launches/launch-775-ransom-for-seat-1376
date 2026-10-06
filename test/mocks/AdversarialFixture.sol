// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ManumissionHook} from "src/ManumissionHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MockManager, MockPool4, MockSeat} from "./ExternalMocks.sol";
import {MockERC20} from "./MockERC20.sol";

abstract contract AdversarialFixture is Test {
    ManumissionHook internal hook;
    MockManager internal manager;
    MockPool4 internal oracle;
    MockSeat internal seat;
    MockERC20 internal imd;
    PoolKey internal key;
    address internal constant HOOK = address(0x1010cc);
    address internal constant POOL4 = 0xc6C965Bd164c483e87d0B550671798e9A3602840;

    function setUp() public virtual {
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
        vm.etch(hook.IDENTITY_MD(), address(new MockSeat()).code);
        seat = MockSeat(hook.IDENTITY_MD());
        seat.configure(hook.CREATOR(), HOOK, 0, hook);
        vm.etch(hook.IMD(), address(new MockERC20("IMD", "IMD", 0)).code);
        imd = MockERC20(hook.IMD());
        imd.mint(address(manager), 1e27);
        manager.setSpot(hook.burnPoolKey(false), 0);
        manager.setSpot(hook.burnPoolKey(true), 0);
        manager.configureSwap(10000, 0.05 ether);
    }

    function _earn(uint256 fee) internal {
        manager.trade(
            hook, key, SwapParams(true, -int256(fee * 50), 1), toBalanceDelta(-int128(int256(fee * 49)), 1)
        );
    }

    function _ready() internal {
        _earn(3 ether);
        vm.roll(block.number + 5);
    }

    function _unspent() internal view {
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.creatorPaid(), 0);
        assertFalse(hook.buried());
        assertEq(hook.totalIMDBurned(), 0);
        assertEq(manager.balanceOf(HOOK, 0), hook.totalFees());
        assertEq(hook.CREATOR().balance, 0);
        assertEq(imd.balanceOf(hook.DEAD()), 0);
        assertEq(hook.lastBurnBlock(), 1000);
    }
}

contract PaymentObserver {
    ManumissionHook public immutable hook;
    uint256 public received;

    constructor(ManumissionHook h) {
        hook = h;
    }

    receive() external payable {
        require(hook.buried() && hook.creatorPaid() == 2.8 ether, "payment before burial state");
        require(MockSeat(hook.IDENTITY_MD()).holder() == hook.DEAD(), "payment before NFT burial");
        _locked(abi.encodeCall(hook.manumit, ()));
        _locked(abi.encodeCall(hook.burnIMD, (false, 0)));
        _locked(abi.encodeCall(hook.pokeAnchor, ()));
        received += msg.value;
    }

    function _locked(bytes memory data) private {
        (bool ok, bytes memory result) = address(hook).call(data);
        require(
            !ok
                && keccak256(result)
                    == keccak256(abi.encodeWithSelector(ManumissionHook.ReentrantCall.selector)),
            "reentrancy was not locked"
        );
    }
}
