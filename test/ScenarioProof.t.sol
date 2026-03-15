// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
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
import {MockPriceOracle} from "./MockPriceOracle.sol";
import {VirtualToken} from "../src/VirtualToken.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {Config} from "../src/Config.sol";
import {AccountBalance} from "../src/AccountBalance.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {Vault} from "../src/Vault.sol";
import {FundingRate} from "../src/FundingRate.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {LiquidityController} from "../src/LiquidityController.sol";
import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {PerpMath} from "../src/libraries/PerpMath.sol";

contract ScenarioProofTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant SWAP_SIG = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

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
    LiquidityController internal liquidityController;

    PoolKey internal vammPoolKey;
    PoolKey internal spotPoolKey;
    PoolId internal vammPoolId;
    PoolId internal spotPoolId;
    Currency internal baseCurrency;
    Currency internal quoteCurrency;

    function setUp() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0xdddd << 144)
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
        vammPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        vammPoolId = vammPoolKey.toId();
        baseCurrency = Currency.wrap(address(veth));
        quoteCurrency = Currency.wrap(address(vusdc));

        spotPoolKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        spotPoolId = spotPoolKey.toId();

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

        hook.registerVAMMPool(vammPoolKey);
        hook.registerSpotPool(spotPoolKey);
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        hook.setClearingHouse(address(clearingHouse));
        hook.setPriceOracle(priceOracle, 0);

        accountBalance.setClearingHouse(address(clearingHouse));
        accountBalance.setVault(address(vault));
        clearingHouse.setVault(vault);
        clearingHouse.setFundingRate(fundingRate);
        vault.setClearingHouse(address(clearingHouse));
        vault.setInsuranceFund(address(insuranceFund));
        vault.setFundingRate(fundingRate);
        fundingRate.setClearingHouse(address(clearingHouse));

        liquidityController = new LiquidityController(
            poolManager, swapRouter, priceOracle, vammPoolKey, 0, 10, 30, 5e18, 1e18
        );
        hook.setLiquidityController(address(liquidityController));

        veth.addWhitelist(address(clearingHouse));
        vusdc.addWhitelist(address(clearingHouse));
        veth.addWhitelist(address(liquidityController));
        vusdc.addWhitelist(address(liquidityController));
        veth.transfer(address(clearingHouse), 1_000_000_000e18);
        vusdc.transfer(address(clearingHouse), 1_000_000_000e18);
        veth.transfer(address(liquidityController), 100e18);
        vusdc.transfer(address(liquidityController), 100_000e18);
        liquidityController.approveSpender(veth, address(swapRouter), type(uint256).max);
        liquidityController.approveSpender(vusdc, address(swapRouter), type(uint256).max);

        poolManager.initialize(vammPoolKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(spotPoolKey, Constants.SQRT_PRICE_1_1);
        _mintVammFullRange(vammPoolKey, 1_000_000e18);

        _fundAndApproveUsdc(address(this), 10_000_000e18);
        _fundAndApproveUsdc(alice, 10_000_000e18);
        _fundAndApproveUsdc(bob, 10_000_000e18);
        _fundAndApproveUsdc(carol, 10_000_000e18);

        _mintSpotFullRangeFor(address(this), 5_000e18);
    }

    function testScenario1_BootstrapAndWiringExact() public view {
        assertEq(config.imRatio(), 100_000);
        assertEq(config.mmRatio(), 62_500);
        assertEq(config.liquidationPenaltyRatio(), 25_000);
        assertEq(config.maxFundingRate(), 100_000);
        assertEq(config.twapInterval(), 900);
        assertEq(config.insuranceFundFeeRatio(), 0);

        assertEq(PoolId.unwrap(hook.spotPoolId()), PoolId.unwrap(spotPoolId));
        assertEq(PoolId.unwrap(hook.vammPoolId()), PoolId.unwrap(vammPoolId));
        assertEq(hook.clearingHouse(), address(clearingHouse));
        assertEq(hook.liquidityController(), address(liquidityController));
        assertTrue(hook.verifiedRouters(address(positionManager)));
        assertTrue(hook.verifiedRouters(address(swapRouter)));

        assertEq(vammPoolKey.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(spotPoolKey.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertTrue(liquidityController.isLiquidityHealthy());
        assertEq(liquidityController.deadbandBps(), 10);
        assertEq(liquidityController.maxRepriceBpsPerUpdate(), 30);
        assertEq(liquidityController.maxAmountInPerUpdate(), 5e18);
        assertEq(liquidityController.minVammLiquidity(), 1e18);
    }

    function testScenario2_OpenCloseWithExactAccounting() public {
        config.setInsuranceFundFeeRatio(0);

        vm.prank(alice);
        vault.deposit(2e18);

        vm.prank(alice);
        (int256 openBase, int256 openQuote) = clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false,
                amount: 10e18,
                sqrtPriceLimitX96: 0,
                hookData: Constants.ZERO_BYTES
            })
        );

        uint256 leverageX18 = (PerpMath.abs(openQuote) * 1e18) / 2e18;
        assertApproxEqAbs(leverageX18, 5e18, 2e17);
        assertGt(openBase, 0);
        assertLt(openQuote, 0);

        int256 prePosition = accountBalance.getTakerPositionSize(alice, vammPoolId);
        int256 preOpenNotional = accountBalance.getTakerOpenNotional(alice, vammPoolId);

        vm.prank(alice);
        (int256 closeBase, int256 closeQuote) = clearingHouse.closePosition(0, 0, Constants.ZERO_BYTES);

        assertEq(closeBase, -prePosition);
        int256 expectedRealizedPnl = preOpenNotional + closeQuote;
        assertEq(accountBalance.owedRealizedPnl(alice), expectedRealizedPnl);
        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);
        assertEq(accountBalance.getTakerOpenNotional(alice, vammPoolId), 0);
    }

    function testScenario3_DynamicFeeFormulaExact() public {
        hook.setSpotFeeConfig(2, 6, 40, 1_000e18, 0);
        uint256 spotPrice = hook.getSpotPriceX18();
        priceOracle.setPriceX18(spotPrice);

        // base(6) + spread(0) + vol(0) + size(1) = 7 bps => 700 pips
        uint24 previewLow = hook.previewSpotFeePips(100e18);
        assertEq(previewLow, 700);

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens{value: 100e18}(
            100e18, 0, true, spotPoolKey, Constants.ZERO_BYTES, address(this), block.timestamp + 1
        );
        uint24 swapFee = _lastPoolSwapFee(vm.getRecordedLogs(), spotPoolId);
        assertEq(swapFee, 700);

        // spread 30% => spreadComp capped at 20, size 1000 => sizeComp 15, total 41 bps => clamp 40 bps.
        priceOracle.setPriceX18((spotPrice * 13) / 10);
        uint24 previewHigh = hook.previewSpotFeePips(1_000e18);
        assertEq(previewHigh, 4_000);
    }

    function testScenario4_LpHedgeImprovesAccountValue() public {
        uint256 aliceLp = _createLpAndDeposit(alice, 2_000e18);
        uint256 bobLp = _createLpAndDeposit(bob, 2_000e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: true,
                amount: 400e18,
                sqrtPriceLimitX96: 0,
                hookData: Constants.ZERO_BYTES
            })
        );

        _setOracleAndMark(0.8e18);

        assertEq(vault.getUserLPTokenIds(alice)[0], aliceLp);
        assertEq(vault.getUserLPTokenIds(bob)[0], bobLp);
        assertEq(vault.getLPCollateralValue(alice), vault.getLPCollateralValue(bob));

        int256 aliceAccountValue = vault.getAccountValue(alice);
        int256 bobAccountValue = vault.getAccountValue(bob);
        assertGt(aliceAccountValue, bobAccountValue);
    }

    function testScenario5_LiquidityControllerRepriceBoundAndCap() public {
        uint256 prePrice = liquidityController.getVammPriceX18();
        priceOracle.setPriceX18((prePrice * 80) / 100); // oracle lower -> expect zeroForOne

        (bool executed, bool zeroForOne, uint256 usedAmountIn) = liquidityController.updateFromOracle(100e18);
        uint256 postPrice = liquidityController.getVammPriceX18();

        assertTrue(executed);
        assertTrue(zeroForOne);
        assertEq(usedAmountIn, 5e18);
        assertLt(postPrice, prePrice);

        uint256 lowerBound = (prePrice * (10_000 - 30)) / 10_000;
        uint256 upperBound = (prePrice * (10_000 + 30)) / 10_000;
        assertGe(postPrice, lowerBound);
        assertLe(postPrice, upperBound);
    }

    function testScenario6_FundingTransferAndSettlementExact() public {
        config.setInsuranceFundFeeRatio(0);

        vm.prank(alice);
        vault.deposit(1_000e18);
        vm.prank(bob);
        vault.deposit(1_000e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false,
                amount: 50e18,
                sqrtPriceLimitX96: 0,
                hookData: Constants.ZERO_BYTES
            })
        );
        vm.prank(bob);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: true,
                amount: 50e18,
                sqrtPriceLimitX96: 0,
                hookData: Constants.ZERO_BYTES
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
                isBaseToQuote: false,
                amount: 1e18,
                sqrtPriceLimitX96: 0,
                hookData: Constants.ZERO_BYTES
            })
        );
        vm.prank(bob);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: true,
                amount: 1e18,
                sqrtPriceLimitX96: 0,
                hookData: Constants.ZERO_BYTES
            })
        );

        int256 deltaA = accountBalance.owedRealizedPnl(alice) - beforeA;
        int256 deltaB = accountBalance.owedRealizedPnl(bob) - beforeB;
        assertApproxEqAbs(deltaA, -pendingAlice, 1);
        assertApproxEqAbs(deltaB, -pendingBob, 1);
    }

    function testScenario7_LiquidationPartialFullAndPenaltySplit() public {
        // Partial liquidation case
        vm.prank(alice);
        vault.deposit(28e18);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false,
                amount: 200e18,
                sqrtPriceLimitX96: 0,
                hookData: Constants.ZERO_BYTES
            })
        );

        _setOracleAndMark(0.9e18);
        int256 partialPosBefore = accountBalance.getTakerPositionSize(alice, vammPoolId);
        int256 bobBefore = vault.usdcBalance(bob);
        int256 ifBefore = vault.usdcBalance(address(insuranceFund));

        vm.prank(bob);
        (int256 liquidatedSize, uint256 penalty) = clearingHouse.liquidate(alice);

        int256 partialPosAfter = accountBalance.getTakerPositionSize(alice, vammPoolId);
        assertGt(PerpMath.abs(liquidatedSize), 0);
        assertGt(PerpMath.abs(partialPosAfter), 0);
        assertLt(PerpMath.abs(partialPosAfter), PerpMath.abs(partialPosBefore));

        uint256 expectedBob = penalty / 2;
        uint256 expectedIf = penalty - expectedBob;
        assertEq(uint256(vault.usdcBalance(bob) - bobBefore), expectedBob);
        assertEq(uint256(vault.usdcBalance(address(insuranceFund)) - ifBefore), expectedIf);

        // Full liquidation case
        vm.prank(carol);
        vault.deposit(27e18);
        vm.prank(carol);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false,
                amount: 80e18,
                sqrtPriceLimitX96: 0,
                hookData: Constants.ZERO_BYTES
            })
        );

        _setOracleAndMark(0.7e18);
        int256 fullPosBefore = accountBalance.getTakerPositionSize(carol, vammPoolId);
        vm.prank(bob);
        clearingHouse.liquidate(carol);
        assertEq(accountBalance.getTakerPositionSize(carol, vammPoolId), 0);
        assertEq(PerpMath.abs(fullPosBefore), 80e18);
    }

    function testScenario8_LpForcedUnwindAndInsuranceWaterfall() public {
        config.setLiquidationPenaltyRatio(0); // isolate waterfall accounting

        usdc.mint(address(insuranceFund), 10_000e18);
        vm.prank(address(insuranceFund));
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(address(insuranceFund));
        vault.deposit(5_000e18);

        uint256 tokenId = _createLpAndDeposit(alice, 2_000e18);
        vm.prank(alice);
        vault.deposit(200e18);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false,
                amount: 16_890e18,
                sqrtPriceLimitX96: 0,
                hookData: Constants.ZERO_BYTES
            })
        );

        _setOracleAndMark(0.1e18);
        assertTrue(vault.isLiquidatable(alice));

        int256 ifBefore = vault.usdcBalance(address(insuranceFund));
        (,,,, uint128 lpLiquidityBefore) = vault.lpCollaterals(tokenId);

        vm.prank(bob);
        clearingHouse.liquidate(alice);

        int256 ifAfter = vault.usdcBalance(address(insuranceFund));
        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);
        assertEq(vault.getUserLPTokenIds(alice).length, 0);
        assertEq(vault.getNetCashBalance(alice), 0);
        assertLt(ifAfter, ifBefore);

        (,,,, uint128 lpLiquidityAfter) = vault.lpCollaterals(tokenId);
        assertEq(lpLiquidityAfter, 0);
        assertGt(lpLiquidityBefore, lpLiquidityAfter);
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
