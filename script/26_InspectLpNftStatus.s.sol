// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract InspectLpNftStatusUnichainSepolia is Script {
    using PositionInfoLibrary for PositionInfo;

    error InvalidChain(uint256 actual, uint256 expected);
    error ZeroTokenId();

    function run() external view {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        IPositionManager positionManager = IPositionManager(vm.envAddress("POSITION_MANAGER"));
        uint256 tokenId = vm.envUint("LP_TOKEN_ID");
        if (tokenId == 0) revert ZeroTokenId();

        console2.log("===== LP NFT Status =====");
        console2.log("TokenId:", tokenId);
        console2.log("Owner:", IERC721(address(positionManager)).ownerOf(tokenId));
        console2.log("Liquidity:", uint256(positionManager.getPositionLiquidity(tokenId)));

        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        console2.log("Currency0:", Currency.unwrap(key.currency0));
        console2.log("Currency1:", Currency.unwrap(key.currency1));
        console2.log("Fee:", key.fee);
        console2.log("Tick spacing:", uint24(uint24(int24(key.tickSpacing))));
        console2.log("TickLower:", int256(info.tickLower()));
        console2.log("TickUpper:", int256(info.tickUpper()));
        console2.log("Has subscriber:", info.hasSubscriber());
    }
}
