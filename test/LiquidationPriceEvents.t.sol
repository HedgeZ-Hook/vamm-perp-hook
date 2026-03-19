// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

contract LiquidationPriceEventsTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant LIQUIDATION_PRICE_CHANGE_SIG = keccak256("LiquidationPriceChange(address,uint256,bool)");

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

    function setUp() public {
        deployArtifactsAndLabel();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x2121 << 144)
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

        spotPoolKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), 3000, 60, IHooks(address(0)));

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

        hook.registerVAMMPool(vammPoolKey, address(veth), address(vusdc));
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
        hook.setClearingHouse(address(clearingHouse));

        accountBalance.setClearingHouse(address(clearingHouse));
        accountBalance.setVault(address(vault));

        clearingHouse.setVault(vault);
        vault.setClearingHouse(address(clearingHouse));

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

    function testDepositAndWithdrawEmitLiquidationPriceChange() public {
        vm.recordLogs();
        vm.prank(alice);
        vault.deposit(2_000e18);
        (bool foundOnDeposit, uint256 liqOnDeposit, bool wasLiquidatedOnDeposit) =
            _lastLiquidationPriceEvent(vm.getRecordedLogs(), alice);
        assertTrue(foundOnDeposit);
        assertEq(liqOnDeposit, 0);
        assertFalse(wasLiquidatedOnDeposit);

        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 10e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );

        vm.recordLogs();
        vm.prank(alice);
        vault.withdraw(100e18);
        (bool foundOnWithdraw, uint256 liqOnWithdraw, bool wasLiquidatedOnWithdraw) =
            _lastLiquidationPriceEvent(vm.getRecordedLogs(), alice);
        assertTrue(foundOnWithdraw);
        assertEq(liqOnWithdraw, vault.getLiquidationPriceX18(alice));
        assertFalse(wasLiquidatedOnWithdraw);
    }

    function testOpenAndCloseEmitLiquidationPriceChange() public {
        vm.prank(alice);
        vault.deposit(2_000e18);

        vm.recordLogs();
        vm.prank(alice);
        clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: false, amount: 10e18, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );
        (bool foundOnOpen, uint256 liqOnOpen, bool wasLiquidatedOnOpen) =
            _lastLiquidationPriceEvent(vm.getRecordedLogs(), alice);
        assertTrue(foundOnOpen);
        assertEq(liqOnOpen, vault.getLiquidationPriceX18(alice));
        assertFalse(wasLiquidatedOnOpen);

        vm.recordLogs();
        vm.prank(alice);
        clearingHouse.closePosition(0, 0, Constants.ZERO_BYTES);
        (bool foundOnClose, uint256 liqOnClose, bool wasLiquidatedOnClose) =
            _lastLiquidationPriceEvent(vm.getRecordedLogs(), alice);
        assertTrue(foundOnClose);
        assertEq(liqOnClose, vault.getLiquidationPriceX18(alice));
        assertEq(liqOnClose, 0);
        assertFalse(wasLiquidatedOnClose);
    }

    function testLpCollateralActionsEmitLiquidationPriceChange() public {
        uint256 tokenId = _mintSpotFullRangeFor(alice, 2_000e18);
        vm.prank(alice);
        IERC721(address(positionManager)).approve(address(vault), tokenId);

        vm.recordLogs();
        vm.prank(alice);
        vault.depositLP(tokenId);
        (bool foundOnDepositLP, uint256 liqOnDepositLP, bool wasLiquidatedOnDepositLP) =
            _lastLiquidationPriceEvent(vm.getRecordedLogs(), alice);
        assertTrue(foundOnDepositLP);
        assertEq(liqOnDepositLP, vault.getLiquidationPriceX18(alice));
        assertFalse(wasLiquidatedOnDepositLP);

        (,,,, uint128 liquidityBefore) = vault.lpCollaterals(tokenId);
        vm.recordLogs();
        vm.prank(alice);
        vault.decreaseLP(tokenId, liquidityBefore / 2);
        (bool foundOnDecreaseLP, uint256 liqOnDecreaseLP, bool wasLiquidatedOnDecreaseLP) =
            _lastLiquidationPriceEvent(vm.getRecordedLogs(), alice);
        assertTrue(foundOnDecreaseLP);
        assertEq(liqOnDecreaseLP, vault.getLiquidationPriceX18(alice));
        assertFalse(wasLiquidatedOnDecreaseLP);
    }

    function testLiquidateEmitsLiquidationPriceChange() public {
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

        vm.recordLogs();
        vm.prank(bob);
        clearingHouse.liquidate(alice);
        (bool foundOnLiquidate, uint256 liqOnLiquidate, bool wasLiquidatedOnLiquidate) =
            _lastLiquidationPriceEvent(vm.getRecordedLogs(), alice);
        assertTrue(foundOnLiquidate);
        assertEq(liqOnLiquidate, vault.getLiquidationPriceX18(alice));
        assertEq(liqOnLiquidate, 0);
        assertTrue(wasLiquidatedOnLiquidate);
    }

    function testMoveBalanceEmitsLiquidationPriceChangeForBothSides() public {
        vm.prank(alice);
        vault.deposit(500e18);
        vm.prank(bob);
        vault.deposit(100e18);

        vm.recordLogs();
        vm.prank(address(clearingHouse));
        vault.moveBalance(alice, bob, 50e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool foundAlice, uint256 liqAlice, bool wasLiquidatedAlice) = _lastLiquidationPriceEvent(logs, alice);
        (bool foundBob, uint256 liqBob, bool wasLiquidatedBob) = _lastLiquidationPriceEvent(logs, bob);

        assertTrue(foundAlice);
        assertTrue(foundBob);
        assertEq(liqAlice, vault.getLiquidationPriceX18(alice));
        assertEq(liqBob, vault.getLiquidationPriceX18(bob));
        assertFalse(wasLiquidatedAlice);
        assertFalse(wasLiquidatedBob);
    }

    function testNotifyLiquidationPriceChangeOnlyClearingHouse() public {
        vm.expectRevert(abi.encodeWithSelector(Vault.Unauthorized.selector, address(this)));
        vault.notifyLiquidationPriceChange(alice, false);

        vm.recordLogs();
        vm.prank(address(clearingHouse));
        vault.notifyLiquidationPriceChange(alice, false);
        (bool found, uint256 liquidationPriceX18, bool wasLiquidated) =
            _lastLiquidationPriceEvent(vm.getRecordedLogs(), alice);
        assertTrue(found);
        assertEq(liquidationPriceX18, vault.getLiquidationPriceX18(alice));
        assertFalse(wasLiquidated);
    }

    function _lastLiquidationPriceEvent(Vm.Log[] memory logs, address trader)
        internal
        view
        returns (bool found, uint256 liquidationPriceX18, bool wasLiquidated)
    {
        bytes32 traderTopic = bytes32(uint256(uint160(trader)));
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(vault) || entry.topics.length < 2) continue;
            if (entry.topics[0] != LIQUIDATION_PRICE_CHANGE_SIG || entry.topics[1] != traderTopic) continue;
            (liquidationPriceX18, wasLiquidated) = abi.decode(entry.data, (uint256, bool));
            return (true, liquidationPriceX18, wasLiquidated);
        }
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
