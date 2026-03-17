// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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
import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {PerpMath} from "../src/libraries/PerpMath.sol";

contract LiquidationTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant POSITION_LIQUIDATED_SIG =
        keccak256("PositionLiquidated(address,address,int256,int256,uint256,bool,int256)");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal insuranceFund = makeAddr("insuranceFund");

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
            ) ^ (0x9999 << 144)
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

        hook.registerVAMMPool(vammPoolKey);
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        hook.registerSpotPool(spotPoolKey);
        hook.setClearingHouse(address(clearingHouse));

        accountBalance.setClearingHouse(address(clearingHouse));
        accountBalance.setVault(address(vault));

        clearingHouse.setVault(vault);
        clearingHouse.setFundingRate(fundingRate);
        vault.setClearingHouse(address(clearingHouse));
        vault.setInsuranceFund(insuranceFund);
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
    }

    function testLiquidationWithUsdcOnlyCollateral() public {
        vm.prank(alice);
        vault.deposit(27e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 80e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        priceOracle.setPriceX18(0.7e18);
        accountBalance.setMarkPriceX18(vammPoolId, 0.7e18);
        assertTrue(vault.isLiquidatable(alice));

        int256 bobBefore = vault.usdcBalance(bob);
        vm.prank(bob);
        (int256 liquidatedSize, uint256 penalty) = clearingHouse.liquidate(alice);

        assertGt(PerpMath.abs(liquidatedSize), 0);
        assertGt(penalty, 0);
        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);
        assertGt(vault.usdcBalance(bob), bobBefore);
    }

    function testLiquidationWithLpCollateralRemovesLpPosition() public {
        uint256 tokenId = _mintSpotFullRangeFor(alice, 2_000e18);
        vm.prank(alice);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(alice);
        vault.depositLP(tokenId);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 5_000e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        priceOracle.setPriceX18(0.2e18);
        accountBalance.setMarkPriceX18(vammPoolId, 0.2e18);
        assertTrue(vault.isLiquidatable(alice));

        (,,,, uint128 liquidityBefore) = vault.lpCollaterals(tokenId);
        vm.prank(bob);
        clearingHouse.liquidate(alice);

        int256 positionAfter = accountBalance.getTakerPositionSize(alice, vammPoolId);
        assertEq(positionAfter, 0);

        uint256[] memory lpIds = vault.getUserLPTokenIds(alice);
        if (lpIds.length == 0) {
            assertEq(vault.getLPCollateralValue(alice), 0);
        } else {
            (,,,, uint128 liquidityAfter) = vault.lpCollaterals(tokenId);
            assertLt(liquidityAfter, liquidityBefore);
        }
    }

    function testCannotLiquidateHealthyPosition() public {
        vm.prank(alice);
        vault.deposit(100e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 10e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.NotLiquidatable.selector, alice));
        vm.prank(bob);
        clearingHouse.liquidate(alice);
    }

    function testPartialPerpLiquidationWhenMarginAboveHalfMm() public {
        vm.prank(alice);
        vault.deposit(28e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 200e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        priceOracle.setPriceX18(0.9e18);
        accountBalance.setMarkPriceX18(vammPoolId, 0.9e18);
        assertTrue(vault.isLiquidatable(alice));

        int256 positionBefore = accountBalance.getTakerPositionSize(alice, vammPoolId);
        vm.prank(bob);
        clearingHouse.liquidate(alice);
        int256 positionAfter = accountBalance.getTakerPositionSize(alice, vammPoolId);

        assertGt(PerpMath.abs(positionAfter), 0);
        assertLt(PerpMath.abs(positionAfter), PerpMath.abs(positionBefore));
    }

    function testLiquidationEventHasCompletionFlagForFull() public {
        vm.prank(alice);
        vault.deposit(27e18);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 80e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        priceOracle.setPriceX18(0.7e18);
        accountBalance.setMarkPriceX18(vammPoolId, 0.7e18);
        assertTrue(vault.isLiquidatable(alice));

        vm.recordLogs();
        vm.prank(bob);
        clearingHouse.liquidate(alice);

        (bool found, bool isFullyLiquidated, int256 remainingPositionSize) =
            _lastPositionLiquidated(vm.getRecordedLogs());
        assertTrue(found);
        assertTrue(isFullyLiquidated);
        assertEq(remainingPositionSize, 0);
    }

    function testLiquidationEventHasCompletionFlagForPartial() public {
        vm.prank(alice);
        vault.deposit(28e18);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 200e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        priceOracle.setPriceX18(0.9e18);
        accountBalance.setMarkPriceX18(vammPoolId, 0.9e18);
        assertTrue(vault.isLiquidatable(alice));

        vm.recordLogs();
        vm.prank(bob);
        clearingHouse.liquidate(alice);

        (bool found, bool isFullyLiquidated, int256 remainingPositionSize) =
            _lastPositionLiquidated(vm.getRecordedLogs());
        assertTrue(found);
        assertFalse(isFullyLiquidated);
        assertTrue(remainingPositionSize != 0);
    }

    function testLiquidationUpdatesFundingSnapshot() public {
        vm.prank(alice);
        vault.deposit(27e18);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 80e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        priceOracle.setPriceX18(0.7e18);
        assertTrue(vault.isLiquidatable(alice));

        vm.warp(block.timestamp + 1 days);

        int256 pendingFunding = fundingRate.getPendingFundingPayment(alice, vammPoolId);
        assertGt(pendingFunding, 0);
        int256 beforeSnapshot = accountBalance.getLastTwPremiumGrowthGlobalX96(alice, vammPoolId);

        vm.prank(bob);
        clearingHouse.liquidate(alice);
        int256 afterSnapshot = accountBalance.getLastTwPremiumGrowthGlobalX96(alice, vammPoolId);

        assertGt(afterSnapshot, beforeSnapshot);
    }

    function testLiquidationSyncsMarkPriceFromVault() public {
        vm.prank(alice);
        vault.deposit(27e18);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 80e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        accountBalance.setMarkPriceX18(vammPoolId, 2e18);
        priceOracle.setPriceX18(0.7e18);

        vm.prank(bob);
        clearingHouse.liquidate(alice);

        assertEq(accountBalance.getMarkPriceX18(vammPoolId), 0.7e18);
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

    function _lastPositionLiquidated(Vm.Log[] memory logs)
        internal
        view
        returns (bool found, bool isFullyLiquidated, int256 remainingPositionSize)
    {
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(clearingHouse) || entry.topics.length == 0) continue;
            if (entry.topics[0] != POSITION_LIQUIDATED_SIG) continue;

            (int256 liquidatedPositionSize, int256 realizedPnl, uint256 penalty, bool full, int256 remaining) =
                abi.decode(entry.data, (int256, int256, uint256, bool, int256));
            liquidatedPositionSize;
            realizedPnl;
            penalty;
            return (true, full, remaining);
        }
    }
}
