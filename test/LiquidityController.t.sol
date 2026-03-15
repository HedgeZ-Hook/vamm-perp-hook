// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {VirtualToken} from "../src/VirtualToken.sol";
import {LiquidityController} from "../src/LiquidityController.sol";
import {MockPriceOracle} from "./MockPriceOracle.sol";

contract LiquidityControllerTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    PerpHook internal hook;
    LiquidityController internal controller;
    MockPriceOracle internal oracle;
    VirtualToken internal veth;
    VirtualToken internal vusdc;

    PoolKey internal vammPoolKey;
    PoolId internal vammPoolId;

    uint24 internal constant DEADBAND_BPS = 10;
    uint24 internal constant MAX_REPRICE_BPS = 30;
    uint256 internal constant MAX_AMOUNT_IN = 5e18;
    uint128 internal constant MIN_VAMM_LIQUIDITY = 1e18;

    function setUp() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x5555 << 144)
        );
        deployCodeTo("PerpHook.sol:PerpHook", abi.encode(poolManager), flags);
        hook = PerpHook(flags);
        hook.setClearingHouse(makeAddr("ch"));

        veth = new VirtualToken("Virtual ETH", "vETH");
        vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        veth.mintMaximumTo(address(this));
        vusdc.mintMaximumTo(address(this));

        _allowVirtualToken(veth);
        _allowVirtualToken(vusdc);

        (Currency currency0, Currency currency1) = _orderedCurrencies(address(veth), address(vusdc));
        vammPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        vammPoolId = vammPoolKey.toId();

        poolManager.initialize(vammPoolKey, Constants.SQRT_PRICE_1_1);
        hook.registerVAMMPool(vammPoolKey);
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        _mintFullRange(vammPoolKey, 1_000_000e18);

        oracle = new MockPriceOracle(1e18);
        controller = new LiquidityController(
            poolManager,
            swapRouter,
            oracle,
            vammPoolKey,
            0,
            DEADBAND_BPS,
            MAX_REPRICE_BPS,
            MAX_AMOUNT_IN,
            MIN_VAMM_LIQUIDITY
        );
        hook.setLiquidityController(address(controller));

        veth.addWhitelist(address(controller));
        vusdc.addWhitelist(address(controller));

        veth.transfer(address(controller), 100e18);
        vusdc.transfer(address(controller), 100_000e18);

        controller.approveSpender(veth, address(swapRouter), type(uint256).max);
        controller.approveSpender(vusdc, address(swapRouter), type(uint256).max);
    }

    function testUpdateFromOracleIsPermissionless() public {
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        controller.updateFromOracle(); // no-op here because oracle ~= vAMM at setup
    }

    function testNoopWithinDeadband() public {
        uint256 beforePrice = controller.getVammPriceX18();
        oracle.setPriceX18((beforePrice * (10_000 - DEADBAND_BPS)) / 10_000);

        (bool executed,, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();

        assertFalse(executed);
        assertEq(usedAmount, 0);
        assertEq(afterPrice, beforePrice);
    }

    function testUpdateMovesPriceTowardLowerOracle() public {
        uint256 beforePrice = controller.getVammPriceX18();
        oracle.setPriceX18((beforePrice * 80) / 100); // oracle lower than vAMM -> zeroForOne

        (bool executed, bool zeroForOne, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();

        assertTrue(executed);
        assertTrue(zeroForOne);
        assertGt(usedAmount, 0);
        assertLe(usedAmount, MAX_AMOUNT_IN);
        assertLt(afterPrice, beforePrice);
    }

    function testUpdateMovesPriceTowardHigherOracle() public {
        uint256 beforePrice = controller.getVammPriceX18();
        oracle.setPriceX18((beforePrice * 120) / 100); // oracle higher than vAMM -> oneForZero

        (bool executed, bool zeroForOne, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();

        assertTrue(executed);
        assertFalse(zeroForOne);
        assertGt(usedAmount, 0);
        assertLe(usedAmount, MAX_AMOUNT_IN);
        assertGt(afterPrice, beforePrice);
    }

    function testAmountInIsCappedByMaxPerUpdate() public {
        uint256 beforePrice = controller.getVammPriceX18();
        oracle.setPriceX18((beforePrice * 140) / 100);

        (, bool zeroForOne, uint256 usedAmount) = controller.updateFromOracle();
        assertEq(usedAmount, MAX_AMOUNT_IN);
        assertFalse(zeroForOne);
    }

    function testRevertWhenLiquidityBelowFloor() public {
        controller.setParams(DEADBAND_BPS, MAX_REPRICE_BPS, MAX_AMOUNT_IN, type(uint128).max);

        uint256 beforePrice = controller.getVammPriceX18();
        oracle.setPriceX18((beforePrice * 130) / 100);

        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityController.VammLiquidityBelowFloor.selector, uint128(1_000_000e18), type(uint128).max
            )
        );
        controller.updateFromOracle();
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

    function _mintFullRange(PoolKey memory key, uint128 liquidityAmount) internal returns (uint256 tokenId) {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
    }
}
