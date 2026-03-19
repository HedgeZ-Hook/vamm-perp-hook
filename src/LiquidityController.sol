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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {PerpMath} from "./libraries/PerpMath.sol";

contract LiquidityController is AccessControl {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error InvalidBps(uint24 value);
    error InvalidOracle(address oracle);
    error InvalidMaxAmountInPerUpdate(uint256 amount);
    error InvalidVammPair(address baseToken, address quoteToken);
    error VammLiquidityBelowFloor(uint128 currentLiquidity, uint128 minVammLiquidity);
    error MaxRepriceExceeded(uint256 postPriceX18, uint256 lowerBoundX18, uint256 upperBoundX18);

    uint256 internal constant BPS_BASE = 10_000;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q192 = 2 ** 192;
    uint256 internal constant PRICE_TOLERANCE_X18 = 2e7;

    IPoolManager public immutable poolManager;
    IUniswapV4Router04 public immutable swapRouter;

    IPriceOracle public priceOracle;
    PoolKey public vammPoolKey;
    PoolId public vammPoolId;
    bool public vammBaseIsCurrency0;
    address public vammBaseToken;
    address public vammQuoteToken;
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
        address vammBaseToken_,
        address vammQuoteToken_,
        uint32 twapInterval_,
        uint24 deadbandBps_,
        uint24 maxRepriceBpsPerUpdate_,
        uint256 maxAmountInPerUpdate_,
        uint128 minVammLiquidity_
    ) {
        if (address(priceOracle_) == address(0)) {
            revert InvalidOracle(address(priceOracle_));
        }
        if (maxAmountInPerUpdate_ == 0) revert InvalidMaxAmountInPerUpdate(maxAmountInPerUpdate_);

        _validateBps(deadbandBps_);
        _validateBps(maxRepriceBpsPerUpdate_);

        poolManager = poolManager_;
        swapRouter = swapRouter_;
        priceOracle = priceOracle_;
        address currency0 = Currency.unwrap(vammPoolKey_.currency0);
        address currency1 = Currency.unwrap(vammPoolKey_.currency1);
        bool validPair = (vammBaseToken_ == currency0 && vammQuoteToken_ == currency1)
            || (vammBaseToken_ == currency1 && vammQuoteToken_ == currency0);
        if (!validPair) revert InvalidVammPair(vammBaseToken_, vammQuoteToken_);
        vammPoolKey = vammPoolKey_;
        vammPoolId = vammPoolKey_.toId();
        vammBaseToken = vammBaseToken_;
        vammQuoteToken = vammQuoteToken_;
        vammBaseIsCurrency0 = vammBaseToken_ == currency0;
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
        priceX18 = priceOracle.latestOraclePriceE18();
    }

    function getVammPriceX18() public view returns (uint256 priceX18) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(vammPoolId);
        if (sqrtPriceX96 == 0) return 0;
        uint256 priceX96 = PerpMath.formatSqrtPriceX96ToPriceX96(sqrtPriceX96);
        uint256 rawPriceX18 = PerpMath.formatX96ToX10_18(priceX96);
        priceX18 = _rawPriceX18ToNormalizedPriceX18(rawPriceX18);
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

        (uint256 lowerBoundX18, uint256 upperBoundX18) = _derivePriceBounds(preVammPriceX18);
        uint256 targetPriceX18 = _clampPriceToBounds(oraclePriceX18, lowerBoundX18, upperBoundX18);
        zeroForOne = _isZeroForOne(preVammPriceX18, targetPriceX18);
        uint160 targetSqrtPriceX96 = _deriveSqrtLimitFromTarget(preSqrtPriceX96, targetPriceX18, zeroForOne);
        usedAmountIn = _resolveUsedAmountIn(currentLiquidity, preSqrtPriceX96, targetSqrtPriceX96, zeroForOne);
        if (usedAmountIn == 0) {
            emit Repriced(false, zeroForOne, 0, oraclePriceX18, preVammPriceX18, preVammPriceX18);
            return (false, zeroForOne, 0);
        }

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
        if (!_isWithinBounds(postVammPriceX18, lowerBoundX18, upperBoundX18)) {
            revert MaxRepriceExceeded(postVammPriceX18, lowerBoundX18, upperBoundX18);
        }

        emit Repriced(true, zeroForOne, usedAmountIn, oraclePriceX18, preVammPriceX18, postVammPriceX18);
        return (true, zeroForOne, usedAmountIn);
    }

    function _getVammSqrtAndPriceX18() internal view returns (uint160 sqrtPriceX96, uint256 priceX18) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(vammPoolId);
        if (sqrtPriceX96 == 0) return (0, 0);
        uint256 priceX96 = PerpMath.formatSqrtPriceX96ToPriceX96(sqrtPriceX96);
        uint256 rawPriceX18 = PerpMath.formatX96ToX10_18(priceX96);
        priceX18 = _rawPriceX18ToNormalizedPriceX18(rawPriceX18);
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

    function _clampPriceToBounds(uint256 targetPriceX18, uint256 lowerBoundX18, uint256 upperBoundX18)
        internal
        pure
        returns (uint256 clampedPriceX18)
    {
        if (targetPriceX18 < lowerBoundX18) return lowerBoundX18;
        if (targetPriceX18 > upperBoundX18) return upperBoundX18;
        return targetPriceX18;
    }

    function _deriveSqrtLimitFromTarget(uint160 currentSqrtPriceX96, uint256 targetNormalizedPriceX18, bool zeroForOne)
        internal
        view
        returns (uint160 sqrtPriceLimitX96)
    {
        sqrtPriceLimitX96 = _priceX18ToSqrtPriceX96(targetNormalizedPriceX18);

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

    function _resolveUsedAmountIn(
        uint128 currentLiquidity,
        uint160 preSqrtPriceX96,
        uint160 targetSqrtPriceX96,
        bool zeroForOne
    ) internal view returns (uint256 usedAmountIn) {
        uint256 estimatedAmountIn = _estimateAmountInToTarget(
            currentLiquidity, preSqrtPriceX96, targetSqrtPriceX96, zeroForOne
        );
        if (estimatedAmountIn == 0) return 0;

        uint256 availableAmountIn = _availableAmountIn(zeroForOne);
        usedAmountIn = Math.min(estimatedAmountIn, maxAmountInPerUpdate);
        usedAmountIn = Math.min(usedAmountIn, availableAmountIn);
    }

    function _availableAmountIn(bool zeroForOne) internal view returns (uint256) {
        address inputToken = Currency.unwrap(zeroForOne ? vammPoolKey.currency0 : vammPoolKey.currency1);
        return IERC20(inputToken).balanceOf(address(this));
    }

    function _priceX18ToSqrtPriceX96(uint256 priceX18) internal view returns (uint160 sqrtPriceX96) {
        if (priceX18 == 0) return TickMath.MIN_SQRT_PRICE + 1;
        uint256 rawPriceX18 = _normalizedPriceX18ToRawPriceX18(priceX18);
        uint256 ratioX192 = FullMath.mulDiv(rawPriceX18, Q192, 1e18);
        sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
    }

    function _rawPriceX18ToNormalizedPriceX18(uint256 rawPriceX18) internal view returns (uint256 priceX18) {
        if (rawPriceX18 == 0) return 0;
        if (vammBaseIsCurrency0) return rawPriceX18;
        priceX18 = FullMath.mulDiv(1e36, 1, rawPriceX18);
    }

    function _normalizedPriceX18ToRawPriceX18(uint256 priceX18) internal view returns (uint256 rawPriceX18) {
        if (vammBaseIsCurrency0) return priceX18;
        rawPriceX18 = FullMath.mulDiv(1e36, 1, priceX18);
    }

    function _isZeroForOne(uint256 currentNormalizedPriceX18, uint256 targetNormalizedPriceX18)
        internal
        view
        returns (bool zeroForOne)
    {
        uint256 currentRawPriceX18 = _normalizedPriceX18ToRawPriceX18(currentNormalizedPriceX18);
        uint256 targetRawPriceX18 = _normalizedPriceX18ToRawPriceX18(targetNormalizedPriceX18);
        zeroForOne = currentRawPriceX18 > targetRawPriceX18;
    }

    function _isWithinBounds(uint256 priceX18, uint256 lowerBoundX18, uint256 upperBoundX18)
        internal
        pure
        returns (bool)
    {
        bool belowLowerBound = priceX18 < lowerBoundX18 && lowerBoundX18 - priceX18 > PRICE_TOLERANCE_X18;
        bool aboveUpperBound = priceX18 > upperBoundX18 && priceX18 - upperBoundX18 > PRICE_TOLERANCE_X18;
        return !belowLowerBound && !aboveUpperBound;
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
