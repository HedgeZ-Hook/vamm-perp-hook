// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {Config} from "./Config.sol";
import {PerpMath} from "./libraries/PerpMath.sol";
import {LPValuation} from "./libraries/LPValuation.sol";
import {IAccountBalance} from "./interfaces/IAccountBalance.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IFundingRate} from "./interfaces/IFundingRate.sol";

contract Vault is Ownable, IVault {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    error InsufficientFreeCollateral(int256 freeCollateral, uint256 requestedAmount);
    error Unauthorized(address caller);
    error InvalidSpotPool(PoolId poolId);
    error InvalidLiquidity(uint128 liquidity);
    error NotLPTokenOwner(address caller, uint256 tokenId);
    error NativeTransferFailed(address to, uint256 amount);
    error InsufficientInternalBalance(address trader, int256 balance, uint256 requestedAmount);
    error InvalidForcedSwapSlippageRatio(uint24 ratio);

    struct LPCollateral {
        uint256 tokenId;
        address owner;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    IAccountBalance public immutable accountBalance;
    Config public immutable config;
    IERC20 public immutable usdc;
    IPriceOracle public immutable priceOracle;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IUniswapV4Router04 public immutable swapRouter;
    IFundingRate public fundingRate;

    PoolKey public spotPoolKey;
    PoolId public spotPoolId;
    bool public immutable spotEthIsCurrency0;

    address public clearingHouse;
    address public insuranceFund;

    uint24 public lpRemoveBufferRatio = 20_000;
    uint24 public forcedSwapSlippageRatio = 50_000;

    mapping(address => int256) public usdcBalance;
    mapping(uint256 => LPCollateral) public lpCollaterals;
    mapping(address => uint256[]) internal userLPTokenIds;
    mapping(uint256 => uint256) internal lpTokenIndexPlusOne;

    event LPDeposited(address indexed trader, uint256 indexed tokenId, uint128 liquidity);
    event LPWithdrawn(address indexed trader, uint256 indexed tokenId, uint128 liquidityRemoved);
    event LPDecreased(address indexed trader, uint256 indexed tokenId, uint128 liquidityRemoved, uint128 liquidityLeft);
    event LPForceLiquidated(
        address indexed trader, uint256 indexed tokenId, uint128 liquidityRemoved, uint256 usdcRecovered
    );
    event Deposited(address indexed trader, uint256 amount);
    event Withdrawn(address indexed trader, uint256 amount);
    event LiquidationPriceChange(address indexed trader, uint256 liquidationPriceX18);

    modifier onlyClearingHouse() {
        if (msg.sender != clearingHouse) revert Unauthorized(msg.sender);
        _;
    }

    constructor(
        IAccountBalance accountBalance_,
        Config config_,
        IERC20 usdc_,
        IPriceOracle priceOracle_,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IUniswapV4Router04 swapRouter_,
        PoolKey memory spotPoolKey_
    ) Ownable(msg.sender) {
        accountBalance = accountBalance_;
        config = config_;
        usdc = usdc_;
        priceOracle = priceOracle_;
        poolManager = poolManager_;
        positionManager = positionManager_;
        swapRouter = swapRouter_;
        spotPoolKey = spotPoolKey_;
        spotPoolId = spotPoolKey_.toId();
        spotEthIsCurrency0 = spotPoolKey_.currency0.isAddressZero();
        insuranceFund = msg.sender;
    }

    receive() external payable {}

    function setClearingHouse(address clearingHouse_) external onlyOwner {
        clearingHouse = clearingHouse_;
    }

    function setInsuranceFund(address insuranceFund_) external onlyOwner {
        insuranceFund = insuranceFund_;
    }

    function setLpRemoveBufferRatio(uint24 lpRemoveBufferRatio_) external onlyOwner {
        lpRemoveBufferRatio = lpRemoveBufferRatio_;
    }

    function setForcedSwapSlippageRatio(uint24 forcedSwapSlippageRatio_) external onlyOwner {
        if (forcedSwapSlippageRatio_ > 1e6) revert InvalidForcedSwapSlippageRatio(forcedSwapSlippageRatio_);
        forcedSwapSlippageRatio = forcedSwapSlippageRatio_;
    }

    function setFundingRate(IFundingRate fundingRate_) external onlyOwner {
        fundingRate = fundingRate_;
    }

    function deposit(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        usdcBalance[msg.sender] += int256(amount);
        emit Deposited(msg.sender, amount);
        _emitLiquidationPriceChange(msg.sender);
    }

    function withdraw(uint256 amount) external {
        _settleOwedRealizedPnl(msg.sender);
        int256 freeCollateral = getFreeCollateral(msg.sender);
        if (freeCollateral < int256(amount)) revert InsufficientFreeCollateral(freeCollateral, amount);
        if (usdcBalance[msg.sender] < int256(amount)) {
            revert InsufficientInternalBalance(msg.sender, usdcBalance[msg.sender], amount);
        }
        usdcBalance[msg.sender] -= int256(amount);
        usdc.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
        _emitLiquidationPriceChange(msg.sender);
    }

    function depositLP(uint256 tokenId) external {
        (PoolKey memory key, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(spotPoolId)) revert InvalidSpotPool(key.toId());

        IERC721(address(positionManager)).transferFrom(msg.sender, address(this), tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        if (liquidity == 0) revert InvalidLiquidity(liquidity);

        lpCollaterals[tokenId] = LPCollateral({
            tokenId: tokenId,
            owner: msg.sender,
            tickLower: positionInfo.tickLower(),
            tickUpper: positionInfo.tickUpper(),
            liquidity: liquidity
        });

        userLPTokenIds[msg.sender].push(tokenId);
        lpTokenIndexPlusOne[tokenId] = userLPTokenIds[msg.sender].length;

        emit LPDeposited(msg.sender, tokenId, liquidity);
        _emitLiquidationPriceChange(msg.sender);
    }

    function withdrawLP(uint256 tokenId) external returns (uint256 ethAmount, uint256 usdcAmount) {
        LPCollateral storage lp = lpCollaterals[tokenId];
        if (lp.owner != msg.sender) revert NotLPTokenOwner(msg.sender, tokenId);

        uint128 liquidityToRemove = lp.liquidity;
        if (liquidityToRemove == 0) revert InvalidLiquidity(liquidityToRemove);

        _requireLpRemovalMargin(msg.sender, tokenId, liquidityToRemove);
        (ethAmount, usdcAmount) = _removeLiquidityFromPosition(tokenId, liquidityToRemove);
        _updateCollateralAfterRemoval(tokenId, liquidityToRemove);

        IERC721(address(positionManager)).transferFrom(address(this), msg.sender, tokenId);
        (ethAmount, usdcAmount) = _settleVoluntaryProceeds(msg.sender, ethAmount, usdcAmount);
        emit LPWithdrawn(msg.sender, tokenId, liquidityToRemove);
        _emitLiquidationPriceChange(msg.sender);
    }

    function decreaseLP(uint256 tokenId, uint128 liquidityToRemove)
        external
        returns (uint256 ethAmount, uint256 usdcAmount)
    {
        LPCollateral storage lp = lpCollaterals[tokenId];
        if (lp.owner != msg.sender) revert NotLPTokenOwner(msg.sender, tokenId);
        if (liquidityToRemove == 0 || liquidityToRemove > lp.liquidity) revert InvalidLiquidity(liquidityToRemove);

        _requireLpRemovalMargin(msg.sender, tokenId, liquidityToRemove);
        (ethAmount, usdcAmount) = _removeLiquidityFromPosition(tokenId, liquidityToRemove);
        _updateCollateralAfterRemoval(tokenId, liquidityToRemove);
        (ethAmount, usdcAmount) = _settleVoluntaryProceeds(msg.sender, ethAmount, usdcAmount);

        uint128 liquidityLeft = lpCollaterals[tokenId].liquidity;
        if (liquidityLeft == 0) {
            IERC721(address(positionManager)).transferFrom(address(this), msg.sender, tokenId);
        }

        emit LPDecreased(msg.sender, tokenId, liquidityToRemove, liquidityLeft);
        _emitLiquidationPriceChange(msg.sender);
    }

    function forceLiquidateLP(address trader, uint256 usdcNeeded)
        external
        onlyClearingHouse
        returns (uint256 usdcRecovered)
    {
        if (usdcNeeded == 0) return 0;

        uint256[] storage tokenIds = userLPTokenIds[trader];
        uint256 markPriceX18 = getMarkPriceX18();
        uint160 sqrtPriceX96 = _getSpotSqrtPriceX96();

        uint256 i = 0;
        while (i < tokenIds.length && usdcRecovered < usdcNeeded) {
            uint256 tokenId = tokenIds[i];
            uint256 usdcRemaining = usdcNeeded - usdcRecovered;
            (uint256 recovered, bool removedFully, bool skipped) =
                _forceLiquidateSinglePosition(trader, tokenId, usdcRemaining, sqrtPriceX96, markPriceX18);
            if (skipped) {
                i++;
                continue;
            }
            usdcRecovered += recovered;
            if (removedFully) {
                continue;
            }
            i++;
        }

        if (usdcRecovered > 0) {
            usdcBalance[trader] += int256(usdcRecovered);
        }

        _emitLiquidationPriceChange(trader);
    }

    function _forceLiquidateSinglePosition(
        address trader,
        uint256 tokenId,
        uint256 usdcRemaining,
        uint160 sqrtPriceX96,
        uint256 markPriceX18
    ) internal returns (uint256 recovered, bool removedFully, bool skipped) {
        LPCollateral storage lp = lpCollaterals[tokenId];
        uint256 lpValue = _getLPValueFromData(lp, sqrtPriceX96, markPriceX18);
        if (lpValue == 0) return (0, false, true);

        uint128 currentLiquidity = lp.liquidity;
        uint128 liquidityToRemove = _estimateLiquidityToRemove(currentLiquidity, lpValue, usdcRemaining);

        (uint256 ethReceived, uint256 usdcReceived) = _removeLiquidityFromPosition(tokenId, liquidityToRemove);
        uint256 usdcFromSwap;
        if (usdcReceived < usdcRemaining) {
            usdcFromSwap = _swapETHtoUSDC(ethReceived, usdcRemaining - usdcReceived, false);
        }
        recovered = usdcReceived + usdcFromSwap;

        removedFully = liquidityToRemove >= currentLiquidity;
        _updateCollateralAfterRemoval(tokenId, liquidityToRemove);
        emit LPForceLiquidated(trader, tokenId, liquidityToRemove, recovered);
    }

    function _estimateLiquidityToRemove(uint128 totalLiquidity, uint256 lpValue, uint256 usdcNeeded)
        internal
        view
        returns (uint128 liquidityToRemove)
    {
        if (lpValue <= usdcNeeded) return totalLiquidity;
        uint256 removeRatioX18 = Math.mulDiv(usdcNeeded, 1e18, lpValue);
        uint256 bufferedRatioX18 = Math.mulDiv(removeRatioX18, 1e6 + lpRemoveBufferRatio, 1e6);
        if (bufferedRatioX18 > 1e18) bufferedRatioX18 = 1e18;
        liquidityToRemove = uint128(Math.mulDiv(totalLiquidity, bufferedRatioX18, 1e18));
        if (liquidityToRemove == 0) liquidityToRemove = 1;
    }

    function moveBalance(address from, address to, uint256 amount) external onlyClearingHouse {
        if (amount == 0) return;
        if (usdcBalance[from] < int256(amount)) {
            revert InsufficientInternalBalance(from, usdcBalance[from], amount);
        }
        usdcBalance[from] -= int256(amount);
        usdcBalance[to] += int256(amount);
        _emitLiquidationPriceChange(from);
        if (to != from) _emitLiquidationPriceChange(to);
    }

    function getAccountValue(address trader) public view returns (int256 accountValue) {
        int256 unrealizedPnl = _getUnrealizedPnl(trader);
        int256 pendingFunding = _getPendingFundingPayment(trader);
        return usdcBalance[trader] + accountBalance.getOwedRealizedPnl(trader) + unrealizedPnl
            + int256(getLPCollateralValue(trader)) - pendingFunding;
    }

    function getFreeCollateral(address trader) public view returns (int256 freeCollateral) {
        return getFreeCollateralByRatio(trader, config.imRatio());
    }

    function getFreeCollateralByRatio(address trader, uint24 ratio) public view returns (int256 freeCollateral) {
        int256 accountValue = getAccountValue(trader);
        int256 collateralValue = usdcBalance[trader] > 0 ? usdcBalance[trader] : int256(0);
        collateralValue += int256(getLPCollateralValue(trader));

        uint256 totalAbsPositionValue = _getTotalAbsPositionValue(trader);
        int256 marginRequirement = int256(PerpMath.mulRatio(totalAbsPositionValue, ratio));
        return PerpMath.min(accountValue, collateralValue) - marginRequirement;
    }

    function getLPCollateralValue(address trader) public view returns (uint256 collateralValue) {
        uint256[] storage tokenIds = userLPTokenIds[trader];
        uint256 len = tokenIds.length;
        if (len == 0) return 0;

        uint160 sqrtPriceX96 = _getSpotSqrtPriceX96();
        uint256 markPriceX18 = getMarkPriceX18();

        for (uint256 i = 0; i < len; i++) {
            LPCollateral storage lp = lpCollaterals[tokenIds[i]];
            if (lp.liquidity == 0) continue;
            collateralValue += _getLPValueFromData(lp, sqrtPriceX96, markPriceX18);
        }
    }

    function getNetCashBalance(address trader) public view returns (int256 netCashBalance) {
        return usdcBalance[trader] + accountBalance.getOwedRealizedPnl(trader);
    }

    function getUserLPTokenIds(address trader) external view returns (uint256[] memory tokenIds) {
        return userLPTokenIds[trader];
    }

    function hasLPCollateral(address trader) external view returns (bool) {
        return userLPTokenIds[trader].length > 0;
    }

    function getMarkPriceX18() public view returns (uint256 priceX18) {
        return priceOracle.getIndexPrice(config.twapInterval());
    }

    function isLiquidatable(address trader) public view returns (bool) {
        int256 accountValue = getAccountValue(trader);
        int256 marginRequirement = int256(PerpMath.mulRatio(_getTotalAbsPositionValue(trader), config.mmRatio()));
        return accountValue < marginRequirement;
    }

    function getLiquidationPriceX18(address trader) public view returns (uint256 liquidationPriceX18) {
        (int256 netPositionSize, int256 totalOpenNotional, uint256 totalAbsPositionSize) =
            _getPositionAggregates(trader);
        if (totalAbsPositionSize == 0) return 0;

        (uint256 lpEthAmount, uint256 lpUsdcAmount) = _getLPCollateralAmounts(trader);
        int256 pendingFunding = _getPendingFundingPayment(trader);

        int256 constantTerm = usdcBalance[trader] + accountBalance.getOwedRealizedPnl(trader) + totalOpenNotional
            + int256(lpUsdcAmount) - pendingFunding;
        int256 mmWeightedAbsSize = int256(PerpMath.mulRatio(totalAbsPositionSize, config.mmRatio()));
        int256 priceSlope = netPositionSize + int256(lpEthAmount) - mmWeightedAbsSize;
        if (priceSlope == 0) return 0;

        int256 signedNumerator = priceSlope > 0 ? PerpMath.neg256(constantTerm) : constantTerm;
        int256 priceX18 = PerpMath.mulDiv(signedNumerator, int256(1e18), PerpMath.abs(priceSlope));
        if (priceX18 <= 0) return 0;
        return uint256(priceX18);
    }

    function notifyLiquidationPriceChange(address trader) external onlyClearingHouse {
        _emitLiquidationPriceChange(trader);
    }

    function getLiquidationState(address trader)
        external
        view
        returns (int256 accountValue, int256 marginRequirement, uint256 totalAbsPositionValue, bool liquidatable)
    {
        accountValue = getAccountValue(trader);
        totalAbsPositionValue = _getTotalAbsPositionValue(trader);
        marginRequirement = int256(PerpMath.mulRatio(totalAbsPositionValue, config.mmRatio()));
        liquidatable = accountValue < marginRequirement;
    }

    function settleBadDebt(address trader) external onlyClearingHouse {
        if (accountBalance.getActivePoolIds(trader).length != 0) return;
        if (userLPTokenIds[trader].length != 0) return;

        _settleOwedRealizedPnl(trader);
        int256 cashBalance = usdcBalance[trader];
        if (cashBalance >= 0) return;

        uint256 badDebt = uint256(-cashBalance);
        usdcBalance[trader] = 0;
        usdcBalance[insuranceFund] -= int256(badDebt);
        _emitLiquidationPriceChange(trader);
        _emitLiquidationPriceChange(insuranceFund);
    }

    function _requireLpRemovalMargin(address trader, uint256 tokenId, uint128 liquidityToRemove) internal view {
        uint256 totalAbsPositionValue = _getTotalAbsPositionValue(trader);
        if (totalAbsPositionValue == 0) return;

        LPCollateral storage lp = lpCollaterals[tokenId];
        uint256 removedValue = Math.mulDiv(
            _getLPValueFromData(lp, _getSpotSqrtPriceX96(), getMarkPriceX18()), liquidityToRemove, lp.liquidity
        );

        int256 accountValueAfter = getAccountValue(trader) - int256(removedValue);
        uint256 totalLpValue = getLPCollateralValue(trader);
        uint256 lpAfter = totalLpValue > removedValue ? totalLpValue - removedValue : 0;
        int256 collateralAfter = (usdcBalance[trader] > 0 ? usdcBalance[trader] : int256(0)) + int256(lpAfter);
        int256 marginRequirement = int256(PerpMath.mulRatio(totalAbsPositionValue, config.imRatio()));

        int256 freeCollateralAfter = PerpMath.min(accountValueAfter, collateralAfter) - marginRequirement;
        if (freeCollateralAfter < 0) revert InsufficientFreeCollateral(freeCollateralAfter, 0);
    }

    function _removeLiquidityFromPosition(uint256 tokenId, uint128 liquidityToRemove)
        internal
        returns (uint256 ethReceived, uint256 usdcReceived)
    {
        uint256 balance0Before = spotPoolKey.currency0.balanceOf(address(this));
        uint256 balance1Before = spotPoolKey.currency1.balanceOf(address(this));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidityToRemove), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(spotPoolKey.currency0, spotPoolKey.currency1, address(this));

        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
            block.timestamp + 1
        );

        uint256 amount0 = spotPoolKey.currency0.balanceOf(address(this)) - balance0Before;
        uint256 amount1 = spotPoolKey.currency1.balanceOf(address(this)) - balance1Before;

        if (spotEthIsCurrency0) {
            ethReceived = amount0;
            usdcReceived = amount1;
        } else {
            ethReceived = amount1;
            usdcReceived = amount0;
        }
    }

    function _swapETHtoUSDC(uint256 ethAmount, uint256 requiredUsdcOut, bool strictMinOut)
        internal
        returns (uint256 usdcOut)
    {
        if (ethAmount == 0) return 0;
        if (poolManager.getLiquidity(spotPoolId) == 0) return 0;
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 expectedUsdcOut = Math.mulDiv(ethAmount, getMarkPriceX18(), 1e18);
        uint256 minUsdcOut = Math.mulDiv(expectedUsdcOut, uint256(1e6) - forcedSwapSlippageRatio, 1e6);
        if (requiredUsdcOut > 0 && minUsdcOut > requiredUsdcOut) {
            minUsdcOut = requiredUsdcOut;
        }
        bool zeroForOne = spotEthIsCurrency0;
        if (strictMinOut) {
            swapRouter.swapExactTokensForTokens{value: ethAmount}(
                ethAmount, minUsdcOut, zeroForOne, spotPoolKey, bytes(""), address(this), block.timestamp + 1
            );
        } else {
            try swapRouter.swapExactTokensForTokens{value: ethAmount}(
                ethAmount, minUsdcOut, zeroForOne, spotPoolKey, bytes(""), address(this), block.timestamp + 1
            ) {}
            catch {
                swapRouter.swapExactTokensForTokens{value: ethAmount}(
                    ethAmount, 0, zeroForOne, spotPoolKey, bytes(""), address(this), block.timestamp + 1
                );
            }
        }
        return usdc.balanceOf(address(this)) - usdcBefore;
    }

    function _settleVoluntaryProceeds(address trader, uint256 ethAmount, uint256 usdcAmount)
        internal
        returns (uint256 ethReturned, uint256 usdcReturned)
    {
        int256 netCashBalance = getNetCashBalance(trader);
        if (netCashBalance < 0) {
            uint256 usdcDebt = uint256(-netCashBalance);
            uint256 usdcFromSwap;
            if (usdcAmount < usdcDebt) {
                usdcFromSwap = _swapETHtoUSDC(ethAmount, usdcDebt - usdcAmount, true);
            }
            uint256 totalUsdc = usdcAmount + usdcFromSwap;

            uint256 debtRepayment = totalUsdc > usdcDebt ? usdcDebt : totalUsdc;
            if (debtRepayment > 0) {
                usdcBalance[trader] += int256(debtRepayment);
            }

            uint256 surplus = totalUsdc - debtRepayment;
            if (surplus > 0) {
                usdc.transfer(trader, surplus);
            }
            return (0, surplus);
        }

        if (ethAmount > 0) _transferNative(trader, ethAmount);
        if (usdcAmount > 0) usdc.transfer(trader, usdcAmount);
        return (ethAmount, usdcAmount);
    }

    function _updateCollateralAfterRemoval(uint256 tokenId, uint128 liquidityRemoved) internal {
        LPCollateral storage lp = lpCollaterals[tokenId];
        if (liquidityRemoved >= lp.liquidity) {
            _removeLPRecord(tokenId, lp.owner);
            return;
        }
        lp.liquidity -= liquidityRemoved;
    }

    function _removeLPRecord(uint256 tokenId, address trader) internal {
        uint256[] storage tokenIds = userLPTokenIds[trader];
        uint256 index = lpTokenIndexPlusOne[tokenId] - 1;
        uint256 lastIndex = tokenIds.length - 1;
        if (index != lastIndex) {
            uint256 movedTokenId = tokenIds[lastIndex];
            tokenIds[index] = movedTokenId;
            lpTokenIndexPlusOne[movedTokenId] = index + 1;
        }
        tokenIds.pop();
        delete lpTokenIndexPlusOne[tokenId];
        delete lpCollaterals[tokenId];
    }

    function _transferNative(address to, uint256 amount) internal {
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert NativeTransferFailed(to, amount);
    }

    function _settleOwedRealizedPnl(address trader) internal {
        int256 pnl = accountBalance.settleOwedRealizedPnl(trader);
        usdcBalance[trader] += pnl;
    }

    function _getSpotSqrtPriceX96() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(spotPoolId);
    }

    function _getLPValueFromData(LPCollateral storage lp, uint160 sqrtPriceX96, uint256 markPriceX18)
        internal
        view
        returns (uint256 valueX18)
    {
        (valueX18,,) = LPValuation.getLPValue(
            sqrtPriceX96, lp.tickLower, lp.tickUpper, lp.liquidity, markPriceX18, spotEthIsCurrency0
        );
    }

    function _getUnrealizedPnl(address trader) internal view returns (int256 unrealizedPnl) {
        PoolId[] memory pools = accountBalance.getActivePoolIds(trader);
        uint256 priceX18 = getMarkPriceX18();
        uint256 len = pools.length;
        for (uint256 i = 0; i < len; i++) {
            IAccountBalance.PositionInfo memory info = accountBalance.getPositionInfo(trader, pools[i]);
            if (info.takerPositionSize == 0) continue;
            int256 positionValue = PerpMath.mulDiv(info.takerPositionSize, int256(priceX18), 1e18);
            unrealizedPnl += positionValue + info.takerOpenNotional;
        }
    }

    function _getTotalAbsPositionValue(address trader) internal view returns (uint256 totalAbsPositionValue) {
        PoolId[] memory pools = accountBalance.getActivePoolIds(trader);
        uint256 priceX18 = getMarkPriceX18();
        uint256 len = pools.length;
        for (uint256 i = 0; i < len; i++) {
            IAccountBalance.PositionInfo memory info = accountBalance.getPositionInfo(trader, pools[i]);
            if (info.takerPositionSize == 0) continue;
            totalAbsPositionValue += Math.mulDiv(PerpMath.abs(info.takerPositionSize), priceX18, 1e18);
        }
    }

    function _getPendingFundingPayment(address trader) internal view returns (int256 pendingFundingPayment) {
        if (address(fundingRate) == address(0)) return 0;
        PoolId[] memory pools = accountBalance.getActivePoolIds(trader);
        uint256 len = pools.length;
        for (uint256 i = 0; i < len; i++) {
            pendingFundingPayment += fundingRate.getPendingFundingPayment(trader, pools[i]);
        }
    }

    function _getPositionAggregates(address trader)
        internal
        view
        returns (int256 netPositionSize, int256 totalOpenNotional, uint256 totalAbsPositionSize)
    {
        PoolId[] memory pools = accountBalance.getActivePoolIds(trader);
        uint256 len = pools.length;
        for (uint256 i = 0; i < len; i++) {
            IAccountBalance.PositionInfo memory info = accountBalance.getPositionInfo(trader, pools[i]);
            if (info.takerPositionSize == 0) continue;
            netPositionSize += info.takerPositionSize;
            totalOpenNotional += info.takerOpenNotional;
            totalAbsPositionSize += PerpMath.abs(info.takerPositionSize);
        }
    }

    function _getLPCollateralAmounts(address trader)
        internal
        view
        returns (uint256 totalEthAmount, uint256 totalUsdcAmount)
    {
        uint256[] storage tokenIds = userLPTokenIds[trader];
        uint256 len = tokenIds.length;
        if (len == 0) return (0, 0);

        uint160 sqrtPriceX96 = _getSpotSqrtPriceX96();
        for (uint256 i = 0; i < len; i++) {
            LPCollateral storage lp = lpCollaterals[tokenIds[i]];
            if (lp.liquidity == 0) continue;
            (, uint256 ethAmount, uint256 usdcAmount) =
                LPValuation.getLPValue(sqrtPriceX96, lp.tickLower, lp.tickUpper, lp.liquidity, 1e18, spotEthIsCurrency0);
            totalEthAmount += ethAmount;
            totalUsdcAmount += usdcAmount;
        }
    }

    function _emitLiquidationPriceChange(address trader) internal {
        emit LiquidationPriceChange(trader, getLiquidationPriceX18(trader));
    }
}
