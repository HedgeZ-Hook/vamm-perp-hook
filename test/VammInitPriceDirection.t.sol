// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {VirtualToken} from "../src/VirtualToken.sol";

contract VammInitPriceDirectionTest is BaseTest {
    using EasyPosm for IPositionManager;

    uint256 internal constant Q192 = 2 ** 192;

    PerpHook internal hook;
    VirtualToken internal veth;
    VirtualToken internal vusdc;
    PoolKey internal vammPoolKey;

    function setUp() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x7777 << 144)
        );
        deployCodeTo("PerpHook.sol:PerpHook", abi.encode(poolManager, address(this)), flags);
        hook = PerpHook(flags);
        hook.setClearingHouse(address(this));
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);

        address vethAddr = address(0x2000000000000000000000000000000000000002);
        address vusdcAddr = address(0x1000000000000000000000000000000000000001);
        deployCodeTo("VirtualToken.sol:VirtualToken", abi.encode("Virtual ETH", "vETH"), vethAddr);
        deployCodeTo("VirtualToken.sol:VirtualToken", abi.encode("Virtual USDC", "vUSDC"), vusdcAddr);
        veth = VirtualToken(vethAddr);
        vusdc = VirtualToken(vusdcAddr);

        assertTrue(address(veth) > address(vusdc));

        veth.mintMaximumTo(address(this));
        vusdc.mintMaximumTo(address(this));
        _allowVirtualToken(veth);
        _allowVirtualToken(vusdc);

        (Currency currency0, Currency currency1) = _orderedCurrencies(address(veth), address(vusdc));
        vammPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        hook.registerVAMMPool(vammPoolKey, address(veth), address(vusdc));

        uint160 initSqrtPriceX96 = _vammInitSqrtPriceX96(vammPoolKey, 2_300e18);
        poolManager.initialize(vammPoolKey, initSqrtPriceX96);
        _mintFullRange(vammPoolKey, initSqrtPriceX96, 1_000_000e18);
    }

    function testVammInitPrice2300EthUsdcIsNotReversed() public {
        assertApproxEqAbs(hook.getVammPriceX18(), 2_300e18, 1e10);

        uint256 vethBefore = veth.balanceOf(address(this));
        uint256 vusdcBefore = vusdc.balanceOf(address(this));

        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: vammPoolKey,
            hookData: bytes(""),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 vethSpent = vethBefore - veth.balanceOf(address(this));
        uint256 vusdcReceived = vusdc.balanceOf(address(this)) - vusdcBefore;

        assertEq(vethSpent, 5e18);
        assertGt(vusdcReceived, 1_000e18, "vAMM init price is reversed: received too little vUSDC for 5 vETH");
    }

    function _vammInitSqrtPriceX96(PoolKey memory key, uint256 quotePerBaseX18) internal view returns (uint160) {
        uint256 rawPriceX18 = Currency.unwrap(key.currency0) == address(veth) ? quotePerBaseX18 : 1e36 / quotePerBaseX18;
        return _priceX18ToSqrtPriceX96(rawPriceX18, 18, 18);
    }

    function _allowVirtualToken(VirtualToken token) internal {
        token.addWhitelist(address(this));
        token.addWhitelist(address(poolManager));
        token.addWhitelist(address(positionManager));
        token.addWhitelist(address(swapRouter));
        token.addWhitelist(address(permit2));

        token.approve(address(permit2), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token), address(poolManager), type(uint160).max, type(uint48).max);
    }

    function _orderedCurrencies(address tokenA, address tokenB)
        internal
        pure
        returns (Currency currency0, Currency currency1)
    {
        currency0 = Currency.wrap(tokenA);
        currency1 = Currency.wrap(tokenB);
        if (tokenA > tokenB) {
            (currency0, currency1) = (currency1, currency0);
        }
    }

    function _priceX18ToSqrtPriceX96(uint256 priceX18, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        uint256 rawPriceX18 = FullMath.mulDiv(priceX18, 10 ** quoteDecimals, 10 ** baseDecimals);
        uint256 ratioX192 = FullMath.mulDiv(rawPriceX18, Q192, 1e18);
        sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
    }

    function _mintFullRange(PoolKey memory key, uint160 sqrtPriceX96, uint128 liquidityAmount) internal {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp + 1,
            bytes("")
        );
    }
}
