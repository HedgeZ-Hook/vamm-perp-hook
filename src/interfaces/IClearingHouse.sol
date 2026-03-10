// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IClearingHouse {
    struct OpenPositionParams {
        bool isBaseToQuote;
        uint256 amount;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    function openPosition(OpenPositionParams calldata params) external returns (int256 base, int256 quote);

    function closePosition(uint256 closeAmount, uint160 sqrtPriceLimitX96, bytes calldata hookData)
        external
        returns (int256 base, int256 quote);

    function liquidate(address trader) external returns (int256 liquidatedPositionSize, uint256 penalty);
}
