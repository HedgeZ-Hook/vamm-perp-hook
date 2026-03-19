// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IVault} from "../src/interfaces/IVault.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract WithdrawLpCollateralUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error ZeroTokenId();

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);
        IVault vault = IVault(vm.envAddress("VAULT"));
        uint256 tokenId = vm.envUint("LP_TOKEN_ID");
        if (tokenId == 0) revert ZeroTokenId();

        vm.startBroadcast(pk);
        (uint256 ethAmount, uint256 usdcAmount) = vault.withdrawLP(tokenId);
        vm.stopBroadcast();

        console2.log("===== LP Collateral Withdrawn =====");
        console2.log("Trader:", trader);
        console2.log("LP tokenId:", tokenId);
        console2.log("ETH received:", ethAmount);
        console2.log("USDC raw received:", usdcAmount);
    }
}
