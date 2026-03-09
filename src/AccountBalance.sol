// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {Config} from "./Config.sol";
import {PerpMath} from "./libraries/PerpMath.sol";
import {IAccountBalance} from "./interfaces/IAccountBalance.sol";

contract AccountBalance is Ownable, IAccountBalance {
    error Unauthorized(address caller);
    error Int256Overflow();

    Config public immutable config;
    address public clearingHouse;
    address public vault;

    mapping(address => mapping(PoolId => PositionInfo)) internal positions;
    mapping(address => int256) public owedRealizedPnl;
    mapping(PoolId => uint256) public markPriceX18;

    mapping(address => PoolId[]) internal activePoolIds;
    mapping(address => mapping(PoolId => uint256)) internal activePoolIndexPlusOne;

    constructor(Config config_) Ownable(msg.sender) {
        config = config_;
    }

    modifier onlyClearingHouse() {
        if (msg.sender != clearingHouse) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized(msg.sender);
        _;
    }

    function setClearingHouse(address clearingHouse_) external onlyOwner {
        clearingHouse = clearingHouse_;
    }

    function setVault(address vault_) external onlyOwner {
        vault = vault_;
    }

    function setMarkPriceX18(PoolId poolId, uint256 priceX18) external onlyOwner {
        markPriceX18[poolId] = priceX18;
    }

    function modifyTakerBalance(address trader, PoolId poolId, int256 base, int256 quote)
        external
        onlyClearingHouse
        returns (int256 takerPositionSize, int256 takerOpenNotional)
    {
        PositionInfo storage info = positions[trader][poolId];
        info.takerPositionSize += base;
        info.takerOpenNotional += quote;
        _syncActivePool(trader, poolId);
        return (info.takerPositionSize, info.takerOpenNotional);
    }

    function settleBalanceAndDeregister(address trader, PoolId poolId, int256 base, int256 quote, int256 realizedPnl)
        external
        onlyClearingHouse
    {
        PositionInfo storage info = positions[trader][poolId];
        info.takerPositionSize += base;
        info.takerOpenNotional += quote;
        owedRealizedPnl[trader] += realizedPnl;
        _syncActivePool(trader, poolId);
    }

    function modifyOwedRealizedPnl(address trader, int256 amount) external onlyClearingHouse {
        owedRealizedPnl[trader] += amount;
    }

    function settleOwedRealizedPnl(address trader) external onlyVault returns (int256 pnl) {
        pnl = owedRealizedPnl[trader];
        owedRealizedPnl[trader] = 0;
    }

    function updateLastTwPremiumGrowthGlobal(address trader, PoolId poolId, int256 lastTwPremiumGrowthGlobalX96)
        external
        onlyClearingHouse
    {
        positions[trader][poolId].lastTwPremiumGrowthGlobalX96 = lastTwPremiumGrowthGlobalX96;
    }

    function getTakerPositionSize(address trader, PoolId poolId) external view returns (int256 takerPositionSize) {
        return positions[trader][poolId].takerPositionSize;
    }

    function getTakerOpenNotional(address trader, PoolId poolId) external view returns (int256 takerOpenNotional) {
        return positions[trader][poolId].takerOpenNotional;
    }

    function getLastTwPremiumGrowthGlobalX96(address trader, PoolId poolId) external view returns (int256 value) {
        return positions[trader][poolId].lastTwPremiumGrowthGlobalX96;
    }

    function getPositionInfo(address trader, PoolId poolId) external view returns (PositionInfo memory info) {
        return positions[trader][poolId];
    }

    function getActivePoolIds(address trader) external view returns (PoolId[] memory poolIds) {
        return activePoolIds[trader];
    }

    function getTotalAbsPositionValue(address trader) public view returns (uint256 totalAbsPositionValue) {
        PoolId[] storage pools = activePoolIds[trader];
        uint256 len = pools.length;
        for (uint256 i = 0; i < len; i++) {
            PoolId poolId = pools[i];
            int256 size = positions[trader][poolId].takerPositionSize;
            if (size == 0) continue;
            uint256 price = markPriceX18[poolId];
            if (price == 0) continue;
            totalAbsPositionValue += Math.mulDiv(PerpMath.abs(size), price, 1e18);
        }
    }

    function getMarginRequirementForLiquidation(address trader)
        external
        view
        returns (int256 marginRequirementForLiquidation)
    {
        uint256 requirement = PerpMath.mulRatio(getTotalAbsPositionValue(trader), config.mmRatio());
        if (requirement > uint256(type(int256).max)) revert Int256Overflow();
        return int256(requirement);
    }

    function _syncActivePool(address trader, PoolId poolId) internal {
        PositionInfo storage info = positions[trader][poolId];
        bool isActive = info.takerPositionSize != 0 || info.takerOpenNotional != 0;
        uint256 indexPlusOne = activePoolIndexPlusOne[trader][poolId];

        if (isActive && indexPlusOne == 0) {
            activePoolIds[trader].push(poolId);
            activePoolIndexPlusOne[trader][poolId] = activePoolIds[trader].length;
            return;
        }

        if (!isActive && indexPlusOne != 0) {
            PoolId[] storage pools = activePoolIds[trader];
            uint256 removeIndex = indexPlusOne - 1;
            uint256 lastIndex = pools.length - 1;

            if (removeIndex != lastIndex) {
                PoolId moved = pools[lastIndex];
                pools[removeIndex] = moved;
                activePoolIndexPlusOne[trader][moved] = indexPlusOne;
            }

            pools.pop();
            activePoolIndexPlusOne[trader][poolId] = 0;
        }
    }
}
