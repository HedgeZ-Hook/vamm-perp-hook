// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {VirtualToken} from "../src/VirtualToken.sol";
import {LiquidityController} from "../src/LiquidityController.sol";
import {MockPriceOracle} from "./MockPriceOracle.sol";

contract LiquidityControllerTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant REPRICED_SIG = keccak256("Repriced(bool,bool,uint256,uint256,uint256,uint256)");
    uint256 internal constant Q192 = 2 ** 192;

    PerpHook internal hook;
    LiquidityController internal controller;
    MockPriceOracle internal oracle;
    VirtualToken internal veth;
    VirtualToken internal vusdc;

    PoolKey internal vammPoolKey;
    PoolId internal vammPoolId;

    uint24 internal constant DEADBAND_BPS = 10;
    uint24 internal constant MAX_REPRICE_BPS = 1_000;
    uint256 internal constant MAX_AMOUNT_IN = 500e18;
    uint128 internal constant MIN_VAMM_LIQUIDITY = 1_000e18;
    uint256 internal constant INITIAL_PRICE_X18 = 2_300e18;
    uint128 internal constant VAMM_BOOTSTRAP_LIQUIDITY = 1_000e18;
    uint256 internal constant LC_VETH_INVENTORY = 50_000e18;
    uint256 internal constant LC_VUSDC_INVENTORY = 150_000_000e18;
    uint256 internal constant PRICE_TOLERANCE_X18 = 2e7;

    function setUp() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x5555 << 144)
        );
        deployCodeTo("PerpHook.sol:PerpHook", abi.encode(poolManager, address(this)), flags);
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

        uint160 initialSqrtPriceX96 = _vammInitSqrtPriceX96(INITIAL_PRICE_X18);
        poolManager.initialize(vammPoolKey, initialSqrtPriceX96);
        hook.registerVAMMPool(vammPoolKey, address(veth), address(vusdc));
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        _mintFullRange(vammPoolKey, initialSqrtPriceX96, VAMM_BOOTSTRAP_LIQUIDITY);

        oracle = new MockPriceOracle(INITIAL_PRICE_X18);
        controller = new LiquidityController(
            poolManager,
            swapRouter,
            oracle,
            vammPoolKey,
            address(veth),
            address(vusdc),
            0,
            DEADBAND_BPS,
            MAX_REPRICE_BPS,
            MAX_AMOUNT_IN,
            MIN_VAMM_LIQUIDITY
        );
        hook.setLiquidityController(address(controller));

        veth.addWhitelist(address(controller));
        vusdc.addWhitelist(address(controller));

        veth.transfer(address(controller), LC_VETH_INVENTORY);
        vusdc.transfer(address(controller), LC_VUSDC_INVENTORY);

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

        (bool executed,, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();

        assertTrue(executed);
        assertGt(usedAmount, 0);
        assertLe(usedAmount, MAX_AMOUNT_IN);
        assertLt(afterPrice, beforePrice);
    }

    function testUpdateMovesPriceTowardHigherOracle() public {
        uint256 beforePrice = controller.getVammPriceX18();
        oracle.setPriceX18((beforePrice * 120) / 100); // oracle higher than vAMM -> oneForZero

        (bool executed,, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();

        assertTrue(executed);
        assertGt(usedAmount, 0);
        assertLe(usedAmount, MAX_AMOUNT_IN);
        assertGt(afterPrice, beforePrice);
    }

    function testUpdateDoesNotOvershootNearHigherOracle() public {
        controller.setParams(DEADBAND_BPS, 1_000, 1_000e18, MIN_VAMM_LIQUIDITY);

        uint256 beforePrice = controller.getVammPriceX18();
        uint256 targetOracle = (beforePrice * 101) / 100; // +1%
        oracle.setPriceX18(targetOracle);

        (bool executed,, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();

        assertTrue(executed);
        assertGt(usedAmount, 0);
        assertGe(afterPrice, beforePrice);
        assertLe(afterPrice, targetOracle + PRICE_TOLERANCE_X18);
    }

    function testUpdateDoesNotOvershootNearLowerOracle() public {
        controller.setParams(DEADBAND_BPS, 1_000, 100e18, MIN_VAMM_LIQUIDITY);

        uint256 beforePrice = controller.getVammPriceX18();
        uint256 targetOracle = (beforePrice * 99) / 100; // -1%
        oracle.setPriceX18(targetOracle);

        (bool executed,, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();

        assertTrue(executed);
        assertGt(usedAmount, 0);
        assertLe(afterPrice, beforePrice);
        assertGe(afterPrice, targetOracle);
    }

    function testUpdateFarOracleRespectsBoundWithoutOvershootingBound() public {
        controller.setParams(DEADBAND_BPS, 300, 1_000e18, MIN_VAMM_LIQUIDITY);

        uint256 beforePrice = controller.getVammPriceX18();
        oracle.setPriceX18((beforePrice * 130) / 100);
        (bool executed,, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();
        uint256 upperBound = (beforePrice * (10_000 + 300)) / 10_000;

        assertTrue(executed);
        assertGt(usedAmount, 0);
        assertLe(afterPrice, upperBound + PRICE_TOLERANCE_X18);
        assertGt(afterPrice, beforePrice);
    }

    function testRepeatedUpdatesConvergeIntoDeadbandForNearHigherOracle() public {
        controller.setParams(DEADBAND_BPS, 1_000, 1_000e18, MIN_VAMM_LIQUIDITY);

        uint256 initialPrice = controller.getVammPriceX18();
        uint256 targetOracle = (initialPrice * 1005) / 1000; // +0.5%
        oracle.setPriceX18(targetOracle);

        uint256 priceAfter;
        uint256 spreadBps;
        for (uint256 i = 0; i < 3; ++i) {
            controller.updateFromOracle();
            priceAfter = controller.getVammPriceX18();
            spreadBps = _spreadBps(priceAfter, targetOracle);
            if (spreadBps <= DEADBAND_BPS) break;
        }

        assertLe(spreadBps, DEADBAND_BPS);
        assertLe(priceAfter, targetOracle + PRICE_TOLERANCE_X18);
        assertGe(priceAfter, initialPrice);
    }

    function testRepricedEventMatchesStateAndStaysWithinOracleWhenOracleInBound() public {
        controller.setParams(DEADBAND_BPS, 1_000, 100e18, MIN_VAMM_LIQUIDITY);

        uint256 beforePrice = controller.getVammPriceX18();
        uint256 targetOracle = (beforePrice * 995) / 1000; // -0.5%
        oracle.setPriceX18(targetOracle);

        vm.recordLogs();
        controller.updateFromOracle();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 amountIn, uint256 oraclePriceX18, uint256 prePriceX18, uint256 postPriceX18) = _lastRepricedEvent(logs);
        uint256 currentPrice = controller.getVammPriceX18();

        assertGt(amountIn, 0);
        assertEq(oraclePriceX18, targetOracle);
        assertEq(prePriceX18, beforePrice);
        assertEq(postPriceX18, currentPrice);
        assertGe(postPriceX18 + PRICE_TOLERANCE_X18, targetOracle);
        assertLe(postPriceX18, beforePrice);
    }

    function testFuzzUpdateHigherOracleWithinBound(uint24 oracleMoveBps, uint24 configuredDeadbandBps) public {
        configuredDeadbandBps = uint24(bound(configuredDeadbandBps, 1, 10));
        oracleMoveBps = uint24(bound(oracleMoveBps, configuredDeadbandBps + 1, 50));

        controller.setParams(configuredDeadbandBps, 100, 10_000e18, MIN_VAMM_LIQUIDITY);

        uint256 beforePrice = controller.getVammPriceX18();
        uint256 oraclePrice = (beforePrice * (10_000 + oracleMoveBps)) / 10_000;
        uint256 spreadBefore = _spreadBps(beforePrice, oraclePrice);
        oracle.setPriceX18(oraclePrice);

        (bool executed,, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();
        uint256 spreadAfter = _spreadBps(afterPrice, oraclePrice);

        if (!executed) {
            assertEq(usedAmount, 0);
            assertEq(afterPrice, beforePrice);
            return;
        }

        assertGt(usedAmount, 0);
        assertGe(afterPrice, beforePrice);
        assertLe(afterPrice, oraclePrice + PRICE_TOLERANCE_X18);
        assertLt(spreadAfter, spreadBefore);
    }

    function testFuzzUpdateLowerOracleWithinBound(uint24 oracleMoveBps, uint24 configuredDeadbandBps) public {
        configuredDeadbandBps = uint24(bound(configuredDeadbandBps, 1, 10));
        oracleMoveBps = uint24(bound(oracleMoveBps, configuredDeadbandBps + 1, 25));

        controller.setParams(configuredDeadbandBps, 100, 100e18, MIN_VAMM_LIQUIDITY);

        uint256 beforePrice = controller.getVammPriceX18();
        uint256 oraclePrice = (beforePrice * (10_000 - oracleMoveBps)) / 10_000;
        uint256 spreadBefore = _spreadBps(beforePrice, oraclePrice);
        oracle.setPriceX18(oraclePrice);

        (bool executed,, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();
        uint256 spreadAfter = _spreadBps(afterPrice, oraclePrice);

        if (!executed) {
            assertEq(usedAmount, 0);
            assertEq(afterPrice, beforePrice);
            return;
        }

        assertGt(usedAmount, 0);
        assertLe(afterPrice, beforePrice);
        assertGe(afterPrice + PRICE_TOLERANCE_X18, oraclePrice);
        assertLt(spreadAfter, spreadBefore);
    }

    function testFuzzUpdateHigherOracleOutsideBoundRespectsUpperBound(uint24 oracleMoveBps) public {
        oracleMoveBps = uint24(bound(oracleMoveBps, 31, 500));

        controller.setParams(DEADBAND_BPS, 30, 10_000e18, MIN_VAMM_LIQUIDITY);

        uint256 beforePrice = controller.getVammPriceX18();
        uint256 oraclePrice = (beforePrice * (10_000 + oracleMoveBps)) / 10_000;
        uint256 upperBound = (beforePrice * 10_030) / 10_000;
        oracle.setPriceX18(oraclePrice);

        (bool ok, bytes memory returnData) = address(controller).call(abi.encodeCall(controller.updateFromOracle, ()));
        if (!ok) {
            assertEq(bytes4(returnData), LiquidityController.MaxRepriceExceeded.selector);
            return;
        }

        (bool executed,, uint256 usedAmount) = abi.decode(returnData, (bool, bool, uint256));
        uint256 afterPrice = controller.getVammPriceX18();

        assertTrue(executed);
        assertGt(usedAmount, 0);
        assertGt(afterPrice, beforePrice);
        assertLe(afterPrice, upperBound + PRICE_TOLERANCE_X18);
        assertLe(afterPrice, oraclePrice + PRICE_TOLERANCE_X18);
    }

    function testFuzzUpdateLowerOracleOutsideBoundRespectsLowerBound(uint24 oracleMoveBps) public {
        oracleMoveBps = uint24(bound(oracleMoveBps, 31, 500));

        controller.setParams(DEADBAND_BPS, 30, 100e18, MIN_VAMM_LIQUIDITY);

        uint256 beforePrice = controller.getVammPriceX18();
        uint256 oraclePrice = (beforePrice * (10_000 - oracleMoveBps)) / 10_000;
        uint256 lowerBound = (beforePrice * 9_970) / 10_000;
        oracle.setPriceX18(oraclePrice);

        (bool executed,, uint256 usedAmount) = controller.updateFromOracle();
        uint256 afterPrice = controller.getVammPriceX18();

        assertTrue(executed);
        assertGt(usedAmount, 0);
        assertLt(afterPrice, beforePrice);
        assertGe(afterPrice + PRICE_TOLERANCE_X18, lowerBound);
        assertGe(afterPrice + PRICE_TOLERANCE_X18, oraclePrice);
    }

    function testAmountInIsCappedByMaxPerUpdate() public {
        controller.setParams(DEADBAND_BPS, MAX_REPRICE_BPS, 1, MIN_VAMM_LIQUIDITY);
        uint256 beforePrice = controller.getVammPriceX18();
        oracle.setPriceX18((beforePrice * 140) / 100);

        (,, uint256 usedAmount) = controller.updateFromOracle();
        assertEq(usedAmount, 1);
    }

    function testAmountInIsCappedByAvailableInventory() public {
        LiquidityController limitedController = new LiquidityController(
            poolManager,
            swapRouter,
            oracle,
            vammPoolKey,
            address(veth),
            address(vusdc),
            0,
            DEADBAND_BPS,
            1_000,
            1_000e18,
            MIN_VAMM_LIQUIDITY
        );
        hook.setLiquidityController(address(limitedController));

        veth.addWhitelist(address(limitedController));
        vusdc.addWhitelist(address(limitedController));

        // For an upward reprice in this pool ordering, zeroForOne=true and the input token is currency0.
        // In this test setup currency0 is the quote-side virtual token, so seed it lightly.
        veth.transfer(address(limitedController), 1_000e18);
        vusdc.transfer(address(limitedController), 1e18);

        limitedController.approveSpender(veth, address(swapRouter), type(uint256).max);
        limitedController.approveSpender(vusdc, address(swapRouter), type(uint256).max);

        uint256 beforePrice = limitedController.getVammPriceX18();
        oracle.setPriceX18((beforePrice * 150) / 100);

        (bool executed,, uint256 usedAmount) = limitedController.updateFromOracle();

        assertTrue(executed);
        assertEq(usedAmount, 1e18);
        assertGt(limitedController.getVammPriceX18(), beforePrice);
    }

    function testRevertWhenLiquidityBelowFloor() public {
        controller.setParams(DEADBAND_BPS, MAX_REPRICE_BPS, MAX_AMOUNT_IN, type(uint128).max);

        uint256 beforePrice = controller.getVammPriceX18();
        oracle.setPriceX18((beforePrice * 130) / 100);

        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityController.VammLiquidityBelowFloor.selector, VAMM_BOOTSTRAP_LIQUIDITY, type(uint128).max
            )
        );
        controller.updateFromOracle();
    }

    function testProductionProfileStartsAt2300() public view {
        assertApproxEqAbs(controller.getVammPriceX18(), INITIAL_PRICE_X18, 1e10);
        assertEq(poolManager.getLiquidity(vammPoolId), VAMM_BOOTSTRAP_LIQUIDITY);
        assertEq(veth.balanceOf(address(controller)), LC_VETH_INVENTORY);
        assertEq(vusdc.balanceOf(address(controller)), LC_VUSDC_INVENTORY);
    }

    function testFuzzStressRandomOracleUpdatesNoCatch(uint256 seed, uint16 steps) public {
        if (!vm.envOr("RUN_STRESS_FUZZ", false)) return;

        steps = uint16(bound(steps, 128, 1024));
        controller.setParams(DEADBAND_BPS, MAX_REPRICE_BPS, MAX_AMOUNT_IN, MIN_VAMM_LIQUIDITY);

        for (uint256 i = 0; i < steps; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i, controller.getVammPriceX18())));
            uint256 oraclePrice = bound(seed, 100e18, 10_000e18);
            oracle.setPriceX18(oraclePrice);
            controller.updateFromOracle();
        }
    }

    function _vammInitSqrtPriceX96(uint256 quotePerBaseX18) internal view returns (uint160) {
        uint256 rawPriceX18 =
            Currency.unwrap(vammPoolKey.currency0) == address(veth) ? quotePerBaseX18 : 1e36 / quotePerBaseX18;
        return _priceX18ToSqrtPriceX96(rawPriceX18, 18, 18);
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

    function testFuzzUpdateFromOracleClassifiesRevertReason(
        uint24 oracleMoveBps,
        bool moveHigher,
        uint24 configuredDeadbandBps,
        uint24 configuredMaxRepriceBps,
        uint256 configuredMaxAmountIn,
        uint128 configuredMinLiquidity
    ) public {
        configuredDeadbandBps = uint24(bound(configuredDeadbandBps, 1, 50));
        configuredMaxRepriceBps = uint24(bound(configuredMaxRepriceBps, 1, 200));
        configuredMaxAmountIn = bound(configuredMaxAmountIn, 1, 2_000e18);
        configuredMinLiquidity = uint128(bound(uint256(configuredMinLiquidity), 1e18, 2_000_000e18));
        oracleMoveBps = uint24(bound(oracleMoveBps, configuredDeadbandBps + 1, 2_000));

        controller.setParams(
            configuredDeadbandBps, configuredMaxRepriceBps, configuredMaxAmountIn, configuredMinLiquidity
        );

        uint256 beforePrice = controller.getVammPriceX18();
        uint256 oraclePrice = moveHigher
            ? (beforePrice * (10_000 + oracleMoveBps)) / 10_000
            : (beforePrice * (10_000 - oracleMoveBps)) / 10_000;
        oracle.setPriceX18(oraclePrice);

        (bool ok, bytes memory data) = address(controller).call(abi.encodeCall(controller.updateFromOracle, ()));
        if (ok) {
            (bool executed,, uint256 usedAmountIn) = abi.decode(data, (bool, bool, uint256));
            if (executed) {
                assertGt(usedAmountIn, 0);
            } else {
                assertEq(usedAmountIn, 0);
            }
            return;
        }

        bytes4 selector = _revertSelector(data);

        console2.log("revert selector");
        console2.logBytes4(selector);
        console2.log("oracleMoveBps", uint256(oracleMoveBps));
        console2.log("moveHigher", moveHigher);
        console2.log("deadband", uint256(configuredDeadbandBps));
        console2.log("maxReprice", uint256(configuredMaxRepriceBps));
        console2.log("maxAmountIn", configuredMaxAmountIn);
        console2.log("minLiquidity", uint256(configuredMinLiquidity));

        bool knownSelector = selector == LiquidityController.VammLiquidityBelowFloor.selector
            || selector == LiquidityController.MaxRepriceExceeded.selector
            || selector == IERC20Errors.ERC20InsufficientBalance.selector;
        assertTrue(knownSelector, "unexpected revert selector");
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

    function _spreadBps(uint256 lhs, uint256 rhs) internal pure returns (uint256) {
        uint256 spread = lhs > rhs ? lhs - rhs : rhs - lhs;
        return (spread * 10_000) / rhs;
    }

    function _lastRepricedEvent(Vm.Log[] memory logs)
        internal
        pure
        returns (uint256 amountIn, uint256 oraclePriceX18, uint256 prePriceX18, uint256 postPriceX18)
    {
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory log = logs[i - 1];
            if (log.topics.length > 0 && log.topics[0] == REPRICED_SIG) {
                return abi.decode(log.data, (uint256, uint256, uint256, uint256));
            }
        }
        revert("repriced event not found");
    }

    function _revertSelector(bytes memory revertData) internal pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(revertData, 32))
        }
    }
}
