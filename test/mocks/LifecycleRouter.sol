// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {MockERC20} from "./MockERC20.sol";

contract LifecycleRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    IPoolManager public immutable manager;

    constructor(IPoolManager pm) {
        manager = pm;
    }
    receive() external payable {}

    function liquidity(PoolKey memory key, int24 low, int24 high, int256 amount) external {
        manager.unlock(abi.encode(uint8(0), key, abi.encode(ModifyLiquidityParams(low, high, amount, 0))));
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(params))), (BalanceDelta));
    }

    function donateClaims(PoolKey memory key, address to, uint256 amount) external {
        manager.unlock(abi.encode(uint8(2), key, abi.encode(to, amount)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == address(manager));
        (uint8 operation, PoolKey memory key, bytes memory args) = abi.decode(data, (uint8, PoolKey, bytes));
        if (operation == 0) {
            manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        } else if (operation == 1) {
            result = abi.encode(manager.swap(key, abi.decode(args, (SwapParams)), ""));
        } else {
            (address to, uint256 amount) = abi.decode(args, (address, uint256));
            manager.mint(to, 0, amount);
        }
        _settle(key.currency0);
        _settle(key.currency1);
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta > 0) manager.take(currency, address(this), uint256(delta));
        if (delta < 0) {
            uint256 amount = uint256(-delta);
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                MockERC20(Currency.unwrap(currency)).transfer(address(manager), amount);
                manager.settle();
            }
        }
    }
}
