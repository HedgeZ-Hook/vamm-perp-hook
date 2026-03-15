// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {PerpMath} from "./libraries/PerpMath.sol";

contract PerpHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error UnauthorizedVammSwapper(address sender);
    error UnauthorizedVammLiquidityOperator(address sender);
    error InvalidSpotFeeConfig(uint24 minFeeBps, uint24 baseFeeBps, uint24 maxFeeBps);
    error InvalidEmaAlpha(uint24 emaAlpha);
    error InvalidSizeRefQuote(uint256 sizeRefQuote);
    error InvalidFeePips(uint24 feePips);
    error RouterDoesNotImplementMsgSender(address router);

    PoolId public spotPoolId;
    PoolId public vammPoolId;
    address public clearingHouse;
    address public liquidityController;
    mapping(address => bool) public verifiedRouters;
    IPriceOracle public priceOracle;
    uint32 public twapInterval;

    uint24 public minFeeBps = 2;
    uint24 public baseFeeBps = 6;
    uint24 public maxFeeBps = 40;
    uint256 public sizeRefQuote = 1_000e18;
    uint24 public emaAlpha = 200_000;

    uint24 public spotVolEmaBps;
    uint256 public lastSpotPriceX18;

    event VammSwapAttempt(address indexed sender);
    event VammSwapExecuted(address indexed sender, BalanceDelta delta);
    event SpotLPAdded(address indexed sender, int256 liquidity);
    event SpotLPRemovalRequested(address indexed sender);
    event SpotLPRemoved(address indexed sender);
    event SpotFeeParamsUpdated(
        uint24 minFeeBps, uint24 baseFeeBps, uint24 maxFeeBps, uint256 sizeRefQuote, uint24 emaAlpha
    );
    event SpotVolEmaUpdated(uint24 previousEmaBps, uint24 newEmaBps, uint24 instantMoveBps);
    event SpotFeeOverrideApplied(address indexed sender, uint24 feePips);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) Ownable(msg.sender) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
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
        lastSpotPriceX18 = _poolPriceX18(spotPoolId);
    }

    function registerVAMMPool(PoolKey calldata key) external onlyOwner {
        vammPoolId = key.toId();
    }

    function setClearingHouse(address clearingHouse_) external onlyOwner {
        clearingHouse = clearingHouse_;
    }

    function setLiquidityController(address liquidityController_) external onlyOwner {
        liquidityController = liquidityController_;
    }

    function setVerifiedRouter(address router, bool approved) external onlyOwner {
        verifiedRouters[router] = approved;
    }

    function setPriceOracle(IPriceOracle priceOracle_, uint32 twapInterval_) external onlyOwner {
        priceOracle = priceOracle_;
        twapInterval = twapInterval_;
    }

    function setSpotFeeConfig(
        uint24 minFeeBps_,
        uint24 baseFeeBps_,
        uint24 maxFeeBps_,
        uint256 sizeRefQuote_,
        uint24 emaAlpha_
    ) external onlyOwner {
        if (minFeeBps_ > baseFeeBps_ || baseFeeBps_ > maxFeeBps_) {
            revert InvalidSpotFeeConfig(minFeeBps_, baseFeeBps_, maxFeeBps_);
        }
        uint24 maxFeePips = maxFeeBps_ * 100;
        if (maxFeePips > LPFeeLibrary.MAX_LP_FEE) revert InvalidFeePips(maxFeePips);
        if (sizeRefQuote_ == 0) revert InvalidSizeRefQuote(sizeRefQuote_);
        if (emaAlpha_ > 1e6) revert InvalidEmaAlpha(emaAlpha_);

        minFeeBps = minFeeBps_;
        baseFeeBps = baseFeeBps_;
        maxFeeBps = maxFeeBps_;
        sizeRefQuote = sizeRefQuote_;
        emaAlpha = emaAlpha_;
        emit SpotFeeParamsUpdated(minFeeBps_, baseFeeBps_, maxFeeBps_, sizeRefQuote_, emaAlpha_);
    }

    function getSpotPriceX18() external view returns (uint256) {
        return _poolPriceX18(spotPoolId);
    }

    function getVammPriceX18() external view returns (uint256) {
        return _poolPriceX18(vammPoolId);
    }

    function previewSpotFeePips(uint256 quoteNotional) external view returns (uint24 feePips) {
        uint256 spotPriceX18 = _poolPriceX18(spotPoolId);
        uint256 oraclePriceX18 = _getOraclePriceOrSpot(spotPriceX18);
        feePips = _computeSpotFeePips(quoteNotional, spotPriceX18, oraclePriceX18);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        if (PoolId.unwrap(poolId) == PoolId.unwrap(vammPoolId)) {
            if (!_isAuthorizedVammSwapper(sender)) revert UnauthorizedVammSwapper(sender);
            emit VammSwapAttempt(sender);
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                LPFeeLibrary.OVERRIDE_FEE_FLAG // vAMM fee = 0
            );
        }

        if (PoolId.unwrap(poolId) == PoolId.unwrap(spotPoolId)) {
            uint256 spotPriceX18 = _poolPriceX18(spotPoolId);
            uint256 oraclePriceX18 = _getOraclePriceOrSpot(spotPriceX18);
            uint256 quoteNotional = _deriveQuoteNotional(params, spotPriceX18);
            uint24 feePips = _computeSpotFeePips(quoteNotional, spotPriceX18, oraclePriceX18);
            emit SpotFeeOverrideApplied(sender, feePips);
            return
                (
                    BaseHook.beforeSwap.selector,
                    BeforeSwapDeltaLibrary.ZERO_DELTA,
                    feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG
                );
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        if (PoolId.unwrap(poolId) == PoolId.unwrap(vammPoolId)) {
            emit VammSwapExecuted(sender, delta);
        } else if (PoolId.unwrap(poolId) == PoolId.unwrap(spotPoolId)) {
            _updateSpotVolEma(_poolPriceX18(spotPoolId));
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (PoolId.unwrap(key.toId()) == PoolId.unwrap(vammPoolId)) {
            if (!_isAuthorizedVammLiquidityOperator(sender)) {
                revert UnauthorizedVammLiquidityOperator(sender);
            }
        }
        return BaseHook.beforeAddLiquidity.selector;
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
        PoolId poolId = key.toId();
        if (PoolId.unwrap(poolId) == PoolId.unwrap(vammPoolId)) {
            if (!_isAuthorizedVammLiquidityOperator(sender)) {
                revert UnauthorizedVammLiquidityOperator(sender);
            }
        } else if (PoolId.unwrap(poolId) == PoolId.unwrap(spotPoolId)) {
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

    function _poolPriceX18(PoolId poolId) internal view returns (uint256 priceX18) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) return 0;
        uint256 priceX96 = PerpMath.formatSqrtPriceX96ToPriceX96(sqrtPriceX96);
        priceX18 = PerpMath.formatX96ToX10_18(priceX96);
    }

    function _getOraclePriceOrSpot(uint256 spotPriceX18) internal view returns (uint256 oraclePriceX18) {
        if (address(priceOracle) == address(0)) return spotPriceX18;
        oraclePriceX18 = priceOracle.getIndexPrice(twapInterval);
        if (oraclePriceX18 == 0) return spotPriceX18;
    }

    function _computeSpotFeePips(uint256 quoteNotional, uint256 spotPriceX18, uint256 oraclePriceX18)
        internal
        view
        returns (uint24 feePips)
    {
        uint24 spreadBps = _calcSpreadBps(spotPriceX18, oraclePriceX18);
        uint24 spreadComponent = uint24(Math.min(spreadBps / 5, 20));
        uint24 volComponent = uint24(Math.min(spotVolEmaBps / 4, 10));
        uint24 sizeComponent = uint24(Math.min((quoteNotional * 15) / sizeRefQuote, 15));
        uint24 feeBps = _clampFeeBps(baseFeeBps + spreadComponent + volComponent + sizeComponent);
        feePips = feeBps * 100;
    }

    function _deriveQuoteNotional(SwapParams calldata params, uint256 spotPriceX18)
        internal
        pure
        returns (uint256 quoteNotional)
    {
        uint256 absAmountSpecified =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Assume spot quote token is currency1 (ETH/USDC style pool).
        if (params.zeroForOne) {
            quoteNotional = params.amountSpecified < 0
                ? FullMath.mulDiv(absAmountSpecified, spotPriceX18, 1e18)
                : absAmountSpecified;
        } else {
            quoteNotional = params.amountSpecified < 0
                ? absAmountSpecified
                : FullMath.mulDiv(absAmountSpecified, spotPriceX18, 1e18);
        }
    }

    function _calcSpreadBps(uint256 lhsPriceX18, uint256 rhsPriceX18) internal pure returns (uint24 spreadBps) {
        if (lhsPriceX18 == 0 || rhsPriceX18 == 0) return 0;
        uint256 spread = lhsPriceX18 > rhsPriceX18 ? lhsPriceX18 - rhsPriceX18 : rhsPriceX18 - lhsPriceX18;
        spreadBps = uint24(Math.min((spread * 10_000) / rhsPriceX18, type(uint24).max));
    }

    function _clampFeeBps(uint24 feeBps) internal view returns (uint24) {
        if (feeBps < minFeeBps) return minFeeBps;
        if (feeBps > maxFeeBps) return maxFeeBps;
        return feeBps;
    }

    function _updateSpotVolEma(uint256 newSpotPriceX18) internal {
        if (newSpotPriceX18 == 0) return;
        uint256 previousPriceX18 = lastSpotPriceX18;
        if (previousPriceX18 == 0) {
            lastSpotPriceX18 = newSpotPriceX18;
            return;
        }

        uint256 move = newSpotPriceX18 > previousPriceX18
            ? newSpotPriceX18 - previousPriceX18
            : previousPriceX18 - newSpotPriceX18;
        uint24 instantMoveBps = uint24(Math.min((move * 10_000) / previousPriceX18, type(uint24).max));
        uint24 previousEmaBps = spotVolEmaBps;
        uint256 newEmaBps = (uint256(previousEmaBps) * (1e6 - emaAlpha) + uint256(instantMoveBps) * emaAlpha) / 1e6;

        spotVolEmaBps = uint24(newEmaBps);
        lastSpotPriceX18 = newSpotPriceX18;
        emit SpotVolEmaUpdated(previousEmaBps, spotVolEmaBps, instantMoveBps);
    }

    function _isAuthorizedVammSwapper(address sender) internal view returns (bool) {
        address caller = _resolveSender(sender);
        return caller == clearingHouse || caller == liquidityController;
    }

    function _isAuthorizedVammLiquidityOperator(address sender) internal view returns (bool) {
        address caller = _resolveSender(sender);
        return caller == owner() || caller == liquidityController;
    }

    function _resolveSender(address sender) internal view returns (address caller) {
        if (!verifiedRouters[sender]) return sender;
        try IMsgSender(sender).msgSender() returns (address resolved) {
            caller = resolved;
        } catch {
            revert RouterDoesNotImplementMsgSender(sender);
        }
    }
}
