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
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";

contract InsuranceFundTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
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
            ) ^ (0xbbbb << 144)
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
        insuranceFund = new InsuranceFund(vault, IERC20(address(usdc)), treasury, 100e18);

        hook.registerVAMMPool(vammPoolKey, address(veth), address(vusdc));
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        hook.registerSpotPool(spotPoolKey);
        hook.setClearingHouse(address(clearingHouse));

        accountBalance.setClearingHouse(address(clearingHouse));
        accountBalance.setVault(address(vault));

        clearingHouse.setVault(vault);
        vault.setClearingHouse(address(clearingHouse));
        vault.setInsuranceFund(address(insuranceFund));

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

    function testInsuranceFundReceivesTradingFees() public {
        config.setInsuranceFundFeeRatio(10_000);

        vm.prank(alice);
        vault.deposit(1_000e18);

        int256 before = accountBalance.getOwedRealizedPnl(address(insuranceFund));
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 100e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );
        int256 afterValue = accountBalance.getOwedRealizedPnl(address(insuranceFund));

        assertGt(afterValue, before);
    }

    function testInsuranceFundReceivesLiquidationPenaltyShare() public {
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

        int256 before = vault.usdcBalance(address(insuranceFund));
        vm.prank(bob);
        clearingHouse.liquidate(alice);
        int256 afterValue = vault.usdcBalance(address(insuranceFund));

        assertGt(afterValue, before);
    }

    function testInsuranceFundCoversBadDebt() public {
        usdc.mint(address(insuranceFund), 500e18);
        vm.prank(address(insuranceFund));
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(address(insuranceFund));
        vault.deposit(500e18);

        vm.prank(alice);
        vault.deposit(10e18);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 80e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        priceOracle.setPriceX18(0.5e18);
        accountBalance.setMarkPriceX18(vammPoolId, 0.5e18);
        assertTrue(vault.isLiquidatable(alice));

        int256 ifBefore = vault.usdcBalance(address(insuranceFund));
        vm.prank(bob);
        clearingHouse.liquidate(alice);
        int256 ifAfter = vault.usdcBalance(address(insuranceFund));

        assertLt(ifAfter, ifBefore);
        assertEq(vault.getNetCashBalance(alice), 0);
    }

    function testInsuranceFundCapacity() public {
        config.setInsuranceFundFeeRatio(10_000);
        usdc.mint(address(insuranceFund), 200e18);

        vm.prank(alice);
        vault.deposit(1_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 100e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        int256 expected = vault.getAccountValue(address(insuranceFund)) + int256(usdc.balanceOf(address(insuranceFund)));
        int256 capacity = insuranceFund.getInsuranceFundCapacity();
        assertEq(capacity, expected);
    }

    function testDistributeFeeCapsByVaultWithdrawableCollateral() public {
        uint256 threshold = insuranceFund.distributionThreshold();
        uint256 vaultBalance = 20e18;
        uint256 walletBalance = threshold + 100e18;

        usdc.mint(address(insuranceFund), walletBalance + vaultBalance);
        vm.startPrank(address(insuranceFund));
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(vaultBalance);
        vm.stopPrank();

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 distributed = insuranceFund.distributeFee();

        assertEq(distributed, vaultBalance);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, vaultBalance);
    }

    function testRepayUsesWalletBalanceToCoverNegativeVaultAccount() public {
        vm.prank(address(clearingHouse));
        accountBalance.modifyOwedRealizedPnl(address(insuranceFund), -100e18);

        usdc.mint(address(insuranceFund), 60e18);
        uint256 walletBefore = usdc.balanceOf(address(insuranceFund));
        assertEq(walletBefore, 60e18);

        uint256 repaid = insuranceFund.repay();
        assertEq(repaid, 60e18);
        assertEq(vault.usdcBalance(address(insuranceFund)), 60e18);
        assertEq(usdc.balanceOf(address(insuranceFund)), 0);
    }

    function testWithdrawAutoPullsUsdcFromInsuranceFundWhenVaultWalletIsShort() public {
        uint256 pnlToWithdraw = 5e18;
        vm.prank(address(clearingHouse));
        accountBalance.modifyOwedRealizedPnl(alice, int256(pnlToWithdraw));

        usdc.mint(address(insuranceFund), pnlToWithdraw);
        assertEq(usdc.balanceOf(address(vault)), 0);

        uint256 aliceWalletBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(pnlToWithdraw);

        assertEq(usdc.balanceOf(alice) - aliceWalletBefore, pnlToWithdraw);
        assertEq(usdc.balanceOf(address(insuranceFund)), 0);
        assertEq(vault.getNetCashBalance(alice), 0);
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
}
