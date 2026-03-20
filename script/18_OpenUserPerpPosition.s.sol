// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {FormatUtils} from "./base/FormatUtils.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract OpenUserPerpPositionUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error ZeroOrderAmount();

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);
        IERC20 usdc = IERC20(vm.envAddress("USDC"));
        IVault vault = IVault(vm.envAddress("VAULT"));
        IClearingHouse clearingHouse = IClearingHouse(vm.envAddress("CLEARING_HOUSE"));

        uint256 depositAmount = vm.envOr("ORDER_DEPOSIT_AMOUNT", uint256(0));
        uint256 amount = vm.envUint("ORDER_AMOUNT");
        if (amount == 0) revert ZeroOrderAmount();
        bool isBaseToQuote = vm.envOr("ORDER_IS_BASE_TO_QUOTE", false);
        uint160 sqrtPriceLimitX96 = uint160(vm.envOr("ORDER_SQRT_PRICE_LIMIT_X96", uint256(0)));

        vm.startBroadcast(pk);
        if (depositAmount > 0) {
            usdc.approve(address(vault), type(uint256).max);
            vault.deposit(depositAmount);
        }

        (int256 base, int256 quote) = clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: isBaseToQuote, amount: amount, sqrtPriceLimitX96: sqrtPriceLimitX96, hookData: bytes("")
            })
        );
        vm.stopBroadcast();

        console2.log("===== User Perp Order Executed =====");
        console2.log("Trader:", trader);
        console2.log("Deposit amount raw:", depositAmount);
        console2.log("Deposit amount:", FormatUtils.formatUsdcRaw(depositAmount), "USDC");
        console2.log("isBaseToQuote:", isBaseToQuote);
        console2.log("Order amount:", amount);
        console2.log("Order amount:", FormatUtils.formatX18(amount));
        console2.log("Base delta:", base);
        console2.log("Base delta:", FormatUtils.formatSignedX18(base));
        console2.log("Quote delta:", quote);
        console2.log("Quote delta:", FormatUtils.formatSignedX18(quote), "vUSDC");
    }
}
