// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {PerpMath} from "../src/libraries/PerpMath.sol";

contract IntegrationTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal treasury = makeAddr("treasury");

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
    InsuranceFund internal insuranceFund;

    PoolKey internal vammPoolKey;
    PoolKey internal spotPoolKey;
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
            ) ^ (0xcccc << 144)
        );
        deployCodeTo("PerpHook.sol:PerpHook", abi.encode(poolManager, address(this)), flags);
        hook = PerpHook(flags);

        veth = new VirtualToken("Virtual ETH", "vETH");
        vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        usdc = new MockERC20("USD Coin", "USDC", 18);

        veth.mintMaximumTo(address(this));
        vusdc.mintMaximumTo(address(this));
        _allowVirtualToken(veth);
        _allowVirtualToken(vusdc);

        (Currency currency0, Currency currency1) = _orderedCurrencies(address(veth), address(vusdc));
        vammPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        vammPoolId = vammPoolKey.toId();
        baseCurrency = Currency.wrap(address(veth));
        quoteCurrency = Currency.wrap(address(vusdc));

        spotPoolKey = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(usdc)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook)
        );

        config = new Config();
        accountBalance = new AccountBalance(config);
        clearingHouse = new ClearingHouse(poolManager, accountBalance, config, vammPoolKey, baseCurrency, quoteCurrency);
        priceOracle = new MockPriceOracle(1e18);
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
        insuranceFund = new InsuranceFund(vault, IERC20(address(usdc)), treasury, 100e18);

        hook.registerVAMMPool(vammPoolKey, address(veth), address(vusdc));
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        hook.registerSpotPool(spotPoolKey);
        hook.setClearingHouse(address(clearingHouse));

        accountBalance.setClearingHouse(address(clearingHouse));
        accountBalance.setVault(address(vault));

        clearingHouse.setVault(vault);
        clearingHouse.setFundingRate(fundingRate);
        vault.setClearingHouse(address(clearingHouse));
        vault.setInsuranceFund(address(insuranceFund));
        vault.setFundingRate(fundingRate);
        fundingRate.setClearingHouse(address(clearingHouse));

        veth.addWhitelist(address(clearingHouse));
        vusdc.addWhitelist(address(clearingHouse));
        veth.transfer(address(clearingHouse), 1_000_000_000e18);
        vusdc.transfer(address(clearingHouse), 1_000_000_000e18);

        poolManager.initialize(vammPoolKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(spotPoolKey, Constants.SQRT_PRICE_1_1);
        _mintVammFullRange(vammPoolKey, 1_000_000e18);

        _fundAndApproveUsdc(alice, 10_000_000e18);
        _fundAndApproveUsdc(bob, 10_000_000e18);
        _fundAndApproveUsdc(carol, 10_000_000e18);
    }

    function testScenario1LpHedgesImpermanentLoss() public {
        uint256 aliceLp = _createLpAndDeposit(alice, 2_000e18);
        uint256 bobLp = _createLpAndDeposit(bob, 2_000e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: true, amount: 400e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        _setOracleAndMark(0.8e18);

        int256 aliceAccountValue = vault.getAccountValue(alice);
        int256 bobAccountValue = vault.getAccountValue(bob);
        assertGt(aliceAccountValue, bobAccountValue);
        assertGt(vault.getLPCollateralValue(alice), 0);
        assertGt(vault.getLPCollateralValue(bob), 0);
        assertEq(vault.getUserLPTokenIds(alice)[0], aliceLp);
        assertEq(vault.getUserLPTokenIds(bob)[0], bobLp);
    }

    function testScenario2MultipleTradersFundingCycle() public {
        config.setInsuranceFundFeeRatio(0);

        vm.prank(alice);
        vault.deposit(1_000e18);
        vm.prank(bob);
        vault.deposit(1_000e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 50e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );
        vm.prank(bob);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: true, amount: 50e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        _setOracleAndMark(0.8e18);
        vm.warp(block.timestamp + 6 hours);

        int256 pendingAlice = fundingRate.getPendingFundingPayment(alice, vammPoolId);
        int256 pendingBob = fundingRate.getPendingFundingPayment(bob, vammPoolId);
        assertGt(pendingAlice, 0);
        assertLt(pendingBob, 0);
        assertApproxEqAbs(PerpMath.abs(pendingAlice), PerpMath.abs(pendingBob), 1e17);

        int256 beforeA = accountBalance.owedRealizedPnl(alice);
        int256 beforeB = accountBalance.owedRealizedPnl(bob);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 1e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );
        vm.prank(bob);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: true, amount: 1e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        int256 deltaA = accountBalance.owedRealizedPnl(alice) - beforeA;
        int256 deltaB = accountBalance.owedRealizedPnl(bob) - beforeB;
        assertLt(deltaA, 0);
        assertGt(deltaB, 0);
    }

    function testScenario3LpCollateralLiquidationEndToEnd() public {
        uint256 tokenId = _createLpAndDeposit(alice, 2_000e18);

        vm.prank(alice);
        vault.deposit(200e18);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 5_000e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        _setOracleAndMark(0.2e18);
        assertTrue(vault.isLiquidatable(alice));

        int256 bobBefore = vault.usdcBalance(bob);
        vm.prank(bob);
        clearingHouse.liquidate(alice);

        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);
        // Liquidation penalty is only distributed when trader still has positive net cash.
        int256 bobAfter = vault.usdcBalance(bob);
        assertTrue(bobAfter >= bobBefore);
        assertEq(vault.getUserLPTokenIds(alice).length, 0);
        assertEq(vault.getLPCollateralValue(alice), 0);
        // LP record is removed after full forced liquidation.
        (,,,, uint128 liqAfter) = vault.lpCollaterals(tokenId);
        assertEq(liqAfter, 0);
    }

    function testScenario3bLpCollateralPartialLiquidation() public {
        // Remove liquidation buffer to deterministically exercise partial LP removal branch.
        vault.setLpRemoveBufferRatio(0);
        config.setLiquidationPenaltyRatio(0);
        uint256 tokenId = _createLpAndDeposit(alice, 2_000e18);

        vm.prank(alice);
        vault.deposit(200e18);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 16_890e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        _setOracleAndMark(0.8e18);
        assertTrue(vault.isLiquidatable(alice));

        vm.prank(bob);
        clearingHouse.liquidate(alice);

        // Position is liquidated and LP is only partially removed.
        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);
        assertEq(vault.getUserLPTokenIds(alice).length, 1);
        (,,,, uint128 liqAfter) = vault.lpCollaterals(tokenId);
        assertGt(liqAfter, 0);
        assertLt(liqAfter, 2_000e18);
    }

    function testScenario4VoluntaryCutLossThenPartialLPUnwind() public {
        uint256 tokenId = _createLpAndDeposit(alice, 2_000e18);

        vm.prank(alice);
        vault.deposit(200e18);
        vm.prank(bob);
        vault.deposit(2_000e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 800e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.prank(bob);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: true, amount: 2_000e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.prank(alice);
        clearingHouse.closePosition(0, 0, Constants.ZERO_BYTES);

        if (vault.getNetCashBalance(alice) >= 0) {
            vm.prank(address(clearingHouse));
            accountBalance.modifyOwedRealizedPnl(alice, -1_000e18);
        }

        int256 netBefore = vault.getNetCashBalance(alice);
        (,,,, uint128 liquidityBefore) = vault.lpCollaterals(tokenId);

        vm.prank(alice);
        vault.decreaseLP(tokenId, liquidityBefore / 2);

        int256 netAfter = vault.getNetCashBalance(alice);
        (,,,, uint128 liquidityAfter) = vault.lpCollaterals(tokenId);
        assertGt(netAfter, netBefore);
        assertGt(liquidityAfter, 0);
        assertLt(liquidityAfter, liquidityBefore);
    }

    function testScenario5LiquidationCascadeWithBadDebt() public {
        usdc.mint(address(insuranceFund), 1_000e18);
        vm.prank(address(insuranceFund));
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(address(insuranceFund));
        vault.deposit(1_000e18);

        vm.prank(alice);
        vault.deposit(10e18);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 80e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        _setOracleAndMark(0.5e18);
        assertTrue(vault.isLiquidatable(alice));

        int256 ifBefore = vault.usdcBalance(address(insuranceFund));
        vm.prank(bob);
        clearingHouse.liquidate(alice);
        int256 ifAfter = vault.usdcBalance(address(insuranceFund));

        assertLt(ifAfter, ifBefore);
        assertEq(vault.getNetCashBalance(alice), 0);
    }

    function testScenario6LpWithdrawalWithOutstandingDebt() public {
        uint256 tokenId = _createLpAndDeposit(alice, 2_000e18);

        vm.prank(alice);
        vault.deposit(200e18);
        vm.prank(address(clearingHouse));
        accountBalance.modifyOwedRealizedPnl(alice, -1_500e18);

        vm.prank(alice);
        vault.withdrawLP(tokenId);

        assertEq(vault.getUserLPTokenIds(alice).length, 0);
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), alice);
        assertGe(vault.getNetCashBalance(alice), 0);
    }

    function testScenario7FullLifecycle() public {
        vm.prank(alice);
        vault.deposit(1_000e18);

        uint256 tokenId = _createLpAndDeposit(alice, 1_500e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 300e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        _setOracleAndMark(0.8e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 1e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.prank(bob);
        vault.deposit(2_000e18);
        vm.prank(bob);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: true, amount: 500e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.prank(alice);
        clearingHouse.closePosition(100e18, 0, Constants.ZERO_BYTES);
        vm.prank(alice);
        clearingHouse.closePosition(0, 0, Constants.ZERO_BYTES);

        if (vault.getNetCashBalance(alice) < 0) {
            (,,,, uint128 liq) = vault.lpCollaterals(tokenId);
            vm.prank(alice);
            vault.decreaseLP(tokenId, liq / 2);
        }

        if (vault.getUserLPTokenIds(alice).length > 0) {
            vm.prank(alice);
            vault.withdrawLP(tokenId);
        }

        int256 settledBalance = vault.usdcBalance(alice) + accountBalance.getOwedRealizedPnl(alice);
        if (settledBalance > 0) {
            vm.prank(alice);
            vault.withdraw(uint256(settledBalance));
        }

        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);
        assertEq(vault.getUserLPTokenIds(alice).length, 0);
    }

    function _setOracleAndMark(uint256 priceX18) internal {
        priceOracle.setPriceX18(priceX18);
        accountBalance.setMarkPriceX18(vammPoolId, priceX18);
    }

    function _createLpAndDeposit(address trader, uint128 liquidity) internal returns (uint256 tokenId) {
        tokenId = _mintSpotFullRangeFor(trader, liquidity);
        vm.prank(trader);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(trader);
        vault.depositLP(tokenId);
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
        if (tokenA > tokenB) (currency0, currency1) = (currency1, currency0);
    }

    function _fundAndApproveUsdc(address trader, uint256 amount) internal {
        usdc.mint(trader, amount);
        vm.deal(trader, 10_000_000e18);

        vm.startPrank(trader);
        usdc.approve(address(permit2), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        permit2.approve(address(usdc), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(usdc), address(poolManager), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _mintVammFullRange(PoolKey memory key, uint128 liquidityAmount) internal returns (uint256 tokenId) {
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

    function _mintSpotFullRangeFor(address owner, uint128 liquidityAmount) internal returns (uint256 tokenId) {
        int24 tickLower = TickMath.minUsableTick(spotPoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(spotPoolKey.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        vm.startPrank(owner);
        (tokenId,) = positionManager.mint(
            spotPoolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            owner,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();
    }
}
