// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {LiquidityController} from "../src/LiquidityController.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract SetLiquidityControllerParamsUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);

    struct Inputs {
        uint256 pk;
        LiquidityController controller;
        uint24 deadbandBps;
        uint24 maxRepriceBpsPerUpdate;
        uint256 maxAmountInPerUpdate;
        uint128 minVammLiquidity;
    }

    function run() external {
        Inputs memory inp = loadInputsFromEnv();
        _execute(inp);
    }

    function loadInputsFromEnv() public view returns (Inputs memory inp) {
        _assertChain();

        inp.pk = vm.envUint("PRIVATE_KEY");
        inp.controller = LiquidityController(vm.envAddress("LIQUIDITY_CONTROLLER"));
        inp.deadbandBps = uint24(vm.envUint("LC_DEADBAND_BPS"));
        inp.maxRepriceBpsPerUpdate = uint24(vm.envUint("LC_MAX_REPRICE_BPS"));
        inp.maxAmountInPerUpdate = vm.envUint("LC_MAX_AMOUNT_IN");
        inp.minVammLiquidity = uint128(vm.envUint("LC_MIN_VAMM_LIQUIDITY"));
    }

    function execute(
        uint256 pk,
        LiquidityController controller,
        uint24 deadbandBps,
        uint24 maxRepriceBpsPerUpdate,
        uint256 maxAmountInPerUpdate,
        uint128 minVammLiquidity
    ) external {
        _assertChain();

        Inputs memory inp = Inputs({
            pk: pk,
            controller: controller,
            deadbandBps: deadbandBps,
            maxRepriceBpsPerUpdate: maxRepriceBpsPerUpdate,
            maxAmountInPerUpdate: maxAmountInPerUpdate,
            minVammLiquidity: minVammLiquidity
        });
        _execute(inp);
    }

    function _assertChain() internal view {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }
    }

    function _execute(Inputs memory inp) internal {
        uint24 oldDeadband = inp.controller.deadbandBps();
        uint24 oldMaxReprice = inp.controller.maxRepriceBpsPerUpdate();
        uint256 oldMaxAmountIn = inp.controller.maxAmountInPerUpdate();
        uint128 oldMinLiquidity = inp.controller.minVammLiquidity();

        vm.startBroadcast(inp.pk);
        inp.controller
            .setParams(inp.deadbandBps, inp.maxRepriceBpsPerUpdate, inp.maxAmountInPerUpdate, inp.minVammLiquidity);
        vm.stopBroadcast();

        console2.log("===== LiquidityController Params Updated =====");
        console2.log("Controller:", address(inp.controller));
        console2.log("deadbandBps:", oldDeadband, "->", inp.deadbandBps);
        console2.log("maxRepriceBpsPerUpdate:", oldMaxReprice, "->", inp.maxRepriceBpsPerUpdate);
        console2.log("maxAmountInPerUpdate:", oldMaxAmountIn, "->", inp.maxAmountInPerUpdate);
        console2.log("minVammLiquidity:", uint256(oldMinLiquidity), "->", uint256(inp.minVammLiquidity));
    }
}
