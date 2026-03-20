// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IAccountBalance} from "../src/interfaces/IAccountBalance.sol";
import {FormatUtils} from "./base/FormatUtils.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract InspectTraderPositionUnichainSepolia is Script {
    using StateLibrary for IPoolManager;

    error InvalidChain(uint256 actual, uint256 expected);

    struct Snapshot {
        address trader;
        uint256 vammPoolIdRaw;
        uint256 sqrtPriceX96;
        int24 tick;
        uint256 liquidity;
        int256 positionSize;
        int256 openNotional;
        int256 owedRealizedPnl;
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

        ClearingHouse clearingHouse = ClearingHouse(vm.envAddress("CLEARING_HOUSE"));
        IVault vault = clearingHouse.vault();
        IAccountBalance accountBalance = clearingHouse.accountBalance();
        IPoolManager poolManager = clearingHouse.poolManager();
        PoolId vammPoolId = clearingHouse.vammPoolId();

        Snapshot memory snap = _snapshot(trader, vault, accountBalance, poolManager, vammPoolId);

        console2.log("===== Trader Position Status =====");
        _printSnapshot(snap);

        uint256[] memory tokenIds = vault.getUserLPTokenIds(trader);
        console2.log("LP token count:", tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            console2.log("LP tokenId:", tokenIds[i]);
        }
    }

    function _snapshot(
        address trader,
        IVault vault,
        IAccountBalance accountBalance,
        IPoolManager poolManager,
        PoolId vammPoolId
    ) internal view returns (Snapshot memory snap) {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(vammPoolId);
        snap.trader = trader;
        snap.vammPoolIdRaw = uint256(PoolId.unwrap(vammPoolId));
        snap.sqrtPriceX96 = uint256(sqrtPriceX96);
        snap.tick = tick;
        snap.liquidity = uint256(poolManager.getLiquidity(vammPoolId));
        snap.positionSize = accountBalance.getTakerPositionSize(trader, vammPoolId);
        snap.openNotional = accountBalance.getTakerOpenNotional(trader, vammPoolId);
        snap.owedRealizedPnl = accountBalance.getOwedRealizedPnl(trader);
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
        console2.log("vAMM PoolId:", snap.vammPoolIdRaw);
        console2.log("vAMM sqrtPriceX96:", snap.sqrtPriceX96);
        console2.log("vAMM tick:", int256(snap.tick));
        console2.log("vAMM liquidity:", snap.liquidity);
        console2.log("Position size:", snap.positionSize);
        console2.log("Position size:", FormatUtils.formatSignedX18(snap.positionSize));
        console2.log("Open notional:", snap.openNotional);
        console2.log("Open notional:", FormatUtils.formatSignedX18(snap.openNotional), "vUSDC");
        console2.log("Owed realized PnL:", snap.owedRealizedPnl);
        console2.log("Owed realized PnL:", FormatUtils.formatSignedX18(snap.owedRealizedPnl), "USD");
        console2.log("Account value:", snap.accountValue);
        console2.log("Account value:", FormatUtils.formatSignedX18(snap.accountValue), "USD");
        console2.log("Free collateral:", snap.freeCollateral);
        console2.log("Free collateral:", FormatUtils.formatSignedX18(snap.freeCollateral), "USD");
        console2.log("Net cash balance:", snap.netCashBalance);
        console2.log("Net cash balance:", FormatUtils.formatSignedX18(snap.netCashBalance), "USD");
        console2.log("LP collateral value:", snap.lpCollateralValue);
        console2.log("LP collateral value:", FormatUtils.formatX18(snap.lpCollateralValue), "USD");
        console2.log("Has LP collateral:", snap.hasLPCollateral);
        console2.log("Liquidation price x18:", snap.liquidationPriceX18);
        console2.log("Liquidation price:", FormatUtils.formatX18(snap.liquidationPriceX18), "USDC/ETH");
        console2.log("Is liquidatable:", snap.isLiquidatable);
    }
}
