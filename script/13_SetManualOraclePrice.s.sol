// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ManualPriceOracle} from "../src/ManualPriceOracle.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract SetManualOraclePriceUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address oracleAddress = vm.envAddress("PRICE_ORACLE");
        uint256 newPriceX18 = vm.envUint("NEW_ORACLE_PRICE_X18");

        vm.startBroadcast(pk);
        ManualPriceOracle(oracleAddress).setPriceX18(newPriceX18);
        vm.stopBroadcast();

        console2.log("Manual oracle updated:", oracleAddress);
        console2.log("new priceX18:", newPriceX18);
    }
}
