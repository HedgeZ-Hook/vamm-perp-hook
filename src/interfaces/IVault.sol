// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IVault {
    function deposit(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function depositLP(uint256 tokenId) external;

    function withdrawLP(uint256 tokenId) external returns (uint256 ethAmount, uint256 usdcAmount);

    function decreaseLP(uint256 tokenId, uint128 liquidityToRemove)
        external
        returns (uint256 ethAmount, uint256 usdcAmount);

    function forceLiquidateLP(address trader, uint256 usdcNeeded) external returns (uint256 usdcRecovered);

    function getAccountValue(address trader) external view returns (int256 accountValue);

    function getFreeCollateral(address trader) external view returns (int256 freeCollateral);

    function getFreeCollateralByRatio(address trader, uint24 ratio) external view returns (int256 freeCollateral);

    function getLPCollateralValue(address trader) external view returns (uint256 collateralValue);

    function getNetCashBalance(address trader) external view returns (int256 netCashBalance);

    function hasLPCollateral(address trader) external view returns (bool);

    function getUserLPTokenIds(address trader) external view returns (uint256[] memory tokenIds);

    function getMarkPriceX18() external view returns (uint256 priceX18);

    function moveBalance(address from, address to, uint256 amount) external;

    function isLiquidatable(address trader) external view returns (bool);

    function insuranceFund() external view returns (address);

    function settleBadDebt(address trader) external;
}
