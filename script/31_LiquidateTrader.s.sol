// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {FormatUtils} from "./base/FormatUtils.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract LiquidateTraderUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error InvalidTrader();

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address liquidator = vm.addr(pk);
        address trader = vm.envAddress("LIQUIDATE_TRADER");
        if (trader == address(0)) revert InvalidTrader();

        IClearingHouse clearingHouse = IClearingHouse(vm.envAddress("CLEARING_HOUSE"));

        vm.startBroadcast(pk);
        (bool isFullyLiquidated, uint256 liquidatedPositionSize, uint256 penalty) = clearingHouse.liquidate(trader);
        vm.stopBroadcast();

        console2.log("===== Trader Liquidated =====");
        console2.log("Liquidator:", liquidator);
        console2.log("Trader:", trader);
        console2.log("isFullyLiquidated:", isFullyLiquidated);
        console2.log("Liquidated position size:", liquidatedPositionSize);
        console2.log("Liquidated position size:", FormatUtils.formatX18(liquidatedPositionSize), "ETH");
        console2.log("Penalty:", penalty);
        console2.log("Penalty:", FormatUtils.formatX18(penalty), "USDC");
    }
}
