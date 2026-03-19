// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

contract ManualPriceOracle is Ownable, IPriceOracle {
    uint256 public latestOraclePriceE18;

    event PriceUpdated(uint256 previousPriceX18, uint256 newPriceX18);

    constructor(uint256 initialPriceX18) Ownable(msg.sender) {
        latestOraclePriceE18 = initialPriceX18;
    }

    function setPriceX18(uint256 newPriceX18) external onlyOwner {
        uint256 previousPriceX18 = latestOraclePriceE18;
        latestOraclePriceE18 = newPriceX18;
        emit PriceUpdated(previousPriceX18, newPriceX18);
    }
}
