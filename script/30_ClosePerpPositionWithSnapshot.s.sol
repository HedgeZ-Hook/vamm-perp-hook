// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IAccountBalance} from "../src/interfaces/IAccountBalance.sol";
import {IFundingRate} from "../src/interfaces/IFundingRate.sol";
import {FormatUtils} from "./base/FormatUtils.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract ClosePerpPositionWithSnapshotUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);

    struct Snapshot {
        uint256 walletUsdcRaw;
        int256 positionSize;
        int256 openNotional;
        int256 owedRealizedPnl;
        int256 pendingFunding;
        int256 accountValue;
        int256 freeCollateral;
        int256 netCashBalance;
        uint256 lpCollateralValue;
        uint256 liquidationPriceX18;
        bool isLiquidatable;
    }

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);
        address usdc = vm.envAddress("USDC");
        ClearingHouse clearingHouse = ClearingHouse(vm.envAddress("CLEARING_HOUSE"));
        IVault vault = clearingHouse.vault();
        IAccountBalance accountBalance = clearingHouse.accountBalance();
        IFundingRate fundingRate = clearingHouse.fundingRate();
        PoolId vammPoolId = clearingHouse.vammPoolId();

        uint256 closeAmount = vm.envOr("CLOSE_AMOUNT", uint256(0));
        uint160 sqrtPriceLimitX96 = uint160(vm.envOr("CLOSE_SQRT_PRICE_LIMIT_X96", uint256(0)));

        Snapshot memory beforeState = _snapshot(trader, usdc, vault, accountBalance, fundingRate, vammPoolId);

        vm.startBroadcast(pk);
        (int256 base, int256 quote) = clearingHouse.closePosition(closeAmount, sqrtPriceLimitX96, bytes(""));
        vm.stopBroadcast();

        Snapshot memory afterState = _snapshot(trader, usdc, vault, accountBalance, fundingRate, vammPoolId);

        console2.log("===== Close Perp Position With Snapshot =====");
        console2.log("Trader:", trader);
        console2.log("Close amount:", closeAmount);
        console2.log("Close amount:", FormatUtils.formatX18(closeAmount));
        console2.log("Base delta:", base);
        console2.log("Base delta:", FormatUtils.formatSignedX18(base));
        console2.log("Quote delta:", quote);
        console2.log("Quote delta:", FormatUtils.formatSignedX18(quote), "vUSDC");

        console2.log("----- Before -----");
        _print(beforeState);

        console2.log("----- After -----");
        _print(afterState);

        console2.log("----- Delta -----");
        console2.log("Wallet USDC raw delta:", int256(afterState.walletUsdcRaw) - int256(beforeState.walletUsdcRaw));
        console2.log(
            "Wallet USDC delta:",
            FormatUtils.formatSignedScaled(int256(afterState.walletUsdcRaw) - int256(beforeState.walletUsdcRaw), 6, 6),
            "USDC"
        );
        console2.log("Position size delta:", afterState.positionSize - beforeState.positionSize);
        console2.log(
            "Position size delta:", FormatUtils.formatSignedX18(afterState.positionSize - beforeState.positionSize)
        );
        console2.log("Open notional delta:", afterState.openNotional - beforeState.openNotional);
        console2.log(
            "Open notional delta:",
            FormatUtils.formatSignedX18(afterState.openNotional - beforeState.openNotional),
            "vUSDC"
        );
        console2.log("Owed realized PnL delta:", afterState.owedRealizedPnl - beforeState.owedRealizedPnl);
        console2.log(
            "Owed realized PnL delta:",
            FormatUtils.formatSignedX18(afterState.owedRealizedPnl - beforeState.owedRealizedPnl),
            "USD"
        );
        console2.log("Pending funding delta:", afterState.pendingFunding - beforeState.pendingFunding);
        console2.log(
            "Pending funding delta:",
            FormatUtils.formatSignedX18(afterState.pendingFunding - beforeState.pendingFunding),
            "USD"
        );
        console2.log("Account value delta:", afterState.accountValue - beforeState.accountValue);
        console2.log(
            "Account value delta:",
            FormatUtils.formatSignedX18(afterState.accountValue - beforeState.accountValue),
            "USD"
        );
        console2.log("Free collateral delta:", afterState.freeCollateral - beforeState.freeCollateral);
        console2.log(
            "Free collateral delta:",
            FormatUtils.formatSignedX18(afterState.freeCollateral - beforeState.freeCollateral),
            "USD"
        );
        console2.log("Net cash balance delta:", afterState.netCashBalance - beforeState.netCashBalance);
        console2.log(
            "Net cash balance delta:",
            FormatUtils.formatSignedX18(afterState.netCashBalance - beforeState.netCashBalance),
            "USD"
        );
        console2.log(
            "LP collateral value delta:", int256(afterState.lpCollateralValue) - int256(beforeState.lpCollateralValue)
        );
        console2.log(
            "LP collateral value delta:",
            FormatUtils.formatSignedX18(int256(afterState.lpCollateralValue) - int256(beforeState.lpCollateralValue)),
            "USD"
        );
    }

    function _snapshot(
        address trader,
        address usdc,
        IVault vault,
        IAccountBalance accountBalance,
        IFundingRate fundingRate,
        PoolId vammPoolId
    ) internal view returns (Snapshot memory s) {
        s.walletUsdcRaw = IERC20(usdc).balanceOf(trader);
        s.positionSize = accountBalance.getTakerPositionSize(trader, vammPoolId);
        s.openNotional = accountBalance.getTakerOpenNotional(trader, vammPoolId);
        s.owedRealizedPnl = accountBalance.getOwedRealizedPnl(trader);
        s.pendingFunding = fundingRate.getPendingFundingPayment(trader, vammPoolId);
        s.accountValue = vault.getAccountValue(trader);
        s.freeCollateral = vault.getFreeCollateral(trader);
        s.netCashBalance = vault.getNetCashBalance(trader);
        s.lpCollateralValue = vault.getLPCollateralValue(trader);
        s.liquidationPriceX18 = vault.getLiquidationPriceX18(trader);
        s.isLiquidatable = vault.isLiquidatable(trader);
    }

    function _print(Snapshot memory s) internal view {
        console2.log("Wallet USDC raw:", s.walletUsdcRaw);
        console2.log("Wallet USDC:", FormatUtils.formatUsdcRaw(s.walletUsdcRaw), "USDC");
        console2.log("Position size:", s.positionSize);
        console2.log("Position size:", FormatUtils.formatSignedX18(s.positionSize));
        console2.log("Open notional:", s.openNotional);
        console2.log("Open notional:", FormatUtils.formatSignedX18(s.openNotional), "vUSDC");
        console2.log("Owed realized PnL:", s.owedRealizedPnl);
        console2.log("Owed realized PnL:", FormatUtils.formatSignedX18(s.owedRealizedPnl), "USD");
        console2.log("Pending funding:", s.pendingFunding);
        console2.log("Pending funding:", FormatUtils.formatSignedX18(s.pendingFunding), "USD");
        console2.log("Unrealized PnL:", _unrealizedPnl(s));
        console2.log("Unrealized PnL:", FormatUtils.formatSignedX18(_unrealizedPnl(s)), "USD");
        console2.log("Account value:", s.accountValue);
        console2.log("Account value:", FormatUtils.formatSignedX18(s.accountValue), "USD");
        console2.log("Free collateral:", s.freeCollateral);
        console2.log("Free collateral:", FormatUtils.formatSignedX18(s.freeCollateral), "USD");
        console2.log("Net cash balance:", s.netCashBalance);
        console2.log("Net cash balance:", FormatUtils.formatSignedX18(s.netCashBalance), "USD");
        console2.log("LP collateral value:", s.lpCollateralValue);
        console2.log("LP collateral value:", FormatUtils.formatX18(s.lpCollateralValue), "USD");
        console2.log("Liquidation price x18:", s.liquidationPriceX18);
        console2.log("Liquidation price:", FormatUtils.formatX18(s.liquidationPriceX18), "USDC/ETH");
        console2.log("Is liquidatable:", s.isLiquidatable);
    }

    function _unrealizedPnl(Snapshot memory s) internal pure returns (int256) {
        return s.accountValue - s.netCashBalance - int256(s.lpCollateralValue) + s.pendingFunding;
    }
}
