// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {InsuranceFund} from "../src/InsuranceFund.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract FundInsuranceFundUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error ZeroAmount();

    struct Inputs {
        uint256 pk;
        address sender;
        InsuranceFund insuranceFund;
        IERC20 usdc;
        uint256 amount;
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
        inp.sender = vm.addr(inp.pk);
        inp.insuranceFund = InsuranceFund(vm.envAddress("INSURANCE_FUND"));
        inp.usdc = IERC20(vm.envAddress("USDC"));
        inp.amount = vm.envUint("INSURANCE_FUND_AMOUNT");
    }

    function execute(uint256 pk, InsuranceFund insuranceFund, IERC20 usdc, uint256 amount) external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        Inputs memory inp =
            Inputs({pk: pk, sender: vm.addr(pk), insuranceFund: insuranceFund, usdc: usdc, amount: amount});
        _execute(inp);
    }

    function _execute(Inputs memory inp) internal {
        if (inp.amount == 0) revert ZeroAmount();

        vm.startBroadcast(inp.pk);
        inp.usdc.transfer(address(inp.insuranceFund), inp.amount);
        vm.stopBroadcast();

        console2.log("===== InsuranceFund Funded =====");
        console2.log("Sender:", inp.sender);
        console2.log("InsuranceFund:", address(inp.insuranceFund));
        console2.log("USDC:", address(inp.usdc));
        console2.log("Amount raw:", inp.amount);
    }
}
