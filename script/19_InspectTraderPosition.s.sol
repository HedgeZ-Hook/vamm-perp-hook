// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IAccountBalance} from "../src/interfaces/IAccountBalance.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract InspectTraderPositionUnichainSepolia is Script {
    using StateLibrary for IPoolManager;

    error InvalidChain(uint256 actual, uint256 expected);

    function run() external view {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        address trader = vm.envOr("INSPECT_TRADER", address(0));
        if (trader == address(0)) {
            trader = vm.addr(vm.envUint("PRIVATE_KEY"));
        }

        IVault vault = IVault(vm.envAddress("VAULT"));
        IClearingHouse clearingHouse = IClearingHouse(vm.envAddress("CLEARING_HOUSE"));
        IAccountBalance accountBalance = IAccountBalance(vm.envAddress("ACCOUNT_BALANCE"));
        IPoolManager poolManager = clearingHouse.poolManager();
        PoolId vammPoolId = clearingHouse.vammPoolId();

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(vammPoolId);

        console2.log("===== Trader Position Status =====");
        console2.log("Trader:", trader);
        console2.log("vAMM PoolId:", uint256(PoolId.unwrap(vammPoolId)));
        console2.log("vAMM sqrtPriceX96:", uint256(sqrtPriceX96));
        console2.log("vAMM tick:", int256(tick));
        console2.log("vAMM liquidity:", uint256(poolManager.getLiquidity(vammPoolId)));
        console2.log("Position size:", accountBalance.getTakerPositionSize(trader, vammPoolId));
        console2.log("Open notional:", accountBalance.getTakerOpenNotional(trader, vammPoolId));
        console2.log("Owed realized PnL:", accountBalance.getOwedRealizedPnl(trader));
        console2.log("Account value:", vault.getAccountValue(trader));
        console2.log("Free collateral:", vault.getFreeCollateral(trader));
        console2.log("Net cash balance:", vault.getNetCashBalance(trader));
        console2.log("LP collateral value:", vault.getLPCollateralValue(trader));
        console2.log("Has LP collateral:", vault.hasLPCollateral(trader));
        console2.log("Liquidation price x18:", vault.getLiquidationPriceX18(trader));
        console2.log("Is liquidatable:", vault.isLiquidatable(trader));

        uint256[] memory tokenIds = vault.getUserLPTokenIds(trader);
        console2.log("LP token count:", tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            console2.log("LP tokenId:", tokenIds[i]);
        }
    }
}
