// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IAccountBalance {
    struct PositionInfo {
        int256 takerPositionSize;
        int256 takerOpenNotional;
        int256 lastTwPremiumGrowthGlobalX96;
    }

    function modifyTakerBalance(address trader, PoolId poolId, int256 base, int256 quote)
        external
        returns (int256 takerPositionSize, int256 takerOpenNotional);

    function settleBalanceAndDeregister(address trader, PoolId poolId, int256 base, int256 quote, int256 realizedPnl)
        external;

    function modifyOwedRealizedPnl(address trader, int256 amount) external;

    function updateMarkPriceX18(PoolId poolId, uint256 priceX18) external;

    function settleOwedRealizedPnl(address trader) external returns (int256 pnl);

    function updateLastTwPremiumGrowthGlobal(address trader, PoolId poolId, int256 lastTwPremiumGrowthGlobalX96)
        external;

    function getTakerPositionSize(address trader, PoolId poolId) external view returns (int256 takerPositionSize);

    function getTakerOpenNotional(address trader, PoolId poolId) external view returns (int256 takerOpenNotional);

    function getLastTwPremiumGrowthGlobalX96(address trader, PoolId poolId) external view returns (int256 value);

    function getPositionInfo(address trader, PoolId poolId) external view returns (PositionInfo memory info);

    function getActivePoolIds(address trader) external view returns (PoolId[] memory poolIds);

    function getOwedRealizedPnl(address trader) external view returns (int256 pnl);

    function getMarkPriceX18(PoolId poolId) external view returns (uint256 priceX18);

    function getTotalAbsPositionValue(address trader) external view returns (uint256 totalAbsPositionValue);

    function getMarginRequirementForLiquidation(address trader)
        external
        view
        returns (int256 marginRequirementForLiquidation);

    function getLiquidatablePositionSize(address trader, PoolId poolId, int256 accountValue)
        external
        view
        returns (int256 liquidatablePositionSize);
}
