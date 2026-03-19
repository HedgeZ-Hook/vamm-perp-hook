// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {VirtualToken} from "../src/VirtualToken.sol";

contract DeployScriptRegressionTest is BaseTest {
    function testPerpHookCreate2DeployHasExpectedOwner() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x2121 << 144)
        );

        address expectedOwner = makeAddr("deployer");
        deployCodeTo("PerpHook.sol:PerpHook", abi.encode(poolManager, expectedOwner), flags);
        PerpHook hook = PerpHook(flags);

        assertEq(hook.owner(), expectedOwner);

        VirtualToken veth = new VirtualToken("Virtual ETH", "vETH");
        VirtualToken vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        (Currency currency0, Currency currency1) = address(veth) < address(vusdc)
            ? (Currency.wrap(address(veth)), Currency.wrap(address(vusdc)))
            : (Currency.wrap(address(vusdc)), Currency.wrap(address(veth)));
        PoolKey memory vammPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));

        vm.prank(expectedOwner);
        hook.registerVAMMPool(vammPoolKey, address(veth), address(vusdc));
    }
}
