// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IVammOracle {
    function updateOraclePrice(uint256 priceE18) external;
}
