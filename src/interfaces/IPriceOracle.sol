// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPriceOracle {
    function getIndexPrice(uint32 interval) external view returns (uint256 priceX18);
}
