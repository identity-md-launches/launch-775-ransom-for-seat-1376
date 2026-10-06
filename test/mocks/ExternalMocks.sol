// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ManumissionHook} from "../../src/ManumissionHook.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "./MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract MockPool4 {
    bool public marketOpen;
    int256 public refTick;

    function configure(bool open, int256 tick) external {
        marketOpen = open;
        refTick = tick;
    }

    // These are the callbacks encoded by the fixed POOL4 address (0x2840).
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }
}

contract MockSeat {
    address public holder;
    address public approved;
    uint256 public behavior;
    ManumissionHook public target;

    function configure(address owner, address approval, uint256 mode, ManumissionHook hook) external {
        holder = owner;
        approved = approval;
        behavior = mode;
        target = hook;
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(id == 1376);
        require(behavior != 4, "unreadable");
        return holder;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(msg.sender == approved, "not approved");
        require(from == holder && id == 1376);
        if (behavior == 1) return; // A dishonest successful transfer.
        if (behavior == 2) {
            _locked(abi.encodeCall(target.manumit, ()));
            _locked(abi.encodeCall(target.burnIMD, (false, 0)));
            _locked(abi.encodeCall(target.pokeAnchor, ()));
        }
        holder = to;
        if (behavior == 3) behavior = 4; // Re-read becomes unavailable.
    }

    function _locked(bytes memory callData) private {
        (bool ok, bytes memory result) = address(target).call(callData);
        require(
            !ok
                && keccak256(result)
                    == keccak256(abi.encodeWithSelector(ManumissionHook.ReentrantCall.selector))
        );
    }
}

contract RejectETH {
    receive() external payable {
        revert("reject");
    }
}

/// @dev Scriptable unit double; real PoolManager settlement is tested separately.
contract MockManager {
    using PoolIdLibrary for PoolKey;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(bytes32 => bytes32) public words;
    uint256 public fillBps;
    uint256 public output;
    bytes32 public lastPool;
    uint256 public lastInput;
    bool public unlocked;

    function setSpot(PoolKey memory key, int24 tick) external {
        bytes32 slot = keccak256(abi.encode(key.toId(), uint256(6)));
        words[slot] = bytes32(uint256(TickMath.getSqrtPriceAtTick(tick)) | (uint256(uint24(tick)) << 160));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return words[slot];
    }

    function configureSwap(uint256 fill, uint256 outAmount) external {
        fillBps = fill;
        output = outAmount;
    }

    function initialize(ManumissionHook hook, PoolKey memory key) external {
        hook.afterInitialize(msg.sender, key, uint160(1) << 96, 0);
    }

    function trade(ManumissionHook hook, PoolKey memory key, SwapParams memory params, BalanceDelta raw)
        external
        returns (int128 afterFee)
    {
        hook.beforeSwap(msg.sender, key, params, "");
        (, afterFee) = hook.afterSwap(msg.sender, key, params, raw, "");
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        require(msg.sender == from && unlocked);
        balanceOf[from][id] -= amount;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        require(!unlocked, "already unlocked");
        unlocked = true;
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
        return result;
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (BalanceDelta)
    {
        require(unlocked && params.zeroForOne && params.amountSpecified < 0);
        require(params.sqrtPriceLimitX96 == TickMath.MIN_SQRT_PRICE + 1);
        lastPool = PoolId.unwrap(key.toId());
        lastInput = uint256(-params.amountSpecified);
        return toBalanceDelta(-int128(int256(lastInput * fillBps / 10000)), int128(int256(output)));
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(unlocked);
        if (Currency.unwrap(currency) == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "payment failed");
        } else {
            MockERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
    }
}
