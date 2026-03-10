// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IFundingRate {
    function settleFunding(address trader, PoolId poolId)
        external
        returns (int256 fundingPayment, int256 latestTwPremiumGrowthGlobalX96);

    function getPendingFundingPayment(address trader, PoolId poolId) external view returns (int256 fundingPayment);

    function getTwPremiumGrowthGlobalX96(PoolId poolId) external view returns (int256 twPremiumGrowthGlobalX96);
}
