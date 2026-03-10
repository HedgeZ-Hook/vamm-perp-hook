// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {Config} from "./Config.sol";
import {PerpMath} from "./libraries/PerpMath.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IAccountBalance} from "./interfaces/IAccountBalance.sol";
import {IFundingRate} from "./interfaces/IFundingRate.sol";

contract FundingRate is Ownable, IFundingRate {
    using StateLibrary for IPoolManager;

    error Unauthorized(address caller);

    IPoolManager public immutable poolManager;
    IPriceOracle public immutable priceOracle;
    IAccountBalance public immutable accountBalance;
    Config public immutable config;

    address public clearingHouse;

    mapping(PoolId => int256) public twPremiumGrowthGlobalX96;
    mapping(PoolId => uint256) public lastSettledTimestamp;

    modifier onlyClearingHouse() {
        if (msg.sender != clearingHouse) revert Unauthorized(msg.sender);
        _;
    }

    constructor(IPoolManager poolManager_, IPriceOracle priceOracle_, IAccountBalance accountBalance_, Config config_)
        Ownable(msg.sender)
    {
        poolManager = poolManager_;
        priceOracle = priceOracle_;
        accountBalance = accountBalance_;
        config = config_;
    }

    function setClearingHouse(address clearingHouse_) external onlyOwner {
        clearingHouse = clearingHouse_;
    }

    function settleFunding(address trader, PoolId poolId)
        external
        onlyClearingHouse
        returns (int256 fundingPayment, int256 latestTwPremiumGrowthGlobalX96)
    {
        latestTwPremiumGrowthGlobalX96 = _settleGlobal(poolId);
        fundingPayment = _getFundingPayment(trader, poolId, latestTwPremiumGrowthGlobalX96);
    }

    function getPendingFundingPayment(address trader, PoolId poolId) external view returns (int256 fundingPayment) {
        int256 latestTwPremiumGrowthGlobalX96 = _getLatestGrowthGlobal(poolId);
        return _getFundingPayment(trader, poolId, latestTwPremiumGrowthGlobalX96);
    }

    function getTwPremiumGrowthGlobalX96(PoolId poolId) external view returns (int256) {
        return twPremiumGrowthGlobalX96[poolId];
    }

    function _settleGlobal(PoolId poolId) internal returns (int256 latestTwPremiumGrowthGlobalX96) {
        latestTwPremiumGrowthGlobalX96 = twPremiumGrowthGlobalX96[poolId];
        uint256 lastTimestamp = lastSettledTimestamp[poolId];
        if (lastTimestamp == 0) {
            lastSettledTimestamp[poolId] = block.timestamp;
            return latestTwPremiumGrowthGlobalX96;
        }

        uint256 elapsed = block.timestamp - lastTimestamp;
        if (elapsed == 0) return latestTwPremiumGrowthGlobalX96;

        int256 deltaGrowthX96 = _calculateDeltaGrowth(poolId, elapsed);
        latestTwPremiumGrowthGlobalX96 += deltaGrowthX96;
        twPremiumGrowthGlobalX96[poolId] = latestTwPremiumGrowthGlobalX96;
        lastSettledTimestamp[poolId] = block.timestamp;
    }

    function _getLatestGrowthGlobal(PoolId poolId) internal view returns (int256 latestTwPremiumGrowthGlobalX96) {
        latestTwPremiumGrowthGlobalX96 = twPremiumGrowthGlobalX96[poolId];
        uint256 lastTimestamp = lastSettledTimestamp[poolId];
        if (lastTimestamp == 0 || block.timestamp == lastTimestamp) {
            return latestTwPremiumGrowthGlobalX96;
        }

        uint256 elapsed = block.timestamp - lastTimestamp;
        int256 deltaGrowthX96 = _calculateDeltaGrowth(poolId, elapsed);
        return latestTwPremiumGrowthGlobalX96 + deltaGrowthX96;
    }

    function _calculateDeltaGrowth(PoolId poolId, uint256 elapsed) internal view returns (int256 deltaGrowthX96) {
        uint256 indexPriceX18 = priceOracle.getIndexPrice(config.twapInterval());
        if (indexPriceX18 == 0) return 0;

        uint256 markPriceX18 = _getMarkPriceX18(poolId);
        int256 premiumRateX18 =
            PerpMath.mulDiv(int256(markPriceX18) - int256(indexPriceX18), int256(1e18), indexPriceX18);
        int256 cappedPremiumRateX18 = _capFundingRate(premiumRateX18);

        int256 timeWeightedPremiumX18 = PerpMath.mulDiv(cappedPremiumRateX18, int256(elapsed), 1 days);
        return PerpMath.mulDiv(timeWeightedPremiumX18, int256(uint256(FixedPoint96.Q96)), 1e18);
    }

    function _capFundingRate(int256 premiumRateX18) internal view returns (int256) {
        int256 maxRateX18 = int256(uint256(config.maxFundingRate()) * 1e12);
        if (premiumRateX18 > maxRateX18) return maxRateX18;
        if (premiumRateX18 < -maxRateX18) return -maxRateX18;
        return premiumRateX18;
    }

    function _getFundingPayment(address trader, PoolId poolId, int256 latestTwPremiumGrowthGlobalX96)
        internal
        view
        returns (int256 fundingPayment)
    {
        IAccountBalance.PositionInfo memory info = accountBalance.getPositionInfo(trader, poolId);
        int256 positionSize = info.takerPositionSize;
        if (positionSize == 0) return 0;

        int256 deltaGrowthX96 = latestTwPremiumGrowthGlobalX96 - info.lastTwPremiumGrowthGlobalX96;
        if (deltaGrowthX96 == 0) return 0;

        uint256 indexPriceX18 = priceOracle.getIndexPrice(config.twapInterval());
        int256 positionNotionalX18 = PerpMath.mulDiv(positionSize, int256(indexPriceX18), 1e18);
        return PerpMath.mulDiv(positionNotionalX18, deltaGrowthX96, uint256(FixedPoint96.Q96));
    }

    function _getMarkPriceX18(PoolId poolId) internal view returns (uint256 markPriceX18) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 priceX96 = PerpMath.formatSqrtPriceX96ToPriceX96(sqrtPriceX96);
        return PerpMath.formatX96ToX10_18(priceX96);
    }
}
