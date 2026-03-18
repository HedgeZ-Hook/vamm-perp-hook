// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IVammLiquidityController {
    function updateFromOracle() external returns (bool executed, bool zeroForOne, uint256 usedAmountIn);
}
