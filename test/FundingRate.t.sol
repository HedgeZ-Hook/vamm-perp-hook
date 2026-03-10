// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {MockPriceOracle} from "./MockPriceOracle.sol";
import {VirtualToken} from "../src/VirtualToken.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {Config} from "../src/Config.sol";
import {AccountBalance} from "../src/AccountBalance.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {Vault} from "../src/Vault.sol";
import {FundingRate} from "../src/FundingRate.sol";
import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {PerpMath} from "../src/libraries/PerpMath.sol";

contract FundingRateTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    VirtualToken internal veth;
    VirtualToken internal vusdc;
    MockERC20 internal usdc;
    PerpHook internal hook;
    Config internal config;
    AccountBalance internal accountBalance;
    ClearingHouse internal clearingHouse;
    MockPriceOracle internal priceOracle;
    Vault internal vault;
    FundingRate internal fundingRate;

    PoolKey internal vammPoolKey;
    PoolId internal vammPoolId;
    Currency internal baseCurrency;
    Currency internal quoteCurrency;

    function setUp() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0xaaaa << 144)
        );
        deployCodeTo("PerpHook.sol:PerpHook", abi.encode(poolManager), flags);
        hook = PerpHook(flags);

        veth = new VirtualToken("Virtual ETH", "vETH");
        vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        usdc = new MockERC20("USD Coin", "USDC", 18);

        veth.mintMaximumTo(address(this));
        vusdc.mintMaximumTo(address(this));
        _allowVirtualToken(veth);
        _allowVirtualToken(vusdc);

        (Currency currency0, Currency currency1) = _orderedCurrencies(address(veth), address(vusdc));
        vammPoolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        vammPoolId = vammPoolKey.toId();
        baseCurrency = Currency.wrap(address(veth));
        quoteCurrency = Currency.wrap(address(vusdc));

        config = new Config();
        accountBalance = new AccountBalance(config);
        clearingHouse = new ClearingHouse(poolManager, accountBalance, config, vammPoolKey, baseCurrency, quoteCurrency);
        priceOracle = new MockPriceOracle(1e18);

        PoolKey memory spotPoolKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), 3000, 60, IHooks(address(0)));
        vault = new Vault(
            accountBalance,
            config,
            IERC20(address(usdc)),
            priceOracle,
            poolManager,
            positionManager,
            swapRouter,
            spotPoolKey
        );
        fundingRate = new FundingRate(poolManager, priceOracle, accountBalance, config);

        hook.registerVAMMPool(vammPoolKey);
        hook.setClearingHouse(address(clearingHouse));

        accountBalance.setClearingHouse(address(clearingHouse));
        accountBalance.setVault(address(vault));
        clearingHouse.setVault(vault);
        vault.setClearingHouse(address(clearingHouse));
        clearingHouse.setFundingRate(fundingRate);
        vault.setFundingRate(fundingRate);
        fundingRate.setClearingHouse(address(clearingHouse));

        veth.addWhitelist(address(clearingHouse));
        vusdc.addWhitelist(address(clearingHouse));
        veth.transfer(address(clearingHouse), 1_000_000_000e18);
        vusdc.transfer(address(clearingHouse), 1_000_000_000e18);

        poolManager.initialize(vammPoolKey, Constants.SQRT_PRICE_1_1);
        _mintFullRange(vammPoolKey, 1_000_000e18);

        usdc.mint(alice, 10_000_000e18);
        usdc.mint(bob, 10_000_000e18);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function testFundingRatePositiveLongPaysShortsReceive() public {
        _seedPosition(alice, 10e18);
        _seedPosition(bob, -10e18);
        _startFundingClock(alice);

        priceOracle.setPriceX18(0.8e18);
        vm.warp(block.timestamp + 1 days);

        int256 alicePending = fundingRate.getPendingFundingPayment(alice, vammPoolId);
        int256 bobPending = fundingRate.getPendingFundingPayment(bob, vammPoolId);

        assertGt(alicePending, 0);
        assertLt(bobPending, 0);
        assertApproxEqAbs(PerpMath.abs(alicePending), PerpMath.abs(bobPending), 5);
    }

    function testFundingRateNegativeShortsPayLongsReceive() public {
        _seedPosition(alice, 10e18);
        _seedPosition(bob, -10e18);
        _startFundingClock(alice);

        priceOracle.setPriceX18(1.2e18);
        vm.warp(block.timestamp + 1 days);

        int256 alicePending = fundingRate.getPendingFundingPayment(alice, vammPoolId);
        int256 bobPending = fundingRate.getPendingFundingPayment(bob, vammPoolId);

        assertLt(alicePending, 0);
        assertGt(bobPending, 0);
        assertApproxEqAbs(PerpMath.abs(alicePending), PerpMath.abs(bobPending), 5);
    }

    function testFundingRateCappedByMaxFundingRate() public {
        _seedPosition(alice, 10e18);
        _startFundingClock(alice);

        config.setMaxFundingRate(10_000);
        priceOracle.setPriceX18(0.1e18);
        vm.warp(block.timestamp + 1 days);

        int256 pending = fundingRate.getPendingFundingPayment(alice, vammPoolId);
        int256 notionalX18 = PerpMath.mulDiv(10e18, int256(0.1e18), 1e18);
        int256 expectedCap = PerpMath.mulDiv(notionalX18, int256(0.01e18), 1e18);
        assertApproxEqAbs(pending, expectedCap, 5);
    }

    function testFundingRateIsTimeWeighted() public {
        _seedPosition(alice, 5e18);
        _startFundingClock(alice);

        priceOracle.setPriceX18(0.8e18);
        vm.warp(block.timestamp + 1 hours);
        int256 pending1h = fundingRate.getPendingFundingPayment(alice, vammPoolId);

        vm.warp(block.timestamp + 4 hours);
        int256 pending5h = fundingRate.getPendingFundingPayment(alice, vammPoolId);

        assertGt(pending1h, 0);
        assertApproxEqAbs(pending5h, pending1h * 5, 20);
    }

    function testFundingSettledOnPositionInteraction() public {
        vm.prank(alice);
        vault.deposit(1_000e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 10e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        priceOracle.setPriceX18(0.8e18);
        vm.warp(block.timestamp + 1 days);

        int256 beforeOwed = accountBalance.owedRealizedPnl(alice);
        int256 beforeSnapshot = accountBalance.getLastTwPremiumGrowthGlobalX96(alice, vammPoolId);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 1e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        int256 afterOwed = accountBalance.owedRealizedPnl(alice);
        int256 afterSnapshot = accountBalance.getLastTwPremiumGrowthGlobalX96(alice, vammPoolId);

        assertLt(afterOwed, beforeOwed);
        assertGt(afterSnapshot, beforeSnapshot);
    }

    function _seedPosition(address trader, int256 baseSize) internal {
        vm.prank(address(clearingHouse));
        accountBalance.modifyTakerBalance(trader, vammPoolId, baseSize, 0);
    }

    function _startFundingClock(address trader) internal {
        vm.prank(address(clearingHouse));
        fundingRate.settleFunding(trader, vammPoolId);
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
