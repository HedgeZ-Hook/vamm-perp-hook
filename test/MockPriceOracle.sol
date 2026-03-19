// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

contract MockPriceOracle is Ownable, IPriceOracle {
    uint256 public latestOraclePriceE18;

    constructor(uint256 initialPriceX18) Ownable(msg.sender) {
        latestOraclePriceE18 = initialPriceX18;
    }

    function setPriceX18(uint256 newPriceX18) external onlyOwner {
        latestOraclePriceE18 = newPriceX18;
    }
}
