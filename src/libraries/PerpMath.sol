// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

library PerpMath {
    error DivisionByZero();
    error Int256Overflow();
    error Int128Overflow();
    error RatioUnderflow();

    function formatSqrtPriceX96ToPriceX96(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
    }

    function formatX10_18ToX96(uint256 valueX10_18) internal pure returns (uint256) {
        return FullMath.mulDiv(valueX10_18, FixedPoint96.Q96, 1 ether);
    }

    function formatX96ToX10_18(uint256 valueX96) internal pure returns (uint256) {
        return FullMath.mulDiv(valueX96, 1 ether, FixedPoint96.Q96);
    }

    function abs(int256 value) internal pure returns (uint256) {
        if (value >= 0) {
            return uint256(value);
        }
        unchecked {
            return uint256(-(value + 1)) + 1;
        }
    }

    function neg256(int256 value) internal pure returns (int256) {
        if (value == type(int256).min) revert Int256Overflow();
        return -value;
    }

    function neg256(uint256 value) internal pure returns (int256) {
        return -SafeCast.toInt256(value);
    }

    function neg128(int128 value) internal pure returns (int128) {
        if (value == type(int128).min) revert Int128Overflow();
        return -value;
    }

    function neg128(uint128 value) internal pure returns (int128) {
        if (value > uint128(type(int128).max)) revert Int128Overflow();
        return -int128(value);
    }

    function divBy10_18(int256 value) internal pure returns (int256) {
        return value / 1 ether;
    }

    function divBy10_18(uint256 value) internal pure returns (uint256) {
        return value / 1 ether;
    }

    function subRatio(uint24 a, uint24 b) internal pure returns (uint24) {
        if (b > a) revert RatioUnderflow();
        return a - b;
    }

    function mulDiv(int256 a, int256 b, uint256 denominator) internal pure returns (int256) {
        if (denominator == 0) revert DivisionByZero();
        if (a == 0 || b == 0) return 0;

        uint256 unsignedA = a < 0 ? uint256(neg256(a)) : uint256(a);
        uint256 unsignedB = b < 0 ? uint256(neg256(b)) : uint256(b);
        bool negative = (a < 0 && b > 0) || (a > 0 && b < 0);
        uint256 unsignedResult = FullMath.mulDiv(unsignedA, unsignedB, denominator);
        return negative ? neg256(unsignedResult) : SafeCast.toInt256(unsignedResult);
    }

    function mulRatio(uint256 value, uint24 ratio) internal pure returns (uint256) {
        return FullMath.mulDiv(value, ratio, 1e6);
    }

    function mulRatio(int256 value, uint24 ratio) internal pure returns (int256) {
        return mulDiv(value, int256(uint256(ratio)), 1e6);
    }

    function divRatio(uint256 value, uint24 ratio) internal pure returns (uint256) {
        return FullMath.mulDiv(value, 1e6, ratio);
    }

    function min(int256 a, int256 b) internal pure returns (int256) {
        return a <= b ? a : b;
    }

    function max(int256 a, int256 b) internal pure returns (int256) {
        return a >= b ? a : b;
    }

    function findMedianOfThree(uint256 v1, uint256 v2, uint256 v3) internal pure returns (uint256) {
        return Math.max(Math.min(v1, v2), Math.min(Math.max(v1, v2), v3));
    }
}
