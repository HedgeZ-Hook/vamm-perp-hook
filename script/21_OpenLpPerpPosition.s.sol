// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract OpenLpPerpPositionUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error ZeroOrderAmount();
    error NoLpCollateral(address trader);

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);
        IVault vault = IVault(vm.envAddress("VAULT"));
        IClearingHouse clearingHouse = IClearingHouse(vm.envAddress("CLEARING_HOUSE"));

        uint256 amount = vm.envUint("LP_ORDER_AMOUNT");
        if (amount == 0) revert ZeroOrderAmount();
        if (!vault.hasLPCollateral(trader)) revert NoLpCollateral(trader);

        bool isBaseToQuote = vm.envOr("LP_ORDER_IS_BASE_TO_QUOTE", false);
        uint160 sqrtPriceLimitX96 = uint160(vm.envOr("LP_ORDER_SQRT_PRICE_LIMIT_X96", uint256(0)));

        vm.startBroadcast(pk);
        (int256 base, int256 quote) = clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: isBaseToQuote, amount: amount, sqrtPriceLimitX96: sqrtPriceLimitX96, hookData: bytes("")
            })
        );
        vm.stopBroadcast();

        console2.log("===== LP Perp Order Executed =====");
        console2.log("Trader:", trader);
        console2.log("isBaseToQuote:", isBaseToQuote);
        console2.log("Order amount:", amount);
        console2.log("Base delta:", base);
        console2.log("Quote delta:", quote);
        console2.log("LP collateral value:", vault.getLPCollateralValue(trader));
        console2.log("Free collateral:", vault.getFreeCollateral(trader));
    }
}
