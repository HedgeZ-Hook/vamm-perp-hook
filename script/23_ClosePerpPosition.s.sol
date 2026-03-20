// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {FormatUtils} from "./base/FormatUtils.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract ClosePerpPositionUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);
        IClearingHouse clearingHouse = IClearingHouse(vm.envAddress("CLEARING_HOUSE"));
        uint256 closeAmount = vm.envOr("CLOSE_AMOUNT", uint256(0));
        uint160 sqrtPriceLimitX96 = uint160(vm.envOr("CLOSE_SQRT_PRICE_LIMIT_X96", uint256(0)));

        vm.startBroadcast(pk);
        (int256 base, int256 quote) = clearingHouse.closePosition(closeAmount, sqrtPriceLimitX96, bytes(""));
        vm.stopBroadcast();

        console2.log("===== Perp Position Closed =====");
        console2.log("Trader:", trader);
        console2.log("Close amount:", closeAmount);
        console2.log("Close amount:", FormatUtils.formatX18(closeAmount));
        console2.log("Base delta:", base);
        console2.log("Base delta:", FormatUtils.formatSignedX18(base));
        console2.log("Quote delta:", quote);
        console2.log("Quote delta:", FormatUtils.formatSignedX18(quote), "vUSDC");
    }
}
