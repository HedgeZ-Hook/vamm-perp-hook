// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Config is Ownable {
    uint24 public imRatio;
    uint24 public mmRatio;
    uint24 public liquidationPenaltyRatio;
    uint24 public maxFundingRate;
    uint32 public twapInterval;
    uint24 public insuranceFundFeeRatio;

    constructor() Ownable(msg.sender) {
        imRatio = 100_000;
        mmRatio = 62_500;
        liquidationPenaltyRatio = 25_000;
        maxFundingRate = 100_000;
        twapInterval = 900;
        insuranceFundFeeRatio = 0;
    }

    function setImRatio(uint24 value) external onlyOwner {
        imRatio = value;
    }

    function setMmRatio(uint24 value) external onlyOwner {
        mmRatio = value;
    }

    function setLiquidationPenaltyRatio(uint24 value) external onlyOwner {
        liquidationPenaltyRatio = value;
    }

    function setMaxFundingRate(uint24 value) external onlyOwner {
        maxFundingRate = value;
    }

    function setTwapInterval(uint32 value) external onlyOwner {
        twapInterval = value;
    }

    function setInsuranceFundFeeRatio(uint24 value) external onlyOwner {
        insuranceFundFeeRatio = value;
    }
}
