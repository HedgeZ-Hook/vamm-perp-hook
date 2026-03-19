// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {InitPoolsBootstrapBase} from "./11.0_InitPoolsBootstrapBase.s.sol";

contract BootstrapSpotPoolUnichainSepolia is InitPoolsBootstrapBase {
    using PoolIdLibrary for PoolKey;

    function run() external {
        _assertChain();

        uint256 pk = vm.envUint("PRIVATE_KEY");
        Inputs memory inp = _loadInputs(pk);
        (, PoolKey memory spotPoolKey) = _buildPoolKeys(inp);

        vm.startBroadcast(pk);
        uint128 liquidityMinted = _mintSpotIfNeeded(inp, spotPoolKey);
        vm.stopBroadcast();

        console2.log("===== Spot Bootstrap Done =====");
        console2.log("Spot PoolId:", uint256(PoolId.unwrap(spotPoolKey.toId())));
        console2.log("Liquidity minted:", uint256(liquidityMinted));
        console2.log("Spot bootstrap liquidity env:", uint256(inp.spotBootstrapLiquidity));
        console2.log("Spot bootstrap ETH amount:", inp.spotBootstrapNativeAmount);
        console2.log("Spot bootstrap USDC amount:", inp.spotBootstrapQuoteAmount);
    }
}
