// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

contract LPTableTestingTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q192 = 2 ** 192;
    uint256 internal constant INIT_PRICE_X18 = 2_300e18;
    uint128 internal constant SPOT_LP_LIQUIDITY = 4_795_831_523_312;

    struct OpenCase {
        string name;
        bool isBaseToQuote;
        uint256 amount;
        int8 expectedSign;
    }

    struct ScaleCase {
        string name;
        bool firstIsBaseToQuote;
        uint256 firstAmount;
        bool secondIsBaseToQuote;
        uint256 secondAmount;
        int8 expectedFinalSign;
        int8 absRelationToBeforeSecond; // 1: larger, -1: smaller
    }

    struct CloseCase {
        string name;
        bool isBaseToQuote;
        uint256 openAmount;
        uint256 closeAmount; // 0 = close all
        bool expectFlat;
        int8 expectedRemainingSign;
    }

    struct LiquidationCase {
        string name;
        bool isBaseToQuote;
        uint256 openAmount;
        uint256 oracleAfterX18;
        bool expectFullLiquidation;
        int8 expectedSignWhenPartial;
    }

    address internal liquidator = makeAddr("liquidator");

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
            ) ^ (0x7171 << 144)
        );
        deployCodeTo("PerpHook.sol:PerpHook", abi.encode(poolManager, address(this)), flags);
        hook = PerpHook(flags);

        veth = new VirtualToken("Virtual ETH", "vETH");
        vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        usdc = new MockERC20("USD Coin", "USDC", 6);

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
        priceOracle = new MockPriceOracle(INIT_PRICE_X18);
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
        hook.registerSpotPool(spotPoolKey);
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);
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

        poolManager.initialize(vammPoolKey, _vammInitSqrtPriceX96(INIT_PRICE_X18));
        poolManager.initialize(spotPoolKey, _priceX18ToSqrtPriceX96(INIT_PRICE_X18, 18, 6));
        _mintVammFullRange(vammPoolKey, 1_000_000e18);

        _fundAndApproveUsdc(liquidator, 10_000_000e6);
    }

    function testTable_LpOpenLongShort() public {
        OpenCase[] memory cases = new OpenCase[](6);
        cases[0] = OpenCase({name: "lp_open_long_0_1", isBaseToQuote: false, amount: 0.1e18, expectedSign: 1});
        cases[1] = OpenCase({name: "lp_open_long_0_5", isBaseToQuote: false, amount: 0.5e18, expectedSign: 1});
        cases[2] = OpenCase({name: "lp_open_long_1_2", isBaseToQuote: false, amount: 1.2e18, expectedSign: 1});
        cases[3] = OpenCase({name: "lp_open_short_0_1", isBaseToQuote: true, amount: 0.1e18, expectedSign: -1});
        cases[4] = OpenCase({name: "lp_open_short_0_5", isBaseToQuote: true, amount: 0.5e18, expectedSign: -1});
        cases[5] = OpenCase({name: "lp_open_short_1_2", isBaseToQuote: true, amount: 1.2e18, expectedSign: -1});

        for (uint256 i = 0; i < cases.length; i++) {
            uint256 snap = vm.snapshotState();
            address trader = _prepareLpTrader(i + 1);
            emit log_named_string("case", cases[i].name);

            (int256 baseDelta, int256 quoteDelta) = _openPosition(trader, cases[i].isBaseToQuote, cases[i].amount);
            _assertBaseQuoteDirection(cases[i].isBaseToQuote, baseDelta, quoteDelta);
            assertEq(PerpMath.abs(baseDelta), cases[i].amount);

            int256 positionSize = accountBalance.getTakerPositionSize(trader, vammPoolId);
            int256 openNotional = accountBalance.getTakerOpenNotional(trader, vammPoolId);
            _assertSign(positionSize, cases[i].expectedSign);
            assertEq(positionSize, baseDelta);
            assertEq(openNotional, quoteDelta);
            assertEq(vault.getNetCashBalance(trader), 0);
            assertEq(accountBalance.getActivePoolIds(trader).length, 1);
            assertEq(vault.getUserLPTokenIds(trader).length, 1);
            assertTrue(vault.hasLPCollateral(trader));
            assertGt(vault.getLPCollateralValue(trader), 100e18);
            uint256 entryPriceX18 = Math.mulDiv(PerpMath.abs(quoteDelta), 1e18, PerpMath.abs(baseDelta));
            assertGt(entryPriceX18, 1_000e18);
            assertLt(entryPriceX18, 5_000e18);
            assertGe(vault.getFreeCollateral(trader), 0);
            vm.revertToState(snap);
        }
    }

    function testTable_LpScaleInAndFlip() public {
        ScaleCase[] memory cases = new ScaleCase[](6);
        cases[0] = ScaleCase({
            name: "long_then_long",
            firstIsBaseToQuote: false,
            firstAmount: 0.4e18,
            secondIsBaseToQuote: false,
            secondAmount: 0.3e18,
            expectedFinalSign: 1,
            absRelationToBeforeSecond: 1
        });
        cases[1] = ScaleCase({
            name: "short_then_short",
            firstIsBaseToQuote: true,
            firstAmount: 0.4e18,
            secondIsBaseToQuote: true,
            secondAmount: 0.3e18,
            expectedFinalSign: -1,
            absRelationToBeforeSecond: 1
        });
        cases[2] = ScaleCase({
            name: "long_then_partial_short",
            firstIsBaseToQuote: false,
            firstAmount: 0.6e18,
            secondIsBaseToQuote: true,
            secondAmount: 0.2e18,
            expectedFinalSign: 1,
            absRelationToBeforeSecond: -1
        });
        cases[3] = ScaleCase({
            name: "short_then_flip_long",
            firstIsBaseToQuote: true,
            firstAmount: 0.4e18,
            secondIsBaseToQuote: false,
            secondAmount: 0.7e18,
            expectedFinalSign: 1,
            absRelationToBeforeSecond: -1
        });
        cases[4] = ScaleCase({
            name: "long_then_flip_short",
            firstIsBaseToQuote: false,
            firstAmount: 0.4e18,
            secondIsBaseToQuote: true,
            secondAmount: 0.9e18,
            expectedFinalSign: -1,
            absRelationToBeforeSecond: 1
        });
        cases[5] = ScaleCase({
            name: "short_then_partial_long",
            firstIsBaseToQuote: true,
            firstAmount: 0.8e18,
            secondIsBaseToQuote: false,
            secondAmount: 0.2e18,
            expectedFinalSign: -1,
            absRelationToBeforeSecond: -1
        });

        for (uint256 i = 0; i < cases.length; i++) {
            uint256 snap = vm.snapshotState();
            _runScaleCase(cases[i], 100 + i);
            vm.revertToState(snap);
        }
    }

    function testTable_LpClosePosition() public {
        CloseCase[] memory cases = new CloseCase[](6);
        cases[0] = CloseCase({
            name: "close_full_long",
            isBaseToQuote: false,
            openAmount: 0.6e18,
            closeAmount: 0,
            expectFlat: true,
            expectedRemainingSign: 0
        });
        cases[1] = CloseCase({
            name: "close_full_short",
            isBaseToQuote: true,
            openAmount: 0.6e18,
            closeAmount: 0,
            expectFlat: true,
            expectedRemainingSign: 0
        });
        cases[2] = CloseCase({
            name: "close_partial_long",
            isBaseToQuote: false,
            openAmount: 0.8e18,
            closeAmount: 0.3e18,
            expectFlat: false,
            expectedRemainingSign: 1
        });
        cases[3] = CloseCase({
            name: "close_partial_short",
            isBaseToQuote: true,
            openAmount: 0.8e18,
            closeAmount: 0.3e18,
            expectFlat: false,
            expectedRemainingSign: -1
        });
        cases[4] = CloseCase({
            name: "close_partial_long_large",
            isBaseToQuote: false,
            openAmount: 1.4e18,
            closeAmount: 0.8e18,
            expectFlat: false,
            expectedRemainingSign: 1
        });
        cases[5] = CloseCase({
            name: "close_partial_short_large",
            isBaseToQuote: true,
            openAmount: 1.4e18,
            closeAmount: 0.8e18,
            expectFlat: false,
            expectedRemainingSign: -1
        });

        for (uint256 i = 0; i < cases.length; i++) {
            uint256 snap = vm.snapshotState();
            _runCloseCase(cases[i], 200 + i);
            vm.revertToState(snap);
        }
    }

    function testTable_LpLiquidationLongShort() public {
        LiquidationCase[] memory cases = new LiquidationCase[](4);
        cases[0] = LiquidationCase({
            name: "liquidate_long_when_price_crashes",
            isBaseToQuote: false,
            openAmount: 1.5e18,
            oracleAfterX18: 1_200e18,
            expectFullLiquidation: true,
            expectedSignWhenPartial: 1
        });
        cases[1] = LiquidationCase({
            name: "liquidate_short_when_price_spikes",
            isBaseToQuote: true,
            openAmount: 1.5e18,
            oracleAfterX18: 4_000e18,
            expectFullLiquidation: true,
            expectedSignWhenPartial: -1
        });
        cases[2] = LiquidationCase({
            name: "partial_liquidate_long",
            isBaseToQuote: false,
            openAmount: 1.95e18,
            oracleAfterX18: 2_150e18,
            expectFullLiquidation: false,
            expectedSignWhenPartial: 1
        });
        cases[3] = LiquidationCase({
            name: "partial_liquidate_short",
            isBaseToQuote: true,
            openAmount: 1.95e18,
            oracleAfterX18: 2_450e18,
            expectFullLiquidation: false,
            expectedSignWhenPartial: -1
        });

        for (uint256 i = 0; i < cases.length; i++) {
            uint256 snap = vm.snapshotState();
            address trader = _prepareLpTrader(300 + i);
            emit log_named_string("case", cases[i].name);

            priceOracle.setPriceX18(INIT_PRICE_X18);
            (int256 baseOpen,) = _openPosition(trader, cases[i].isBaseToQuote, cases[i].openAmount);
            int256 positionBefore = accountBalance.getTakerPositionSize(trader, vammPoolId);
            assertEq(positionBefore, baseOpen);
            assertFalse(vault.isLiquidatable(trader));

            priceOracle.setPriceX18(cases[i].oracleAfterX18);
            assertTrue(vault.isLiquidatable(trader));

            vm.prank(liquidator);
            (bool isFullyLiquidated, uint256 liquidatedSize, uint256 penalty) = clearingHouse.liquidate(trader);

            assertGt(liquidatedSize, 0);
            assertGt(penalty, 0);
            assertLe(liquidatedSize, PerpMath.abs(positionBefore));
            assertEq(isFullyLiquidated, cases[i].expectFullLiquidation);

            int256 positionAfter = accountBalance.getTakerPositionSize(trader, vammPoolId);
            if (cases[i].expectFullLiquidation) {
                assertEq(positionAfter, 0);
                assertEq(liquidatedSize, PerpMath.abs(positionBefore));
                assertEq(accountBalance.getActivePoolIds(trader).length, 0);
            } else {
                assertTrue(positionAfter != 0);
                _assertSign(positionAfter, cases[i].expectedSignWhenPartial);
                assertEq(PerpMath.abs(positionAfter), PerpMath.abs(positionBefore) - liquidatedSize);
                assertGt(accountBalance.getActivePoolIds(trader).length, 0);
            }
            vm.revertToState(snap);
        }
    }

    function _prepareLpTrader(uint256 seed) internal returns (address trader) {
        trader = vm.addr(uint256(keccak256(abi.encodePacked("table-trader", seed))));
        _fundAndApproveUsdc(trader, 10_000_000e6);

        uint256 tokenId = _mintSpotFullRangeFor(trader, SPOT_LP_LIQUIDITY);
        vm.prank(trader);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(trader);
        vault.depositLP(tokenId);
    }

    function _openPosition(address trader, bool isBaseToQuote, uint256 amount)
        internal
        returns (int256 baseDelta, int256 quoteDelta)
    {
        vm.prank(trader);
        (baseDelta, quoteDelta) = clearingHouse.openPosition(
            IClearingHouse.OpenPositionParams({
                isBaseToQuote: isBaseToQuote, amount: amount, sqrtPriceLimitX96: 0, hookData: Constants.ZERO_BYTES
            })
        );
    }

    function _runCloseCase(CloseCase memory c, uint256 seed) internal {
        address trader = _prepareLpTrader(seed);
        emit log_named_string("case", c.name);

        (int256 baseOpen, int256 quoteOpen) = _openPosition(trader, c.isBaseToQuote, c.openAmount);
        _assertBaseQuoteDirection(c.isBaseToQuote, baseOpen, quoteOpen);
        int256 positionBefore = accountBalance.getTakerPositionSize(trader, vammPoolId);
        int256 openNotionalBefore = accountBalance.getTakerOpenNotional(trader, vammPoolId);
        int256 owedBefore = accountBalance.getOwedRealizedPnl(trader);
        assertEq(positionBefore, baseOpen);
        assertEq(openNotionalBefore, quoteOpen);

        vm.prank(trader);
        (int256 baseClose, int256 quoteClose) = clearingHouse.closePosition(c.closeAmount, 0, Constants.ZERO_BYTES);

        int256 positionAfter = accountBalance.getTakerPositionSize(trader, vammPoolId);
        int256 openNotionalAfter = accountBalance.getTakerOpenNotional(trader, vammPoolId);
        int256 owedAfter = accountBalance.getOwedRealizedPnl(trader);

        _assertCloseAccounting(
            positionBefore,
            openNotionalBefore,
            owedBefore,
            baseClose,
            quoteClose,
            positionAfter,
            openNotionalAfter,
            owedAfter
        );
        if (c.closeAmount != 0) assertEq(PerpMath.abs(baseClose), c.closeAmount);

        if (c.expectFlat) {
            assertEq(positionAfter, 0);
            assertEq(openNotionalAfter, 0);
            assertEq(accountBalance.getActivePoolIds(trader).length, 0);
        } else {
            _assertSign(positionAfter, c.expectedRemainingSign);
            assertEq(PerpMath.abs(positionAfter), PerpMath.abs(positionBefore) - PerpMath.abs(baseClose));
            assertGt(accountBalance.getActivePoolIds(trader).length, 0);
        }
    }

    function _runScaleCase(ScaleCase memory c, uint256 seed) internal {
        address trader = _prepareLpTrader(seed);
        emit log_named_string("case", c.name);

        (int256 base1, int256 quote1) = _openPosition(trader, c.firstIsBaseToQuote, c.firstAmount);
        _assertBaseQuoteDirection(c.firstIsBaseToQuote, base1, quote1);
        assertEq(PerpMath.abs(base1), c.firstAmount);
        int256 positionBeforeSecond = accountBalance.getTakerPositionSize(trader, vammPoolId);
        int256 openNotionalBeforeSecond = accountBalance.getTakerOpenNotional(trader, vammPoolId);
        assertEq(positionBeforeSecond, base1);
        assertEq(openNotionalBeforeSecond, quote1);

        (int256 base2, int256 quote2) = _openPosition(trader, c.secondIsBaseToQuote, c.secondAmount);
        _assertBaseQuoteDirection(c.secondIsBaseToQuote, base2, quote2);
        assertEq(PerpMath.abs(base2), c.secondAmount);
        int256 positionAfterSecond = accountBalance.getTakerPositionSize(trader, vammPoolId);
        int256 openNotionalAfterSecond = accountBalance.getTakerOpenNotional(trader, vammPoolId);

        _assertSign(positionAfterSecond, c.expectedFinalSign);
        assertEq(positionAfterSecond, positionBeforeSecond + base2);
        assertEq(openNotionalAfterSecond, openNotionalBeforeSecond + quote2);

        uint256 absBefore = PerpMath.abs(positionBeforeSecond);
        uint256 absAfter = PerpMath.abs(positionAfterSecond);
        if (c.absRelationToBeforeSecond > 0) {
            assertGt(absAfter, absBefore);
        } else if (c.absRelationToBeforeSecond < 0) {
            assertLt(absAfter, absBefore);
        }

        uint256 expectedAbsAfter;
        if (c.firstIsBaseToQuote == c.secondIsBaseToQuote) {
            expectedAbsAfter = c.firstAmount + c.secondAmount;
        } else if (c.firstAmount > c.secondAmount) {
            expectedAbsAfter = c.firstAmount - c.secondAmount;
        } else {
            expectedAbsAfter = c.secondAmount - c.firstAmount;
        }
        assertEq(absAfter, expectedAbsAfter);
    }

    function _assertCloseAccounting(
        int256 positionBefore,
        int256 openNotionalBefore,
        int256 owedBefore,
        int256 baseClose,
        int256 quoteClose,
        int256 positionAfter,
        int256 openNotionalAfter,
        int256 owedAfter
    ) internal pure {
        if (positionBefore > 0) {
            assertLt(baseClose, 0);
        } else {
            assertGt(baseClose, 0);
        }

        assertEq(positionAfter, positionBefore + baseClose);

        uint256 closeRatioX18 = Math.mulDiv(PerpMath.abs(baseClose), 1e18, PerpMath.abs(positionBefore));
        int256 closedOpenNotional = PerpMath.mulDiv(openNotionalBefore, int256(closeRatioX18), 1e18);
        int256 expectedOpenNotionalAfter = openNotionalBefore - closedOpenNotional;
        _assertApproxEqAbsInt(openNotionalAfter, expectedOpenNotionalAfter, 2);

        int256 realizedPnl = quoteClose + closedOpenNotional;
        _assertApproxEqAbsInt(owedAfter, owedBefore + realizedPnl, 2);
    }

    function _assertSign(int256 value, int8 expectedSign) internal pure {
        if (expectedSign > 0) {
            assertGt(value, 0);
        } else if (expectedSign < 0) {
            assertLt(value, 0);
        } else {
            assertEq(value, 0);
        }
    }

    function _assertBaseQuoteDirection(bool isBaseToQuote, int256 baseDelta, int256 quoteDelta) internal pure {
        if (isBaseToQuote) {
            assertLt(baseDelta, 0);
            assertGt(quoteDelta, 0);
        } else {
            assertGt(baseDelta, 0);
            assertLt(quoteDelta, 0);
        }
    }

    function _assertApproxEqAbsInt(int256 a, int256 b, uint256 maxDiff) internal pure {
        uint256 diff = a >= b ? uint256(a - b) : uint256(b - a);
        assertLe(diff, maxDiff);
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
            _vammInitSqrtPriceX96(INIT_PRICE_X18),
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
        uint160 sqrtPriceX96 = _priceX18ToSqrtPriceX96(INIT_PRICE_X18, 18, 6);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
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

    function _vammInitSqrtPriceX96(uint256 quotePerBaseX18) internal view returns (uint160) {
        uint256 rawPriceX18 =
            Currency.unwrap(vammPoolKey.currency0) == address(veth) ? quotePerBaseX18 : 1e36 / quotePerBaseX18;
        return _priceX18ToSqrtPriceX96(rawPriceX18, 18, 18);
    }

    function _priceX18ToSqrtPriceX96(uint256 priceX18, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        uint256 rawPriceX18 = FullMath.mulDiv(priceX18, 10 ** quoteDecimals, 10 ** baseDecimals);
        uint256 ratioX192 = FullMath.mulDiv(rawPriceX18, Q192, 1e18);
        sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
    }
}
