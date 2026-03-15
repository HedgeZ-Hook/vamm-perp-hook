// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {IVault} from "../src/interfaces/IVault.sol";

import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract SmokeTestPerpUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);

        address usdc = vm.envAddress("USDC");
        IVault vault = IVault(vm.envAddress("VAULT"));
        IClearingHouse clearingHouse = IClearingHouse(vm.envAddress("CLEARING_HOUSE"));

        uint256 depositAmount = vm.envOr("SMOKE_DEPOSIT_AMOUNT", uint256(1_000e18));
        uint256 openAmount = vm.envOr("SMOKE_OPEN_AMOUNT", uint256(1e18));

        vm.startBroadcast(pk);

        IERC20(usdc).approve(address(vault), type(uint256).max);
        vault.deposit(depositAmount);

        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: openAmount, sqrtPriceLimitX96: 0, hookData: bytes("")
            })
        );

        clearingHouse.closePosition(0, 0, bytes(""));

        vm.stopBroadcast();

        int256 accountValue = vault.getAccountValue(trader);
        int256 freeCollateral = vault.getFreeCollateral(trader);

        console2.log("===== Smoke Test Completed =====");
        console2.log("Trader:", trader);
        console2.log("Deposit amount:", depositAmount);
        console2.log("Open amount:", openAmount);
        console2.log("Account value:", accountValue);
        console2.log("Free collateral:", freeCollateral);
    }
}
