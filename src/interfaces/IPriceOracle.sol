// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPriceOracle {
    function latestOraclePriceE18() external view returns (uint256 priceX18);
}
