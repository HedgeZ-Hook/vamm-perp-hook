// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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
import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

contract Step2PerpHookBasicTest is BaseTest {
    using EasyPosm for IPositionManager;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant SPOT_LP_ADDED_SIG = keccak256("SpotLPAdded(address,int256)");
    bytes32 internal constant SPOT_LP_REMOVAL_REQUESTED_SIG = keccak256("SpotLPRemovalRequested(address)");
    bytes32 internal constant SPOT_LP_REMOVED_SIG = keccak256("SpotLPRemoved(address)");
    bytes32 internal constant VAMM_SWAP_ATTEMPT_SIG = keccak256("VammSwapAttempt(address)");
    bytes32 internal constant VAMM_SWAP_EXECUTED_SIG = keccak256("VammSwapExecuted(address,int256)");

    PerpHook internal hook;
    PoolKey internal spotPoolKey;
    PoolKey internal vammPoolKey;
    PoolId internal spotPoolId;
    PoolId internal vammPoolId;
    uint256 internal spotTokenId;

    function setUp() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x5555 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("PerpHook.sol:PerpHook", constructorArgs, flags);
        hook = PerpHook(flags);

        (Currency spotCurrency0, Currency spotCurrency1) = deployCurrencyPair();
        spotPoolKey = PoolKey(spotCurrency0, spotCurrency1, 3000, 60, IHooks(hook));

        VirtualToken veth = new VirtualToken("Virtual ETH", "vETH");
        VirtualToken vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        veth.mintMaximumTo(address(this));
        vusdc.mintMaximumTo(address(this));

        _allowVirtualToken(veth);
        _allowVirtualToken(vusdc);

        (Currency vammCurrency0, Currency vammCurrency1) = _orderedCurrencies(address(veth), address(vusdc));
        vammPoolKey = PoolKey(vammCurrency0, vammCurrency1, 3000, 60, IHooks(hook));

        poolManager.initialize(spotPoolKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(vammPoolKey, Constants.SQRT_PRICE_1_1);

        hook.registerSpotPool(spotPoolKey);
        hook.registerVAMMPool(vammPoolKey);

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
            spotTokenId,
            1e18,
            0,
            0,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countHookLogs(logs, SPOT_LP_REMOVAL_REQUESTED_SIG), 1);
        assertEq(_countHookLogs(logs, SPOT_LP_REMOVED_SIG), 1);
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

    function _orderedCurrencies(address tokenA, address tokenB) internal pure returns (Currency currency0, Currency currency1) {
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
        delta = swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _countHookLogs(Vm.Log[] memory logs, bytes32 sig) internal view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                count++;
            }
        }
    }
}
