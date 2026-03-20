// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Vault} from "../src/Vault.sol";
import {FormatUtils} from "./base/FormatUtils.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract WithdrawVaultCollateralUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error NoWithdrawableCollateral(address trader);

    struct Inputs {
        uint256 pk;
        address trader;
        Vault vault;
        uint256 requestedAmount;
    }

    function run() external {
        Inputs memory inp = loadInputsFromEnv();
        _execute(inp);
    }

    function loadInputsFromEnv() public view returns (Inputs memory inp) {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        inp.pk = vm.envUint("PRIVATE_KEY");
        inp.trader = vm.addr(inp.pk);
        inp.vault = Vault(payable(vm.envAddress("VAULT")));
        inp.requestedAmount = vm.envOr("WITHDRAW_AMOUNT", uint256(0));
    }

    function execute(uint256 pk, Vault vault, uint256 requestedAmount) external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        Inputs memory inp = Inputs({pk: pk, trader: vm.addr(pk), vault: vault, requestedAmount: requestedAmount});
        _execute(inp);
    }

    function _execute(Inputs memory inp) internal {
        uint8 usdcDecimals = IERC20Metadata(address(inp.vault.usdc())).decimals();
        uint256 scale = 10 ** (18 - usdcDecimals);

        int256 internalBalanceX18 = inp.vault.usdcBalance(inp.trader);
        int256 freeCollateralX18 = inp.vault.getFreeCollateral(inp.trader);

        uint256 withdrawableRaw = _toRawWithdrawable(internalBalanceX18, freeCollateralX18, scale);
        if (inp.requestedAmount != 0 && inp.requestedAmount < withdrawableRaw) {
            withdrawableRaw = inp.requestedAmount;
        }
        if (withdrawableRaw == 0) revert NoWithdrawableCollateral(inp.trader);

        vm.startBroadcast(inp.pk);
        inp.vault.withdraw(withdrawableRaw);
        vm.stopBroadcast();

        console2.log("===== Vault Withdraw Done =====");
        console2.log("Trader:", inp.trader);
        console2.log("Withdraw amount raw:", withdrawableRaw);
        console2.log("Withdraw amount:", FormatUtils.formatUsdcRaw(withdrawableRaw), "USDC");
        console2.log("Internal balance x18 before:", uint256(internalBalanceX18 > 0 ? internalBalanceX18 : int256(0)));
        console2.log(
            "Internal balance before:",
            FormatUtils.formatX18(uint256(internalBalanceX18 > 0 ? internalBalanceX18 : int256(0))),
            "USD"
        );
        console2.log("Free collateral x18 before:", uint256(freeCollateralX18 > 0 ? freeCollateralX18 : int256(0)));
        console2.log(
            "Free collateral before:",
            FormatUtils.formatX18(uint256(freeCollateralX18 > 0 ? freeCollateralX18 : int256(0))),
            "USD"
        );
    }

    function _toRawWithdrawable(int256 internalBalanceX18, int256 freeCollateralX18, uint256 scale)
        internal
        pure
        returns (uint256)
    {
        if (internalBalanceX18 <= 0 || freeCollateralX18 <= 0) return 0;

        uint256 balanceX18 = uint256(internalBalanceX18);
        uint256 freeX18 = uint256(freeCollateralX18);
        uint256 withdrawableX18 = balanceX18 < freeX18 ? balanceX18 : freeX18;
        return withdrawableX18 / scale;
    }
}
