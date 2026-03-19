// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {PerpHook} from "../src/PerpHook.sol";
import {VirtualToken} from "../src/VirtualToken.sol";
import {MockPriceOracle} from "./MockPriceOracle.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

contract PerpHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant SPOT_LP_ADDED_SIG = keccak256("SpotLPAdded(address,int256)");
    bytes32 internal constant SPOT_LP_REMOVAL_REQUESTED_SIG = keccak256("SpotLPRemovalRequested(address)");
    bytes32 internal constant SPOT_LP_REMOVED_SIG = keccak256("SpotLPRemoved(address)");
    bytes32 internal constant VAMM_SWAP_ATTEMPT_SIG = keccak256("VammSwapAttempt(address)");
    bytes32 internal constant VAMM_SWAP_EXECUTED_SIG = keccak256("VammSwapExecuted(address,int256)");
    bytes32 internal constant SWAP_SIG = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    PerpHook internal hook;
    MockPriceOracle internal priceOracle;
    PoolKey internal spotPoolKey;
    PoolKey internal vammPoolKey;
    PoolId internal spotPoolId;
    PoolId internal vammPoolId;
    uint256 internal spotTokenId;

    function setUp() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x5555 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager, address(this));
        deployCodeTo("PerpHook.sol:PerpHook", constructorArgs, flags);
        hook = PerpHook(flags);

        (Currency spotCurrency0, Currency spotCurrency1) = deployCurrencyPair();
        spotPoolKey = PoolKey(spotCurrency0, spotCurrency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));

        VirtualToken veth = new VirtualToken("Virtual ETH", "vETH");
        VirtualToken vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        veth.mintMaximumTo(address(this));
        vusdc.mintMaximumTo(address(this));

        _allowVirtualToken(veth);
        _allowVirtualToken(vusdc);

        (Currency vammCurrency0, Currency vammCurrency1) = _orderedCurrencies(address(veth), address(vusdc));
        vammPoolKey = PoolKey(vammCurrency0, vammCurrency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));

        poolManager.initialize(spotPoolKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(vammPoolKey, Constants.SQRT_PRICE_1_1);

        hook.registerSpotPool(spotPoolKey);
        hook.registerVAMMPool(vammPoolKey, address(veth), address(vusdc));
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        hook.setClearingHouse(address(this));

        priceOracle = new MockPriceOracle(1e18);
        hook.setPriceOracle(priceOracle, 0);

        spotPoolId = spotPoolKey.toId();
        vammPoolId = vammPoolKey.toId();

        spotTokenId = _mintFullRange(spotPoolKey, 100e18);
        _mintFullRange(vammPoolKey, 100e18);
    }

    function testPoolRegistration() public view {
        assertEq(PoolId.unwrap(hook.spotPoolId()), PoolId.unwrap(spotPoolId));
        assertEq(PoolId.unwrap(hook.vammPoolId()), PoolId.unwrap(vammPoolId));
    }

    function testSpotAddLiquidityEmitsOnlySpotEvent() public {
        vm.recordLogs();
        _mintFullRange(spotPoolKey, 10e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countHookLogs(logs, SPOT_LP_ADDED_SIG), 1);
        assertEq(_countHookLogs(logs, VAMM_SWAP_ATTEMPT_SIG), 0);
        assertEq(_countHookLogs(logs, VAMM_SWAP_EXECUTED_SIG), 0);
    }

    function testVammSwapEmitsOnlyVammEvents() public {
        vm.recordLogs();
        _swap(vammPoolKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countHookLogs(logs, VAMM_SWAP_ATTEMPT_SIG), 1);
        assertEq(_countHookLogs(logs, VAMM_SWAP_EXECUTED_SIG), 1);
        assertEq(_countHookLogs(logs, SPOT_LP_ADDED_SIG), 0);
        assertEq(_countHookLogs(logs, SPOT_LP_REMOVAL_REQUESTED_SIG), 0);
        assertEq(_countHookLogs(logs, SPOT_LP_REMOVED_SIG), 0);
    }

    function testVammAddLiquidityDoesNotEmitSpotEvent() public {
        vm.recordLogs();
        _mintFullRange(vammPoolKey, 10e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countHookLogs(logs, SPOT_LP_ADDED_SIG), 0);
    }

    function testSpotSwapDoesNotEmitVammEvent() public {
        vm.recordLogs();
        _swap(spotPoolKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countHookLogs(logs, VAMM_SWAP_ATTEMPT_SIG), 0);
        assertEq(_countHookLogs(logs, VAMM_SWAP_EXECUTED_SIG), 0);
    }

    function testSpotRemoveLiquidityEmitsRemoveEvents() public {
        vm.recordLogs();
        positionManager.decreaseLiquidity(
            spotTokenId, 1e18, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countHookLogs(logs, SPOT_LP_REMOVAL_REQUESTED_SIG), 1);
        assertEq(_countHookLogs(logs, SPOT_LP_REMOVED_SIG), 1);
    }

    function testVammSwapUnauthorizedReverts() public {
        hook.setClearingHouse(makeAddr("newCH"));
        vm.expectRevert();
        _swap(vammPoolKey);
    }

    function testVammDynamicFeeAlwaysZero() public {
        vm.recordLogs();
        _swap(vammPoolKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint24 fee = _lastPoolSwapFee(logs, vammPoolId);
        assertEq(fee, 0);
    }

    function testSpotFeeIncreasesWhenSpreadIncreases() public {
        uint256 spotPriceX18 = hook.getSpotPriceX18();
        priceOracle.setPriceX18(spotPriceX18);

        uint24 baselineFee = _spotSwapFee(1e18, true);
        priceOracle.setPriceX18((spotPriceX18 * 13) / 10); // +30% oracle spread
        uint24 spreadFee = _spotSwapFee(1e18, true);

        assertGe(baselineFee, hook.minFeeBps() * 100);
        assertLe(baselineFee, hook.maxFeeBps() * 100);
        assertGe(spreadFee, hook.minFeeBps() * 100);
        assertLe(spreadFee, hook.maxFeeBps() * 100);
        assertGt(spreadFee, baselineFee);
    }

    function testSpotFeeIncreasesWithTradeSize() public {
        hook.setSpotFeeConfig(2, 6, 40, 1e18, 0); // disable EMA for isolated size check
        uint256 spotPriceX18 = hook.getSpotPriceX18();
        priceOracle.setPriceX18(spotPriceX18);

        uint24 smallFee = _spotSwapFee(2e16, true);
        uint24 largeFee = _spotSwapFee(2e18, true);

        assertGt(largeFee, smallFee);
    }

    function testSpotVolEmaIncreasesAfterVolatileSwap() public {
        hook.setSpotFeeConfig(2, 6, 40, 1e18, 500_000);
        uint24 beforeEma = hook.spotVolEmaBps();

        _swapWithAmount(spotPoolKey, 5e18, true);

        uint24 afterEma = hook.spotVolEmaBps();
        assertGt(afterEma, beforeEma);
    }

    function testSpotVolEmaDecaysAfterCalmerSwap() public {
        hook.setSpotFeeConfig(2, 6, 40, 1e18, 500_000);

        _swapWithAmount(spotPoolKey, 5e18, true);
        uint24 afterVolatile = hook.spotVolEmaBps();

        _swapWithAmount(spotPoolKey, 1e14, true);
        uint24 afterCalmer = hook.spotVolEmaBps();

        assertLt(afterCalmer, afterVolatile);
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

    function _swap(PoolKey memory key) internal returns (BalanceDelta delta) {
        delta = _swapWithAmount(key, 1e18, true);
    }

    function _swapWithAmount(PoolKey memory key, uint256 amountIn, bool zeroForOne)
        internal
        returns (BalanceDelta delta)
    {
        delta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _spotSwapFee(uint256 amountIn, bool zeroForOne) internal returns (uint24 fee) {
        vm.recordLogs();
        _swapWithAmount(spotPoolKey, amountIn, zeroForOne);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        fee = _lastPoolSwapFee(logs, spotPoolId);
    }

    function _lastPoolSwapFee(Vm.Log[] memory logs, PoolId poolId) internal view returns (uint24 fee) {
        bytes32 poolIdTopic = bytes32(PoolId.unwrap(poolId));
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(poolManager) || entry.topics.length < 2) continue;
            if (entry.topics[0] != SWAP_SIG || entry.topics[1] != poolIdTopic) continue;
            (,,,,, fee) = abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
            return fee;
        }
        revert("swap fee not found");
    }

    function _countHookLogs(Vm.Log[] memory logs, bytes32 sig) internal view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                count++;
            }
        }
    }
}
