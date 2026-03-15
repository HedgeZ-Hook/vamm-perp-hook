// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

contract ManualPriceOracle is Ownable, IPriceOracle {
    uint256 public priceX18;

    event PriceUpdated(uint256 previousPriceX18, uint256 newPriceX18);

    constructor(uint256 initialPriceX18) Ownable(msg.sender) {
        priceX18 = initialPriceX18;
    }

    function setPriceX18(uint256 newPriceX18) external onlyOwner {
        uint256 previousPriceX18 = priceX18;
        priceX18 = newPriceX18;
        emit PriceUpdated(previousPriceX18, newPriceX18);
    }

    function getIndexPrice(uint32) external view returns (uint256) {
        return priceX18;
    }
}
