// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {PerpMath} from "./libraries/PerpMath.sol";

contract LiquidityController is AccessControl {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error InvalidBps(uint24 value);
    error InvalidOracle(address oracle);
    error InvalidMaxAmountInPerUpdate(uint256 amount);
    error VammLiquidityBelowFloor(uint128 currentLiquidity, uint128 minVammLiquidity);
    error MaxRepriceExceeded(uint256 postPriceX18, uint256 lowerBoundX18, uint256 upperBoundX18);

    uint256 internal constant BPS_BASE = 10_000;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q192 = 2 ** 192;

    IPoolManager public immutable poolManager;
    IUniswapV4Router04 public immutable swapRouter;

    IPriceOracle public priceOracle;
    PoolKey public vammPoolKey;
    PoolId public vammPoolId;
    uint32 public twapInterval;

    uint24 public deadbandBps;
    uint24 public maxRepriceBpsPerUpdate;
    uint256 public maxAmountInPerUpdate;
    uint128 public minVammLiquidity;

    event OracleUpdated(address indexed oracle, uint32 twapInterval);
    event ParamsUpdated(
        uint24 deadbandBps, uint24 maxRepriceBpsPerUpdate, uint256 maxAmountInPerUpdate, uint128 minVammLiquidity
    );
    event Repriced(
        bool indexed executed,
        bool indexed zeroForOne,
        uint256 amountIn,
        uint256 oraclePriceX18,
        uint256 preVammPriceX18,
        uint256 postVammPriceX18
    );

    constructor(
        IPoolManager poolManager_,
        IUniswapV4Router04 swapRouter_,
        IPriceOracle priceOracle_,
        PoolKey memory vammPoolKey_,
        uint32 twapInterval_,
        uint24 deadbandBps_,
        uint24 maxRepriceBpsPerUpdate_,
        uint256 maxAmountInPerUpdate_,
        uint128 minVammLiquidity_
    ) {
        if (address(priceOracle_) == address(0)) revert InvalidOracle(address(priceOracle_));
        if (maxAmountInPerUpdate_ == 0) revert InvalidMaxAmountInPerUpdate(maxAmountInPerUpdate_);

        _validateBps(deadbandBps_);
        _validateBps(maxRepriceBpsPerUpdate_);

        poolManager = poolManager_;
        swapRouter = swapRouter_;
        priceOracle = priceOracle_;
        vammPoolKey = vammPoolKey_;
        vammPoolId = vammPoolKey_.toId();
        twapInterval = twapInterval_;

        deadbandBps = deadbandBps_;
        maxRepriceBpsPerUpdate = maxRepriceBpsPerUpdate_;
        maxAmountInPerUpdate = maxAmountInPerUpdate_;
        minVammLiquidity = minVammLiquidity_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setParams(
        uint24 deadbandBps_,
        uint24 maxRepriceBpsPerUpdate_,
        uint256 maxAmountInPerUpdate_,
        uint128 minVammLiquidity_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxAmountInPerUpdate_ == 0) {
            revert InvalidMaxAmountInPerUpdate(maxAmountInPerUpdate_);
        }
        _validateBps(deadbandBps_);
        _validateBps(maxRepriceBpsPerUpdate_);

        deadbandBps = deadbandBps_;
        maxRepriceBpsPerUpdate = maxRepriceBpsPerUpdate_;
        maxAmountInPerUpdate = maxAmountInPerUpdate_;
        minVammLiquidity = minVammLiquidity_;

        emit ParamsUpdated(deadbandBps_, maxRepriceBpsPerUpdate_, maxAmountInPerUpdate_, minVammLiquidity_);
    }

    function setOracle(IPriceOracle priceOracle_, uint32 twapInterval_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(priceOracle_) == address(0)) revert InvalidOracle(address(priceOracle_));
        priceOracle = priceOracle_;
        twapInterval = twapInterval_;
        emit OracleUpdated(address(priceOracle_), twapInterval_);
    }

    function approveSpender(IERC20 token, address spender, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        token.approve(spender, amount);
    }

    function getOraclePriceX18() public view returns (uint256 priceX18) {
        priceX18 = priceOracle.getIndexPrice(twapInterval);
    }

    function getVammPriceX18() public view returns (uint256 priceX18) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(vammPoolId);
        if (sqrtPriceX96 == 0) return 0;
        uint256 priceX96 = PerpMath.formatSqrtPriceX96ToPriceX96(sqrtPriceX96);
        priceX18 = PerpMath.formatX96ToX10_18(priceX96);
    }

    function isLiquidityHealthy() public view returns (bool healthy) {
        healthy = poolManager.getLiquidity(vammPoolId) >= minVammLiquidity;
    }

    function updateFromOracle() external returns (bool executed, bool zeroForOne, uint256 usedAmountIn) {
        uint256 oraclePriceX18 = getOraclePriceX18();
        (uint160 preSqrtPriceX96, uint256 preVammPriceX18) = _getVammSqrtAndPriceX18();
        if (oraclePriceX18 == 0 || preVammPriceX18 == 0) {
            emit Repriced(false, false, 0, oraclePriceX18, preVammPriceX18, preVammPriceX18);
            return (false, false, 0);
        }

        uint256 spreadBps = _calcSpreadBps(preVammPriceX18, oraclePriceX18);
        if (spreadBps <= deadbandBps) {
            emit Repriced(false, false, 0, oraclePriceX18, preVammPriceX18, preVammPriceX18);
            return (false, false, 0);
        }

        uint128 currentLiquidity = poolManager.getLiquidity(vammPoolId);
        if (currentLiquidity < minVammLiquidity) {
            revert VammLiquidityBelowFloor(currentLiquidity, minVammLiquidity);
        }

        zeroForOne = preVammPriceX18 > oraclePriceX18;
        (uint256 lowerBoundX18, uint256 upperBoundX18) = _derivePriceBounds(preVammPriceX18);
        uint160 targetSqrtPriceX96 =
            _deriveSqrtLimitFromBounds(preSqrtPriceX96, lowerBoundX18, upperBoundX18, zeroForOne);
        uint256 estimatedAmountIn =
            _estimateAmountInToTarget(currentLiquidity, preSqrtPriceX96, targetSqrtPriceX96, zeroForOne);
        if (estimatedAmountIn == 0) {
            emit Repriced(false, zeroForOne, 0, oraclePriceX18, preVammPriceX18, preVammPriceX18);
            return (false, zeroForOne, 0);
        }
        usedAmountIn = estimatedAmountIn > maxAmountInPerUpdate ? maxAmountInPerUpdate : estimatedAmountIn;

        swapRouter.swapExactTokensForTokens({
            amountIn: usedAmountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: vammPoolKey,
            hookData: abi.encode(targetSqrtPriceX96),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 postVammPriceX18 = getVammPriceX18();
        if (postVammPriceX18 < lowerBoundX18 || postVammPriceX18 > upperBoundX18) {
            revert MaxRepriceExceeded(postVammPriceX18, lowerBoundX18, upperBoundX18);
        }

        emit Repriced(true, zeroForOne, usedAmountIn, oraclePriceX18, preVammPriceX18, postVammPriceX18);
        return (true, zeroForOne, usedAmountIn);
    }

    function _getVammSqrtAndPriceX18() internal view returns (uint160 sqrtPriceX96, uint256 priceX18) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(vammPoolId);
        if (sqrtPriceX96 == 0) return (0, 0);
        uint256 priceX96 = PerpMath.formatSqrtPriceX96ToPriceX96(sqrtPriceX96);
        priceX18 = PerpMath.formatX96ToX10_18(priceX96);
    }

    function _calcSpreadBps(uint256 lhsPriceX18, uint256 rhsPriceX18) internal pure returns (uint256 spreadBps) {
        uint256 spread = lhsPriceX18 > rhsPriceX18 ? lhsPriceX18 - rhsPriceX18 : rhsPriceX18 - lhsPriceX18;
        spreadBps = (spread * BPS_BASE) / rhsPriceX18;
    }

    function _derivePriceBounds(uint256 currentPriceX18)
        internal
        view
        returns (uint256 lowerBoundX18, uint256 upperBoundX18)
    {
        uint256 bps = maxRepriceBpsPerUpdate;
        lowerBoundX18 = FullMath.mulDiv(currentPriceX18, BPS_BASE - bps, BPS_BASE);
        upperBoundX18 = FullMath.mulDiv(currentPriceX18, BPS_BASE + bps, BPS_BASE);
    }

    function _deriveSqrtLimitFromBounds(
        uint160 currentSqrtPriceX96,
        uint256 lowerBoundX18,
        uint256 upperBoundX18,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtPriceLimitX96) {
        sqrtPriceLimitX96 = zeroForOne ? _priceX18ToSqrtPriceX96(lowerBoundX18) : _priceX18ToSqrtPriceX96(upperBoundX18);

        if (zeroForOne) {
            if (sqrtPriceLimitX96 >= currentSqrtPriceX96) {
                sqrtPriceLimitX96 = currentSqrtPriceX96 > TickMath.MIN_SQRT_PRICE + 1
                    ? currentSqrtPriceX96 - 1
                    : TickMath.MIN_SQRT_PRICE + 1;
            }
            if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;
            }
        } else {
            if (sqrtPriceLimitX96 <= currentSqrtPriceX96) {
                sqrtPriceLimitX96 = currentSqrtPriceX96 < TickMath.MAX_SQRT_PRICE - 1
                    ? currentSqrtPriceX96 + 1
                    : TickMath.MAX_SQRT_PRICE - 1;
            }
            if (sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
            }
        }
    }

    function _priceX18ToSqrtPriceX96(uint256 priceX18) internal pure returns (uint160 sqrtPriceX96) {
        if (priceX18 == 0) return TickMath.MIN_SQRT_PRICE + 1;
        uint256 ratioX192 = FullMath.mulDiv(priceX18, Q192, 1e18);
        sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
    }

    function _estimateAmountInToTarget(
        uint128 liquidity,
        uint160 currentSqrtPriceX96,
        uint160 targetSqrtPriceX96,
        bool zeroForOne
    ) internal pure returns (uint256 amountIn) {
        if (currentSqrtPriceX96 == targetSqrtPriceX96 || liquidity == 0) return 0;

        if (zeroForOne) {
            if (targetSqrtPriceX96 >= currentSqrtPriceX96) return 0;
            uint256 sqrtDelta = uint256(currentSqrtPriceX96) - uint256(targetSqrtPriceX96);
            uint256 first = FullMath.mulDivRoundingUp(uint256(liquidity), sqrtDelta, uint256(targetSqrtPriceX96));
            amountIn = FullMath.mulDivRoundingUp(first, Q96, uint256(currentSqrtPriceX96));
        } else {
            if (targetSqrtPriceX96 <= currentSqrtPriceX96) return 0;
            uint256 sqrtDelta = uint256(targetSqrtPriceX96) - uint256(currentSqrtPriceX96);
            amountIn = FullMath.mulDivRoundingUp(uint256(liquidity), sqrtDelta, Q96);
        }
    }

    function _validateBps(uint24 value) internal pure {
        if (value > BPS_BASE) revert InvalidBps(value);
    }
}
