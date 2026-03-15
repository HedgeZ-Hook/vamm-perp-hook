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
import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";

contract LPCollateralTest is BaseTest {
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

    PoolKey internal vammPoolKey;
    PoolKey internal spotPoolKey;
    PoolId internal vammPoolId;
    Currency internal baseCurrency;
    Currency internal quoteCurrency;

    uint256 internal aliceSpotTokenId;

    function setUp() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x8888 << 144)
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

        spotPoolKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));

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

        hook.registerVAMMPool(vammPoolKey);
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        hook.registerSpotPool(spotPoolKey);
        hook.setClearingHouse(address(clearingHouse));

        accountBalance.setClearingHouse(address(clearingHouse));
        accountBalance.setVault(address(vault));

        clearingHouse.setVault(vault);
        vault.setClearingHouse(address(clearingHouse));
        vault.setInsuranceFund(makeAddr("insuranceFund"));

        veth.addWhitelist(address(clearingHouse));
        vusdc.addWhitelist(address(clearingHouse));
        veth.transfer(address(clearingHouse), 1_000_000_000e18);
        vusdc.transfer(address(clearingHouse), 1_000_000_000e18);

        poolManager.initialize(vammPoolKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(spotPoolKey, Constants.SQRT_PRICE_1_1);
        _mintVammFullRange(vammPoolKey, 1_000_000e18);

        _fundAndApproveUsdc(alice, 10_000_000e18);
        _fundAndApproveUsdc(bob, 10_000_000e18);

        aliceSpotTokenId = _mintSpotFullRangeFor(alice, 2_000e18);
    }

    function testDepositLPAsCollateral() public {
        vm.prank(alice);
        IERC721(address(positionManager)).approve(address(vault), aliceSpotTokenId);

        vm.prank(alice);
        vault.depositLP(aliceSpotTokenId);

        assertEq(IERC721(address(positionManager)).ownerOf(aliceSpotTokenId), address(vault));
        (uint256 tokenId, address owner,,,) = vault.lpCollaterals(aliceSpotTokenId);
        assertEq(tokenId, aliceSpotTokenId);
        assertEq(owner, alice);
        assertEq(vault.getUserLPTokenIds(alice).length, 1);
        assertGt(vault.getLPCollateralValue(alice), 0);
        assertEq(vault.getAccountValue(alice), int256(vault.getLPCollateralValue(alice)));
    }

    function testLpCollateralEnablesPerpTrading() public {
        _depositAliceLP();

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 2_000e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        assertGt(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);

        vm.expectRevert();
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 80_000e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );
    }

    function testVoluntaryWithdrawBlockedByMarginAndPartialDecreaseWorks() public {
        _depositAliceLP();

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 20_000e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.expectRevert();
        vm.prank(alice);
        vault.withdrawLP(aliceSpotTokenId);

        (,,,, uint128 liquidityBefore) = vault.lpCollaterals(aliceSpotTokenId);
        uint128 removeLiquidity = liquidityBefore / 3;
        vm.prank(alice);
        vault.decreaseLP(aliceSpotTokenId, removeLiquidity);
        (,,,, uint128 liquidityAfter) = vault.lpCollaterals(aliceSpotTokenId);
        assertEq(liquidityAfter, liquidityBefore - removeLiquidity);
    }

    function testVoluntaryWithdrawWithDebtRepaymentWaterfall() public {
        _depositAliceLP();

        vm.prank(alice);
        vault.deposit(200e18);

        vm.prank(address(clearingHouse));
        accountBalance.modifyOwedRealizedPnl(alice, -1_500e18);

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawLP(aliceSpotTokenId);

        assertEq(IERC721(address(positionManager)).ownerOf(aliceSpotTokenId), alice);
        assertGe(vault.getNetCashBalance(alice), 0);
        assertGt(usdc.balanceOf(alice), usdcBefore);
    }

    function testVoluntaryWithdrawRevertsWhenForcedSwapOutputFallsBelowMinOut() public {
        _depositAliceLP();
        _mintSpotFullRangeFor(bob, 1_000e18);

        vm.prank(address(clearingHouse));
        accountBalance.modifyOwedRealizedPnl(alice, -10_000e18);

        // Force a strict min-out based on oracle, then set oracle far above spot to trigger slippage revert.
        vault.setForcedSwapSlippageRatio(0);
        priceOracle.setPriceX18(100e18);

        vm.expectRevert();
        vm.prank(alice);
        vault.withdrawLP(aliceSpotTokenId);
    }

    function testPartialDecreaseUpdatesLiquidity() public {
        _depositAliceLP();

        (,,,, uint128 liquidityBefore) = vault.lpCollaterals(aliceSpotTokenId);
        uint128 removeLiquidity = (liquidityBefore * 4) / 10;

        vm.prank(alice);
        vault.decreaseLP(aliceSpotTokenId, removeLiquidity);

        (,,,, uint128 liquidityAfter) = vault.lpCollaterals(aliceSpotTokenId);
        assertEq(liquidityAfter, liquidityBefore - removeLiquidity);
    }

    function testLpValueChangesWithOraclePrice() public {
        _depositAliceLP();

        uint256 valueAt1 = vault.getLPCollateralValue(alice);
        priceOracle.setPriceX18(2e18);
        uint256 valueAt2 = vault.getLPCollateralValue(alice);

        assertGt(valueAt2, valueAt1);
    }

    function testCannotWithdrawSomeoneElseLP() public {
        _depositAliceLP();

        vm.expectRevert();
        vm.prank(bob);
        vault.withdrawLP(aliceSpotTokenId);
    }

    function _depositAliceLP() internal {
        vm.prank(alice);
        IERC721(address(positionManager)).approve(address(vault), aliceSpotTokenId);
        vm.prank(alice);
        vault.depositLP(aliceSpotTokenId);
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
