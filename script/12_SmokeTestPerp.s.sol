// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {IVault} from "../src/interfaces/IVault.sol";

import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract SmokeTestPerpUnichainSepolia is Script {
    using StateLibrary for IPoolManager;

    error InvalidChain(uint256 actual, uint256 expected);
    error VammPoolNotInitialized(bytes32 poolId);
    error VammPoolNoLiquidity(bytes32 poolId);

    struct Inputs {
        uint256 pk;
        address trader;
        address usdc;
        IVault vault;
        IClearingHouse clearingHouse;
        uint256 depositAmount;
        uint256 openAmount;
    }

    function run() external {
        Inputs memory inp = loadInputsFromEnv();
        _execute(inp);
    }

    function loadInputsFromEnv() public view returns (Inputs memory inp) {
        _assertChain();

        inp.pk = vm.envUint("PRIVATE_KEY");
        inp.trader = vm.addr(inp.pk);
        inp.usdc = vm.envAddress("USDC");
        inp.vault = IVault(vm.envAddress("VAULT"));
        inp.clearingHouse = IClearingHouse(vm.envAddress("CLEARING_HOUSE"));

        uint8 usdcDecimals = IERC20Metadata(inp.usdc).decimals();
        uint256 defaultDepositAmount = 1_000 * (10 ** usdcDecimals);
        inp.depositAmount = vm.envOr("SMOKE_DEPOSIT_AMOUNT", defaultDepositAmount);
        inp.openAmount = vm.envOr("SMOKE_OPEN_AMOUNT", uint256(1e18));
    }

    function execute(
        uint256 pk,
        address usdc,
        IVault vault,
        IClearingHouse clearingHouse,
        uint256 depositAmount,
        uint256 openAmount
    ) external {
        _assertChain();
        Inputs memory inp = Inputs({
            pk: pk,
            trader: vm.addr(pk),
            usdc: usdc,
            vault: vault,
            clearingHouse: clearingHouse,
            depositAmount: depositAmount,
            openAmount: openAmount
        });
        _execute(inp);
    }

    function _assertChain() internal view {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }
    }

    function _execute(Inputs memory inp) internal {
        IPoolManager poolManager = inp.clearingHouse.poolManager();
        PoolId vammPoolId = inp.clearingHouse.vammPoolId();
        bytes32 vammPoolIdRaw = PoolId.unwrap(vammPoolId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(vammPoolId);
        if (sqrtPriceX96 == 0) revert VammPoolNotInitialized(vammPoolIdRaw);
        if (poolManager.getLiquidity(vammPoolId) == 0) revert VammPoolNoLiquidity(vammPoolIdRaw);

        vm.startBroadcast(inp.pk);

        IERC20(inp.usdc).approve(address(inp.vault), type(uint256).max);
        inp.vault.deposit(inp.depositAmount);

        inp.clearingHouse
            .openPosition(
                IClearingHouse.OpenPositionParams({
                    isBaseToQuote: false, amount: inp.openAmount, sqrtPriceLimitX96: 0, hookData: bytes("")
                })
            );

        inp.clearingHouse.closePosition(0, 0, bytes(""));

        vm.stopBroadcast();

        int256 accountValue = inp.vault.getAccountValue(inp.trader);
        int256 freeCollateral = inp.vault.getFreeCollateral(inp.trader);

        console2.log("===== Smoke Test Completed =====");
        console2.log("Trader:", inp.trader);
        console2.log("Deposit amount:", inp.depositAmount);
        console2.log("Open amount:", inp.openAmount);
        console2.log("Account value:", accountValue);
        console2.log("Free collateral:", freeCollateral);
    }
}
