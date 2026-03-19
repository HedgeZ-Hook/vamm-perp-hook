// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {VirtualToken} from "../src/VirtualToken.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {Config} from "../src/Config.sol";
import {AccountBalance} from "../src/AccountBalance.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {PerpMath} from "../src/libraries/PerpMath.sol";

contract OpenCloseTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    VirtualToken internal veth;
    VirtualToken internal vusdc;
    PerpHook internal hook;
    Config internal config;
    AccountBalance internal accountBalance;
    ClearingHouse internal clearingHouse;
    PoolKey internal vammPoolKey;
    PoolId internal vammPoolId;
    Currency internal baseCurrency;
    Currency internal quoteCurrency;

    function setUp() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x6666 << 144)
        );
        deployCodeTo("PerpHook.sol:PerpHook", abi.encode(poolManager, address(this)), flags);
        hook = PerpHook(flags);

        veth = new VirtualToken("Virtual ETH", "vETH");
        vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        veth.mintMaximumTo(address(this));
        vusdc.mintMaximumTo(address(this));

        _allowVirtualToken(veth);
        _allowVirtualToken(vusdc);

        (Currency currency0, Currency currency1) = _orderedCurrencies(address(veth), address(vusdc));
        vammPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        baseCurrency = Currency.wrap(address(veth));
        quoteCurrency = Currency.wrap(address(vusdc));
        vammPoolId = vammPoolKey.toId();

        config = new Config();
        accountBalance = new AccountBalance(config);
        clearingHouse = new ClearingHouse(poolManager, accountBalance, config, vammPoolKey, baseCurrency, quoteCurrency);

        accountBalance.setClearingHouse(address(clearingHouse));
        accountBalance.setVault(address(this));
        hook.registerVAMMPool(vammPoolKey, address(veth), address(vusdc));
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        hook.setClearingHouse(address(clearingHouse));

        veth.addWhitelist(address(clearingHouse));
        vusdc.addWhitelist(address(clearingHouse));
        veth.transfer(address(clearingHouse), 1_000_000e18);
        vusdc.transfer(address(clearingHouse), 10_000_000_000e18);

        poolManager.initialize(vammPoolKey, Constants.SQRT_PRICE_1_1);
        _mintFullRange(vammPoolKey, 1_000e18);
    }

    function testOpenLongPosition() public {
        (uint160 beforePrice,,,) = poolManager.getSlot0(vammPoolId);

        vm.prank(alice);
        (int256 base, int256 quote) = clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 1e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        assertGt(base, 0);
        assertLt(quote, 0);
        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), base);
        assertEq(accountBalance.getTakerOpenNotional(alice, vammPoolId), quote);

        (uint160 afterPrice,,,) = poolManager.getSlot0(vammPoolId);
        assertTrue(afterPrice != beforePrice);
    }

    function testOpenShortPosition() public {
        vm.prank(bob);
        (int256 base, int256 quote) = clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: true, amount: 1e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        assertLt(base, 0);
        assertGt(quote, 0);
        assertEq(accountBalance.getTakerPositionSize(bob, vammPoolId), base);
        assertEq(accountBalance.getTakerOpenNotional(bob, vammPoolId), quote);
    }

    function testClosePositionWithProfit() public {
        vm.startPrank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 1e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );
        vm.stopPrank();

        vm.prank(bob);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 5e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.prank(alice);
        clearingHouse.closePosition(0, 0, Constants.ZERO_BYTES);

        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);
        assertEq(accountBalance.getTakerOpenNotional(alice, vammPoolId), 0);
        assertGt(accountBalance.owedRealizedPnl(alice), 0);
    }

    function testClosePositionWithLoss() public {
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 1e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.prank(carol);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: true, amount: 5e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.prank(alice);
        clearingHouse.closePosition(0, 0, Constants.ZERO_BYTES);

        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);
        assertEq(accountBalance.getTakerOpenNotional(alice, vammPoolId), 0);
        assertLt(accountBalance.owedRealizedPnl(alice), 0);
    }

    function testPartialClosePosition() public {
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 10e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.prank(alice);
        clearingHouse.closePosition(3e18, 0, Constants.ZERO_BYTES);

        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 7e18);
        assertEq(accountBalance.getActivePoolIds(alice).length, 1);
    }

    function testPnlCalculationExactOnFullClose() public {
        vm.prank(alice);
        (, int256 openQuote) = clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 2e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        int256 prePosition = accountBalance.getTakerPositionSize(alice, vammPoolId);
        int256 preOpenNotional = accountBalance.getTakerOpenNotional(alice, vammPoolId);
        assertEq(preOpenNotional, openQuote);

        vm.prank(alice);
        (, int256 closeQuote) = clearingHouse.closePosition(0, 0, Constants.ZERO_BYTES);

        int256 expectedRealizedPnl = preOpenNotional + closeQuote;
        assertEq(accountBalance.owedRealizedPnl(alice), expectedRealizedPnl);
        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);
        assertEq(accountBalance.getTakerOpenNotional(alice, vammPoolId), 0);
        assertGt(PerpMath.abs(prePosition), 0);
    }

    function testPnlCalculationExactOnPartialClose() public {
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 10e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        int256 prePosition = accountBalance.getTakerPositionSize(alice, vammPoolId);
        int256 preOpenNotional = accountBalance.getTakerOpenNotional(alice, vammPoolId);

        vm.prank(alice);
        (int256 closeBase, int256 closeQuote) = clearingHouse.closePosition(3e18, 0, Constants.ZERO_BYTES);

        uint256 closeRatioX18 = (PerpMath.abs(closeBase) * 1e18) / PerpMath.abs(prePosition);
        int256 expectedClosedOpenNotional = PerpMath.mulDiv(preOpenNotional, int256(closeRatioX18), 1e18);
        int256 expectedRealizedPnl = closeQuote + expectedClosedOpenNotional;
        int256 expectedRemainingOpenNotional = preOpenNotional - expectedClosedOpenNotional;

        assertEq(accountBalance.owedRealizedPnl(alice), expectedRealizedPnl);
        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), prePosition + closeBase);
        assertEq(accountBalance.getTakerOpenNotional(alice, vammPoolId), expectedRemainingOpenNotional);
    }

    function testDirectSwapOnVammIsBlocked() public {
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: vammPoolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
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
