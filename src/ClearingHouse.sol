// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Config} from "./Config.sol";
import {PerpMath} from "./libraries/PerpMath.sol";
import {IAccountBalance} from "./interfaces/IAccountBalance.sol";
import {IClearingHouse} from "./interfaces/IClearingHouse.sol";
import {ILiquidationTracker} from "./interfaces/ILiquidationTracker.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IFundingRate} from "./interfaces/IFundingRate.sol";

contract ClearingHouse is Ownable, IUnlockCallback, IClearingHouse {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;

    error NotPoolManager(address caller);
    error InvalidCloseAmount(uint256 closeAmount, uint256 maxCloseAmount);
    error NoOpenPosition();
    error InvalidCloseDirection(int256 positionSize, int256 baseDelta);
    error ZeroAmount();
    error InsufficientMargin(int256 freeCollateral);
    error VaultNotSet();
    error NotVault(address caller);
    error NotLiquidatable(address trader);
    error NoLiquidatablePosition(address trader);

    enum Action {
        Open,
        Close
    }

    struct CallbackData {
        Action action;
        bool isBaseToQuote;
        uint256 amount;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct LiquidationResult {
        int256 liquidatedPositionSize;
        int256 realizedPnl;
        uint256 liquidatedNotional;
    }

    IPoolManager public immutable poolManager;
    IAccountBalance public immutable accountBalance;
    Config public immutable config;
    IVault public vault;
    IFundingRate public fundingRate;
    ILiquidationTracker public liquidationTracker;

    PoolKey public vammPoolKey;
    PoolId public vammPoolId;
    Currency public baseCurrency;
    Currency public quoteCurrency;

    event PositionOpened(address indexed trader, int256 base, int256 quote);
    event PositionClosed(address indexed trader, int256 base, int256 quote, int256 realizedPnl);
    event PositionLiquidated(
        address indexed trader,
        address indexed liquidator,
        int256 liquidatedPositionSize,
        int256 realizedPnl,
        uint256 penalty,
        bool isFullyLiquidated,
        int256 remainingPositionSize
    );

    constructor(
        IPoolManager poolManager_,
        IAccountBalance accountBalance_,
        Config config_,
        PoolKey memory vammPoolKey_,
        Currency baseCurrency_,
        Currency quoteCurrency_
    ) Ownable(msg.sender) {
        poolManager = poolManager_;
        accountBalance = accountBalance_;
        config = config_;
        vammPoolKey = vammPoolKey_;
        vammPoolId = vammPoolKey_.toId();
        baseCurrency = baseCurrency_;
        quoteCurrency = quoteCurrency_;
    }

    function openPosition(OpenPositionParams calldata params) external returns (int256 base, int256 quote) {
        if (params.amount == 0) revert ZeroAmount();
        _settleFunding(msg.sender);
        (base, quote) =
            _executeSwap(Action.Open, params.isBaseToQuote, params.amount, params.sqrtPriceLimitX96, params.hookData);
        accountBalance.modifyTakerBalance(msg.sender, vammPoolId, base, quote);
        _chargeTradeFee(msg.sender, quote);
        _enforceMargin(msg.sender, config.imRatio());
        _notifyLiquidationPriceChange(msg.sender, false);
        emit PositionOpened(msg.sender, base, quote);
    }

    function closePosition(uint256 closeAmount, uint160 sqrtPriceLimitX96, bytes calldata hookData)
        external
        returns (int256 base, int256 quote)
    {
        _settleFunding(msg.sender);
        int256 positionSize = accountBalance.getTakerPositionSize(msg.sender, vammPoolId);
        int256 openNotional = accountBalance.getTakerOpenNotional(msg.sender, vammPoolId);
        uint256 absPositionSize = PerpMath.abs(positionSize);

        if (absPositionSize == 0) revert NoOpenPosition();

        uint256 closeBaseAbs = closeAmount == 0 ? absPositionSize : closeAmount;
        if (closeBaseAbs > absPositionSize) revert InvalidCloseAmount(closeBaseAbs, absPositionSize);

        bool isBaseToQuote = positionSize > 0;
        (base, quote) = _executeSwap(Action.Close, isBaseToQuote, closeBaseAbs, sqrtPriceLimitX96, hookData);

        if (positionSize > 0 && base >= 0) revert InvalidCloseDirection(positionSize, base);
        if (positionSize < 0 && base <= 0) revert InvalidCloseDirection(positionSize, base);

        uint256 closeRatioX18 = (PerpMath.abs(base) * 1e18) / absPositionSize;
        int256 closedOpenNotional = PerpMath.mulDiv(openNotional, int256(closeRatioX18), 1e18);
        int256 quoteForOpenNotional = -closedOpenNotional;
        int256 realizedPnl = quote + closedOpenNotional;

        accountBalance.settleBalanceAndDeregister(msg.sender, vammPoolId, base, quoteForOpenNotional, realizedPnl);
        _chargeTradeFee(msg.sender, quote);
        _enforceMargin(msg.sender, config.mmRatio());
        _notifyLiquidationPriceChange(msg.sender, false);
        emit PositionClosed(msg.sender, base, quote, realizedPnl);
    }

    function setVault(IVault vault_) external onlyOwner {
        vault = vault_;
    }

    function setFundingRate(IFundingRate fundingRate_) external onlyOwner {
        fundingRate = fundingRate_;
    }

    function setLiquidationTracker(ILiquidationTracker liquidationTracker_) external onlyOwner {
        liquidationTracker = liquidationTracker_;
    }

    function syncTraderLiquidationPrice(address trader, uint256 liquidationPriceX18, bool wasLiquidated) external {
        if (msg.sender != address(vault)) revert NotVault(msg.sender);
        if (address(liquidationTracker) == address(0)) return;
        liquidationTracker.updateTrader(trader, liquidationPriceX18, wasLiquidated);
    }

    function liquidate(address trader)
        external
        returns (bool isFullyLiquidated, uint256 liquidatedPositionSize, uint256 penalty)
    {
        if (address(vault) == address(0)) revert VaultNotSet();
        if (!vault.isLiquidatable(trader)) revert NotLiquidatable(trader);

        _settleFunding(trader);
        int256 positionSizeBefore = accountBalance.getTakerPositionSize(trader, vammPoolId);
        if (positionSizeBefore == 0) {
            int256 debtToSettle = vault.getNetCashBalance(trader);
            if (debtToSettle < 0 && vault.hasLPCollateral(trader)) {
                vault.forceLiquidateLP(trader, uint256(-debtToSettle));
                debtToSettle = vault.getNetCashBalance(trader);
            }
            if (debtToSettle < 0) {
                vault.settleBadDebt(trader);
            }

            _notifyLiquidationPriceChange(trader, true);
            emit PositionLiquidated(trader, msg.sender, 0, 0, 0, true, 0);
            return (true, 0, 0);
        }

        uint256 markPriceX18 = vault.getMarkPriceX18();
        accountBalance.updateMarkPriceX18(vammPoolId, markPriceX18);
        int256 accountValue = vault.getAccountValue(trader);
        LiquidationResult memory result = _liquidateAtMark(trader, accountValue, markPriceX18);
        int256 liquidatedPositionSizeSigned = result.liquidatedPositionSize;
        liquidatedPositionSize = PerpMath.abs(liquidatedPositionSizeSigned);

        penalty = PerpMath.mulRatio(result.liquidatedNotional, config.liquidationPenaltyRatio());
        if (penalty > 0) {
            accountBalance.modifyOwedRealizedPnl(trader, -int256(penalty));
        }

        int256 debtAmount = vault.getNetCashBalance(trader);
        if (debtAmount < 0 && vault.hasLPCollateral(trader)) {
            vault.forceLiquidateLP(trader, uint256(-debtAmount));
        }

        _distributePenalty(trader, msg.sender, penalty);

        if (vault.getNetCashBalance(trader) < 0) {
            vault.settleBadDebt(trader);
        }

        int256 remainingPositionSize = accountBalance.getTakerPositionSize(trader, vammPoolId);
        isFullyLiquidated = remainingPositionSize == 0;

        _notifyLiquidationPriceChange(trader, true);
        emit PositionLiquidated(
            trader,
            msg.sender,
            liquidatedPositionSizeSigned,
            result.realizedPnl,
            penalty,
            isFullyLiquidated,
            remainingPositionSize
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        SwapParams memory swapParams = _buildSwapParams(data.isBaseToQuote, data.amount, data.sqrtPriceLimitX96);
        BalanceDelta delta = poolManager.swap(vammPoolKey, swapParams, data.hookData);

        int256 delta0 = int256(delta.amount0());
        int256 delta1 = int256(delta.amount1());

        if (delta0 < 0) {
            vammPoolKey.currency0.settle(poolManager, address(this), uint256(-delta0), false);
        } else if (delta0 > 0) {
            vammPoolKey.currency0.take(poolManager, address(this), uint256(delta0), false);
        }

        if (delta1 < 0) {
            vammPoolKey.currency1.settle(poolManager, address(this), uint256(-delta1), false);
        } else if (delta1 > 0) {
            vammPoolKey.currency1.take(poolManager, address(this), uint256(delta1), false);
        }

        int256 base = baseCurrency == vammPoolKey.currency0 ? delta0 : delta1;
        int256 quote = quoteCurrency == vammPoolKey.currency0 ? delta0 : delta1;
        return abi.encode(base, quote, data.action);
    }

    function _executeSwap(
        Action action,
        bool isBaseToQuote,
        uint256 amount,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) internal returns (int256 base, int256 quote) {
        bytes memory result = poolManager.unlock(
            abi.encode(
                CallbackData({
                    action: action,
                    isBaseToQuote: isBaseToQuote,
                    amount: amount,
                    sqrtPriceLimitX96: sqrtPriceLimitX96,
                    hookData: hookData
                })
            )
        );
        (base, quote,) = abi.decode(result, (int256, int256, Action));
    }

    function _buildSwapParams(bool isBaseToQuote, uint256 amount, uint160 sqrtPriceLimitX96)
        internal
        view
        returns (SwapParams memory params)
    {
        bool baseIsCurrency0 = baseCurrency == vammPoolKey.currency0;
        bool zeroForOne = baseIsCurrency0 ? isBaseToQuote : !isBaseToQuote;

        int256 amountSpecified = isBaseToQuote ? -int256(amount) : int256(amount);
        uint160 limit = sqrtPriceLimitX96;
        if (limit == 0) {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        params = SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit});
    }

    function _enforceMargin(address trader, uint24 ratio) internal view {
        if (address(vault) == address(0)) return;
        int256 freeCollateral = vault.getFreeCollateralByRatio(trader, ratio);
        if (freeCollateral < 0) revert InsufficientMargin(freeCollateral);
    }

    function _distributePenalty(address trader, address liquidator, uint256 penalty) internal {
        if (penalty == 0) return;

        int256 netCashBalance = vault.getNetCashBalance(trader);
        if (netCashBalance <= 0) return;

        uint256 available = uint256(netCashBalance);
        uint256 paidPenalty = available < penalty ? available : penalty;
        if (paidPenalty == 0) return;

        uint256 liquidatorShare = paidPenalty / 2;
        uint256 insuranceFundShare = paidPenalty - liquidatorShare;

        if (liquidatorShare > 0) {
            vault.moveBalance(trader, liquidator, liquidatorShare);
        }

        if (insuranceFundShare > 0 && vault.insuranceFund() != address(0)) {
            vault.moveBalance(trader, vault.insuranceFund(), insuranceFundShare);
        }
    }

    function _liquidateAtMark(address trader, int256 accountValue, uint256 markPriceX18)
        internal
        returns (LiquidationResult memory result)
    {
        int256 positionSize = accountBalance.getTakerPositionSize(trader, vammPoolId);
        int256 maxLiquidatable = accountBalance.getLiquidatablePositionSize(trader, vammPoolId, accountValue);
        if (maxLiquidatable == 0) revert NoLiquidatablePosition(trader);

        uint256 absPositionSize = PerpMath.abs(positionSize);
        uint256 absLiquidateSize = PerpMath.abs(maxLiquidatable);
        if (absLiquidateSize > absPositionSize) {
            maxLiquidatable = positionSize;
            absLiquidateSize = absPositionSize;
        }

        int256 openNotional = accountBalance.getTakerOpenNotional(trader, vammPoolId);
        uint256 closeRatioX18 = Math.mulDiv(absLiquidateSize, 1e18, absPositionSize);
        int256 closedOpenNotional = PerpMath.mulDiv(openNotional, int256(closeRatioX18), 1e18);
        int256 realizedPnl = PerpMath.mulDiv(maxLiquidatable, int256(markPriceX18), 1e18) + closedOpenNotional;
        accountBalance.settleBalanceAndDeregister(
            trader, vammPoolId, -maxLiquidatable, -closedOpenNotional, realizedPnl
        );

        result = LiquidationResult({
            liquidatedPositionSize: maxLiquidatable,
            realizedPnl: realizedPnl,
            liquidatedNotional: Math.mulDiv(absLiquidateSize, markPriceX18, 1e18)
        });
    }

    function _settleFunding(address trader) internal {
        if (address(fundingRate) == address(0)) return;
        (int256 fundingPayment, int256 latestTwPremiumGrowthGlobalX96) = fundingRate.settleFunding(trader, vammPoolId);
        accountBalance.updateLastTwPremiumGrowthGlobal(trader, vammPoolId, latestTwPremiumGrowthGlobalX96);
        if (fundingPayment != 0) {
            accountBalance.modifyOwedRealizedPnl(trader, -fundingPayment);
        }
    }

    function _chargeTradeFee(address trader, int256 quote) internal {
        if (address(vault) == address(0)) return;
        address insuranceFund = vault.insuranceFund();
        if (insuranceFund == address(0)) return;

        uint24 feeRatio = config.insuranceFundFeeRatio();
        if (feeRatio == 0) return;

        uint256 feeAmount = PerpMath.mulRatio(PerpMath.abs(quote), feeRatio);
        if (feeAmount == 0) return;

        accountBalance.modifyOwedRealizedPnl(trader, -int256(feeAmount));
        accountBalance.modifyOwedRealizedPnl(insuranceFund, int256(feeAmount));
    }

    function _notifyLiquidationPriceChange(address trader, bool wasLiquidated) internal {
        if (address(vault) == address(0)) return;
        vault.notifyLiquidationPriceChange(trader, wasLiquidated);
    }
}
