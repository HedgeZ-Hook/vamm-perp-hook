// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {InitPoolsBootstrapBase} from "./11.0_InitPoolsBootstrapBase.s.sol";

contract ApproveBootstrapTokensUnichainSepolia is InitPoolsBootstrapBase {
    function run() external {
        _assertChain();

        uint256 pk = vm.envUint("PRIVATE_KEY");
        Inputs memory inp = _loadInputs(pk);

        vm.startBroadcast(pk);
        _approveForPosm(inp);
        vm.stopBroadcast();

        console2.log("===== Bootstrap Approvals Done =====");
        console2.log("Deployer:", inp.deployer);
        console2.log("vETH:", inp.veth);
        console2.log("vUSDC:", inp.vusdc);
        console2.log("USDC:", inp.usdc);
    }
}
