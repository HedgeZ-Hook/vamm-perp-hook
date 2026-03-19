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
import {PerpMath} from "../src/libraries/PerpMath.sol";

contract VaultTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    address internal alice = makeAddr("alice");

    VirtualToken internal veth;
    VirtualToken internal vusdc;
    PerpHook internal hook;
    Config internal config;
    AccountBalance internal accountBalance;
    ClearingHouse internal clearingHouse;
    MockPriceOracle internal priceOracle;
    Vault internal vault;
    MockERC20 internal usdc;
    PoolKey internal spotPoolKey;
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
            ) ^ (0x7777 << 144)
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
        vammPoolId = vammPoolKey.toId();
        baseCurrency = Currency.wrap(address(veth));
        quoteCurrency = Currency.wrap(address(vusdc));

        config = new Config();
        accountBalance = new AccountBalance(config);
        clearingHouse = new ClearingHouse(poolManager, accountBalance, config, vammPoolKey, baseCurrency, quoteCurrency);
        hook.registerVAMMPool(vammPoolKey, address(veth), address(vusdc));
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        hook.setClearingHouse(address(clearingHouse));
        accountBalance.setClearingHouse(address(clearingHouse));

        usdc = new MockERC20("USD Coin", "USDC", 18);
        priceOracle = new MockPriceOracle(3_000e18);
        spotPoolKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), 3000, 60, IHooks(address(0)));
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
        vault.setClearingHouse(address(clearingHouse));
        accountBalance.setVault(address(vault));
        clearingHouse.setVault(vault);

        veth.addWhitelist(address(clearingHouse));
        vusdc.addWhitelist(address(clearingHouse));
        veth.transfer(address(clearingHouse), 1_000_000e18);
        vusdc.transfer(address(clearingHouse), 10_000_000_000e18);

        poolManager.initialize(vammPoolKey, Constants.SQRT_PRICE_1_1);
        _mintFullRange(vammPoolKey, 1_000e18);

        usdc.mint(alice, 1_000_000e18);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function testDepositAndWithdraw() public {
        vm.prank(alice);
        vault.deposit(10_000e18);
        assertEq(vault.usdcBalance(alice), 10_000e18);

        vm.prank(alice);
        vault.withdraw(5_000e18);
        assertEq(vault.usdcBalance(alice), 5_000e18);

        vm.expectRevert();
        vm.prank(alice);
        vault.withdraw(6_000e18);
    }

    function testMarginCheckOnOpenPosition() public {
        vm.prank(alice);
        vault.deposit(1_000e18);

        vm.expectRevert();
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 10e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );
        assertEq(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 3e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );
        assertGt(accountBalance.getTakerPositionSize(alice, vammPoolId), 0);
    }

    function testCannotWithdrawBelowMargin() public {
        vm.prank(alice);
        vault.deposit(2_000e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 5e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.expectRevert();
        vm.prank(alice);
        vault.withdraw(1_000e18);

        vm.prank(alice);
        vault.withdraw(400e18);
        assertEq(vault.usdcBalance(alice), 1_600e18);
    }

    function testUnrealizedPnlAffectsAccountValue() public {
        vm.prank(alice);
        vault.deposit(1_000e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 1e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        int256 positionSize = accountBalance.getTakerPositionSize(alice, vammPoolId);
        assertGt(positionSize, 0);

        priceOracle.setPriceX18(3_500e18);
        int256 accountValueHigh = vault.getAccountValue(alice);

        priceOracle.setPriceX18(2_500e18);
        int256 accountValueLow = vault.getAccountValue(alice);

        assertGt(accountValueHigh, accountValueLow);
        int256 expectedDelta = PerpMath.mulDiv(positionSize, 1_000e18, 1e18);
        assertEq(accountValueHigh - accountValueLow, expectedDelta);
    }

    function testMarginCheckOnClosePositionWithMmRatio() public {
        vm.prank(alice);
        vault.deposit(1_000e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 3e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        config.setMmRatio(900_000);

        vm.expectRevert();
        vm.prank(alice);
        clearingHouse.closePosition(1e18, 0, Constants.ZERO_BYTES);
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
