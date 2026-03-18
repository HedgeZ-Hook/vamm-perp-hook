// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IVammVault {
    function isLiquidatable(address trader) external view returns (bool);
}
