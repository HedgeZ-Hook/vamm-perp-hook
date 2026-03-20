// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IAccountBalance} from "../src/interfaces/IAccountBalance.sol";
import {IFundingRate} from "../src/interfaces/IFundingRate.sol";
import {PerpMath} from "../src/libraries/PerpMath.sol";
import {FormatUtils} from "./base/FormatUtils.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract InspectLpAccountStateUnichainSepolia is Script {
    using StateLibrary for IPoolManager;

    error InvalidChain(uint256 actual, uint256 expected);

    struct Snapshot {
        address trader;
        uint256 walletUsdcRaw;
        uint256 oraclePriceX18;
        uint256 vammPriceX18;
        int256 positionSize;
        int256 openNotional;
        int256 entryPriceX18;
        uint256 currentNotionalX18;
        int256 owedRealizedPnl;
        int256 pendingFunding;
        int256 unrealizedPnl;
        int256 totalPnl;
        int256 accountValue;
        int256 freeCollateral;
        int256 netCashBalance;
        uint256 lpCollateralValue;
        bool hasLPCollateral;
        uint256 liquidationPriceX18;
        bool isLiquidatable;
    }

    function run() external view {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        address trader = vm.envOr("INSPECT_TRADER", address(0));
        if (trader == address(0)) {
            trader = vm.addr(vm.envUint("PRIVATE_KEY"));
        }

        address usdc = vm.envAddress("USDC");
        ClearingHouse clearingHouse = ClearingHouse(vm.envAddress("CLEARING_HOUSE"));
        IVault vault = clearingHouse.vault();
        IAccountBalance accountBalance = clearingHouse.accountBalance();
        IFundingRate fundingRate = clearingHouse.fundingRate();
        PoolId vammPoolId = clearingHouse.vammPoolId();

        Snapshot memory snap = _snapshot(trader, usdc, vault, accountBalance, fundingRate, clearingHouse, vammPoolId);

        console2.log("===== LP Account State =====");
        _printSnapshot(snap);

        uint256[] memory tokenIds = vault.getUserLPTokenIds(trader);
        console2.log("LP token count:", tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            console2.log("LP tokenId:", tokenIds[i]);
        }
    }

    function _snapshot(
        address trader,
        address usdc,
        IVault vault,
        IAccountBalance accountBalance,
        IFundingRate fundingRate,
        ClearingHouse clearingHouse,
        PoolId vammPoolId
    ) internal view returns (Snapshot memory snap) {
        snap.trader = trader;
        snap.walletUsdcRaw = IERC20(usdc).balanceOf(trader);
        snap.oraclePriceX18 = vault.getMarkPriceX18();
        snap.vammPriceX18 = _vammPriceX18(clearingHouse, vammPoolId);
        snap.positionSize = accountBalance.getTakerPositionSize(trader, vammPoolId);
        snap.openNotional = accountBalance.getTakerOpenNotional(trader, vammPoolId);
        snap.entryPriceX18 = _entryPriceX18(snap.positionSize, snap.openNotional);
        snap.currentNotionalX18 = _currentNotionalX18(snap.positionSize, snap.oraclePriceX18);
        snap.owedRealizedPnl = accountBalance.getOwedRealizedPnl(trader);
        snap.pendingFunding = fundingRate.getPendingFundingPayment(trader, vammPoolId);
        snap.unrealizedPnl = snap.positionSize == 0
            ? int256(0)
            : ((snap.positionSize * int256(snap.oraclePriceX18)) / int256(1e18)) + snap.openNotional;
        snap.totalPnl = snap.owedRealizedPnl + snap.unrealizedPnl - snap.pendingFunding;
        snap.accountValue = vault.getAccountValue(trader);
        snap.freeCollateral = vault.getFreeCollateral(trader);
        snap.netCashBalance = vault.getNetCashBalance(trader);
        snap.lpCollateralValue = vault.getLPCollateralValue(trader);
        snap.hasLPCollateral = vault.hasLPCollateral(trader);
        snap.liquidationPriceX18 = vault.getLiquidationPriceX18(trader);
        snap.isLiquidatable = vault.isLiquidatable(trader);
    }

    function _printSnapshot(Snapshot memory snap) internal pure {
        console2.log("Trader:", snap.trader);

        console2.log("--- Wallet ---");
        console2.log("USDC balance:", FormatUtils.formatUsdcRaw(snap.walletUsdcRaw), "USDC");

        console2.log("--- Market ---");
        console2.log("Oracle price:", FormatUtils.formatX18(snap.oraclePriceX18), "USDC/ETH");
        console2.log("vAMM price:", FormatUtils.formatX18(snap.vammPriceX18), "USDC/ETH");

        console2.log("--- Position ---");
        console2.log("Side:", _side(snap.positionSize));
        console2.log("Position size:", FormatUtils.formatSignedX18(snap.positionSize), "ETH");
        console2.log("Open notional:", FormatUtils.formatSignedX18(snap.openNotional), "vUSDC");
        console2.log("Entry price:", FormatUtils.formatSignedX18(snap.entryPriceX18), "USDC/ETH");
        console2.log("Current notional:", FormatUtils.formatX18(snap.currentNotionalX18), "USD");

        console2.log("--- PnL ---");
        console2.log("Unrealized PnL:", FormatUtils.formatSignedX18(snap.unrealizedPnl), "USD");
        console2.log("Realized PnL:", FormatUtils.formatSignedX18(snap.owedRealizedPnl), "USD");
        console2.log("Pending funding:", FormatUtils.formatSignedX18(snap.pendingFunding), "USD");
        console2.log("Total PnL:", FormatUtils.formatSignedX18(snap.totalPnl), "USD");

        console2.log("--- Collateral & Risk ---");
        console2.log("Account value:", FormatUtils.formatSignedX18(snap.accountValue), "USD");
        console2.log("Free collateral:", FormatUtils.formatSignedX18(snap.freeCollateral), "USD");
        console2.log("Net cash balance:", FormatUtils.formatSignedX18(snap.netCashBalance), "USD");
        console2.log("LP collateral value:", FormatUtils.formatX18(snap.lpCollateralValue), "USD");
        console2.log("Has LP collateral:", snap.hasLPCollateral);
        console2.log("Liquidation price:", FormatUtils.formatX18(snap.liquidationPriceX18), "USDC/ETH");
        console2.log("Is liquidatable:", snap.isLiquidatable);
    }

    function _entryPriceX18(int256 positionSize, int256 openNotional) internal pure returns (int256) {
        uint256 absSize = _abs(positionSize);
        if (absSize == 0) return 0;
        return int256((_abs(openNotional) * 1e18) / absSize);
    }

    function _currentNotionalX18(int256 positionSize, uint256 markPriceX18) internal pure returns (uint256) {
        return (_abs(positionSize) * markPriceX18) / 1e18;
    }

    function _vammPriceX18(ClearingHouse clearingHouse, PoolId vammPoolId) internal view returns (uint256) {
        (Currency currency0,,,,) = clearingHouse.vammPoolKey();
        Currency baseCurrency = clearingHouse.baseCurrency();
        (uint160 sqrtPriceX96,,,) = clearingHouse.poolManager().getSlot0(vammPoolId);
        if (sqrtPriceX96 == 0) return 0;
        uint256 priceX96 = PerpMath.formatSqrtPriceX96ToPriceX96(sqrtPriceX96);
        uint256 rawRatioX18 = PerpMath.formatX96ToX10_18(priceX96);
        if (baseCurrency == currency0) return rawRatioX18;
        return FullMath.mulDiv(1e36, 1, rawRatioX18);
    }

    function _side(int256 positionSize) internal pure returns (string memory) {
        if (positionSize > 0) return "LONG";
        if (positionSize < 0) return "SHORT";
        return "FLAT";
    }

    function _abs(int256 value) internal pure returns (uint256) {
        if (value >= 0) return uint256(value);
        unchecked {
            return uint256(-(value + 1)) + 1;
        }
    }
}
