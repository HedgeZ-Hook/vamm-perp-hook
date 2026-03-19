// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IVault} from "../src/interfaces/IVault.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract DecreaseLpCollateralUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error ZeroTokenId();
    error ZeroLiquidity();

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);
        IVault vault = IVault(vm.envAddress("VAULT"));
        uint256 tokenId = vm.envUint("LP_TOKEN_ID");
        uint128 liquidityToRemove = uint128(vm.envUint("LP_LIQUIDITY_TO_REMOVE"));
        if (tokenId == 0) revert ZeroTokenId();
        if (liquidityToRemove == 0) revert ZeroLiquidity();

        vm.startBroadcast(pk);
        (uint256 ethAmount, uint256 usdcAmount) = vault.decreaseLP(tokenId, liquidityToRemove);
        vm.stopBroadcast();

        console2.log("===== LP Collateral Decreased =====");
        console2.log("Trader:", trader);
        console2.log("LP tokenId:", tokenId);
        console2.log("Liquidity removed:", uint256(liquidityToRemove));
        console2.log("ETH received:", ethAmount);
        console2.log("USDC raw received:", usdcAmount);
    }
}
