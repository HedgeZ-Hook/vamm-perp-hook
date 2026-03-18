// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILiquidationTracker {
    function updateTrader(address trader, uint256 liquidationPrice, bool isLiquidated) external;
}
