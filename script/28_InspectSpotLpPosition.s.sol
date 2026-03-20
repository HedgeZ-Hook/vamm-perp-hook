// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IVault} from "../src/interfaces/IVault.sol";
import {LPValuation} from "../src/libraries/LPValuation.sol";
import {FormatUtils} from "./base/FormatUtils.sol";
import {PerpMath} from "../src/libraries/PerpMath.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract InspectSpotLpPositionUnichainSepolia is Script {
    using PositionInfoLibrary for PositionInfo;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error InvalidChain(uint256 actual, uint256 expected);
    error ZeroTokenId();

    struct PositionSnapshot {
        address owner;
        uint128 positionLiquidity;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 poolLiquidity;
        uint256 spotPriceX18;
        uint256 markPriceX18;
        uint256 ethAmount;
        uint256 usdcAmountX18;
        uint256 valueX18;
    }

    function run() external view {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        IPositionManager positionManager = IPositionManager(vm.envAddress("POSITION_MANAGER"));
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        IVault vault = IVault(vm.envAddress("VAULT"));
        address usdc = vm.envAddress("USDC");

        uint256 tokenId = vm.envUint("LP_TOKEN_ID");
        if (tokenId == 0) revert ZeroTokenId();

        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        PositionSnapshot memory snap;
        snap.owner = IERC721(address(positionManager)).ownerOf(tokenId);
        snap.positionLiquidity = positionManager.getPositionLiquidity(tokenId);
        snap.markPriceX18 = vault.getMarkPriceX18();
        (snap.sqrtPriceX96, snap.tick,,) = poolManager.getSlot0(key.toId());
        snap.poolLiquidity = poolManager.getLiquidity(key.toId());
        snap.spotPriceX18 = _spotPriceX18(snap.sqrtPriceX96);

        bool isEthToken0 = Currency.unwrap(key.currency0) == address(0);
        (snap.valueX18, snap.ethAmount, snap.usdcAmountX18) = LPValuation.getLPValue(
            snap.sqrtPriceX96,
            info.tickLower(),
            info.tickUpper(),
            snap.positionLiquidity,
            snap.markPriceX18,
            isEthToken0,
            6
        );

        console2.log("===== Spot LP Position =====");
        console2.log("TokenId:", tokenId);
        console2.log("Owner:", snap.owner);
        console2.log("PositionManager:", address(positionManager));
        console2.log("PoolManager:", address(poolManager));
        console2.log("Currency0:", Currency.unwrap(key.currency0));
        console2.log("Currency1:", Currency.unwrap(key.currency1));
        console2.log("Expect USDC:", usdc);
        console2.log("Liquidity:", uint256(snap.positionLiquidity));
        console2.log("TickLower:", int256(info.tickLower()));
        console2.log("TickUpper:", int256(info.tickUpper()));
        _printSnapshot(snap);
    }

    function _printSnapshot(PositionSnapshot memory snap) internal view {
        console2.log("Pool sqrtPriceX96:", uint256(snap.sqrtPriceX96));
        console2.log("Pool tick:", int256(snap.tick));
        console2.log("Pool liquidity:", uint256(snap.poolLiquidity));
        console2.log("Mark price x18:", snap.markPriceX18);
        console2.log("Mark price:", FormatUtils.formatX18(snap.markPriceX18), "USDC/ETH");
        console2.log("Spot price x18:", snap.spotPriceX18);
        console2.log("Spot price:", FormatUtils.formatX18(snap.spotPriceX18), "USDC/ETH");
        console2.log("ETH amount:", snap.ethAmount);
        console2.log("ETH amount:", FormatUtils.formatEth(snap.ethAmount), "ETH");
        console2.log("USDC amount x18:", snap.usdcAmountX18);
        console2.log("USDC amount:", FormatUtils.formatX18(snap.usdcAmountX18), "USDC");
        console2.log("Total LP value x18:", snap.valueX18);
        console2.log("Total LP value:", FormatUtils.formatX18(snap.valueX18), "USD");
    }

    function _spotPriceX18(uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        uint256 priceX96 = PerpMath.formatSqrtPriceX96ToPriceX96(sqrtPriceX96);
        uint256 rawRatioX18 = PerpMath.formatX96ToX10_18(priceX96);
        return FullMath.mulDiv(rawRatioX18, 1e18, 1e6);
    }
}
