// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVault} from "../src/interfaces/IVault.sol";
import {FormatUtils} from "./base/FormatUtils.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract DepositVaultCollateralUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error ZeroAmount();

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);
        IERC20 usdc = IERC20(vm.envAddress("USDC"));
        IVault vault = IVault(vm.envAddress("VAULT"));
        uint256 amount = vm.envUint("DEPOSIT_AMOUNT");
        if (amount == 0) revert ZeroAmount();

        vm.startBroadcast(pk);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount);
        vm.stopBroadcast();

        console2.log("===== Vault Collateral Deposited =====");
        console2.log("Trader:", trader);
        console2.log("Amount raw:", amount);
        console2.log("Amount:", FormatUtils.formatUsdcRaw(amount), "USDC");
    }
}
