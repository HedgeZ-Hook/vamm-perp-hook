// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract PerpHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    error UnauthorizedVammSwapper(address sender);

    PoolId public spotPoolId;
    PoolId public vammPoolId;
    address public clearingHouse;

    event VammSwapAttempt(address indexed sender);
    event VammSwapExecuted(address indexed sender, BalanceDelta delta);
    event SpotLPAdded(address indexed sender, int256 liquidity);
    event SpotLPRemovalRequested(address indexed sender);
    event SpotLPRemoved(address indexed sender);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) Ownable(msg.sender) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function registerSpotPool(PoolKey calldata key) external onlyOwner {
        spotPoolId = key.toId();
    }

    function registerVAMMPool(PoolKey calldata key) external onlyOwner {
        vammPoolId = key.toId();
    }

    function setClearingHouse(address clearingHouse_) external onlyOwner {
        clearingHouse = clearingHouse_;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) == PoolId.unwrap(vammPoolId)) {
            if (clearingHouse != address(0) && sender != clearingHouse) revert UnauthorizedVammSwapper(sender);
            emit VammSwapAttempt(sender);
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (PoolId.unwrap(key.toId()) == PoolId.unwrap(vammPoolId)) {
            emit VammSwapExecuted(sender, delta);
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (PoolId.unwrap(key.toId()) == PoolId.unwrap(spotPoolId)) {
            emit SpotLPAdded(sender, params.liquidityDelta);
        }
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        if (PoolId.unwrap(key.toId()) == PoolId.unwrap(spotPoolId)) {
            emit SpotLPRemovalRequested(sender);
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (PoolId.unwrap(key.toId()) == PoolId.unwrap(spotPoolId)) {
            emit SpotLPRemoved(sender);
        }
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
