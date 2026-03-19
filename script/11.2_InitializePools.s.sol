// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {InitPoolsBootstrapBase} from "./11.0_InitPoolsBootstrapBase.s.sol";

contract InitializePoolsUnichainSepolia is InitPoolsBootstrapBase {
    using PoolIdLibrary for PoolKey;

    function run() external {
        _assertChain();

        uint256 pk = vm.envUint("PRIVATE_KEY");
        Inputs memory inp = _loadInputs(pk);
        (PoolKey memory vammPoolKey, PoolKey memory spotPoolKey) = _buildPoolKeys(inp);

        vm.startBroadcast(pk);
        _initializeIfNeeded(inp.poolManager, vammPoolKey, _vammInitSqrtPriceX96(inp, vammPoolKey));
        _initializeIfNeeded(inp.poolManager, spotPoolKey, _spotInitSqrtPriceX96(inp));
        vm.stopBroadcast();

        console2.log("===== Pools Initialized =====");
        console2.log("vAMM PoolId:", uint256(PoolId.unwrap(vammPoolKey.toId())));
        console2.log("Spot PoolId:", uint256(PoolId.unwrap(spotPoolKey.toId())));
    }
}
