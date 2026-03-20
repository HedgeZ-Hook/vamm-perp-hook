// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IVault} from "../src/interfaces/IVault.sol";
import {FormatUtils} from "./base/FormatUtils.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract DepositLpCollateralUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error ZeroTokenId();

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);
        IVault vault = IVault(vm.envAddress("VAULT"));
        address positionManager = vm.envAddress("POSITION_MANAGER");
        uint256 tokenId = vm.envUint("LP_TOKEN_ID");
        if (tokenId == 0) revert ZeroTokenId();

        vm.startBroadcast(pk);
        IERC721(positionManager).approve(address(vault), tokenId);
        vault.depositLP(tokenId);
        vm.stopBroadcast();

        console2.log("===== LP Collateral Deposited =====");
        console2.log("Trader:", trader);
        console2.log("Vault:", address(vault));
        console2.log("LP tokenId:", tokenId);
        console2.log("LP collateral value:", FormatUtils.formatX18(vault.getLPCollateralValue(trader)), "USD");
    }
}
