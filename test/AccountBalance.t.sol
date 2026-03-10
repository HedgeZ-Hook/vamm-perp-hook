// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {Config} from "../src/Config.sol";
import {AccountBalance} from "../src/AccountBalance.sol";
import {PerpMath} from "../src/libraries/PerpMath.sol";

contract PerpMathHarness {
    function formatSqrtPriceX96ToPriceX96(uint160 value) external pure returns (uint256) {
        return PerpMath.formatSqrtPriceX96ToPriceX96(value);
    }

    function formatX10_18ToX96(uint256 value) external pure returns (uint256) {
        return PerpMath.formatX10_18ToX96(value);
    }

    function formatX96ToX10_18(uint256 value) external pure returns (uint256) {
        return PerpMath.formatX96ToX10_18(value);
    }

    function abs(int256 value) external pure returns (uint256) {
        return PerpMath.abs(value);
    }

    function neg256(int256 value) external pure returns (int256) {
        return PerpMath.neg256(value);
    }

    function neg256U(uint256 value) external pure returns (int256) {
        return PerpMath.neg256(value);
    }

    function neg128(int128 value) external pure returns (int128) {
        return PerpMath.neg128(value);
    }

    function neg128U(uint128 value) external pure returns (int128) {
        return PerpMath.neg128(value);
    }

    function divBy10_18I(int256 value) external pure returns (int256) {
        return PerpMath.divBy10_18(value);
    }

    function divBy10_18U(uint256 value) external pure returns (uint256) {
        return PerpMath.divBy10_18(value);
    }

    function subRatio(uint24 a, uint24 b) external pure returns (uint24) {
        return PerpMath.subRatio(a, b);
    }

    function mulDiv(int256 a, int256 b, uint256 denominator) external pure returns (int256) {
        return PerpMath.mulDiv(a, b, denominator);
    }

    function mulRatio(uint256 value, uint24 ratio) external pure returns (uint256) {
        return PerpMath.mulRatio(value, ratio);
    }

    function mulRatioI(int256 value, uint24 ratio) external pure returns (int256) {
        return PerpMath.mulRatio(value, ratio);
    }

    function divRatio(uint256 value, uint24 ratio) external pure returns (uint256) {
        return PerpMath.divRatio(value, ratio);
    }

    function min(int256 a, int256 b) external pure returns (int256) {
        return PerpMath.min(a, b);
    }

    function max(int256 a, int256 b) external pure returns (int256) {
        return PerpMath.max(a, b);
    }

    function findMedianOfThree(uint256 v1, uint256 v2, uint256 v3) external pure returns (uint256) {
        return PerpMath.findMedianOfThree(v1, v2, v3);
    }
}

contract AccountBalanceTest is Test {
    address internal clearingHouse = makeAddr("clearingHouse");
    address internal vault = makeAddr("vault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    Config internal config;
    AccountBalance internal accountBalance;
    PerpMathHarness internal perpMathHarness;

    PoolId internal poolA = PoolId.wrap(keccak256("poolA"));
    PoolId internal poolB = PoolId.wrap(keccak256("poolB"));

    function setUp() public {
        config = new Config();
        accountBalance = new AccountBalance(config);
        accountBalance.setClearingHouse(clearingHouse);
        accountBalance.setVault(vault);

        perpMathHarness = new PerpMathHarness();
    }

    function testModifyTakerBalanceAndLifecycle() public {
        vm.startPrank(clearingHouse);
        accountBalance.modifyTakerBalance(alice, poolA, 10e18, -30_000e18);
        accountBalance.modifyTakerBalance(alice, poolA, -5e18, 16_000e18);
        vm.stopPrank();

        assertEq(accountBalance.getTakerPositionSize(alice, poolA), 5e18);
        assertEq(accountBalance.getTakerOpenNotional(alice, poolA), -14_000e18);

        vm.prank(clearingHouse);
        accountBalance.modifyTakerBalance(alice, poolA, -10e18, 25_000e18);

        assertEq(accountBalance.getTakerPositionSize(alice, poolA), -5e18);
        assertEq(accountBalance.getTakerOpenNotional(alice, poolA), 11_000e18);

        vm.prank(clearingHouse);
        accountBalance.modifyTakerBalance(alice, poolA, 5e18, -11_000e18);

        assertEq(accountBalance.getTakerPositionSize(alice, poolA), 0);
        assertEq(accountBalance.getTakerOpenNotional(alice, poolA), 0);
        assertEq(accountBalance.getActivePoolIds(alice).length, 0);
    }

    function testSettleAndPnlFlow() public {
        vm.prank(clearingHouse);
        accountBalance.modifyTakerBalance(alice, poolA, 1e18, -3_000e18);

        vm.prank(clearingHouse);
        accountBalance.settleBalanceAndDeregister(alice, poolA, -1e18, 3_000e18, 200e18);

        assertEq(accountBalance.getTakerPositionSize(alice, poolA), 0);
        assertEq(accountBalance.getTakerOpenNotional(alice, poolA), 0);
        assertEq(accountBalance.owedRealizedPnl(alice), 200e18);
        assertEq(accountBalance.getActivePoolIds(alice).length, 0);

        vm.prank(clearingHouse);
        accountBalance.modifyOwedRealizedPnl(alice, -20e18);
        assertEq(accountBalance.owedRealizedPnl(alice), 180e18);

        vm.prank(vault);
        int256 settled = accountBalance.settleOwedRealizedPnl(alice);
        assertEq(settled, 180e18);
        assertEq(accountBalance.owedRealizedPnl(alice), 0);
    }

    function testTotalAbsPositionValueAndLiquidationRequirement() public {
        accountBalance.setMarkPriceX18(poolA, 3_000e18);
        accountBalance.setMarkPriceX18(poolB, 2_000e18);

        vm.startPrank(clearingHouse);
        accountBalance.modifyTakerBalance(alice, poolA, 2e18, -6_000e18);
        accountBalance.modifyTakerBalance(alice, poolB, -1e18, 2_000e18);
        vm.stopPrank();

        uint256 absPositionValue = accountBalance.getTotalAbsPositionValue(alice);
        assertEq(absPositionValue, 8_000e18);

        int256 marginRequirement = accountBalance.getMarginRequirementForLiquidation(alice);
        assertEq(marginRequirement, 500e18);
    }

    function testUpdateTwPremiumGrowthGlobal() public {
        vm.prank(clearingHouse);
        accountBalance.updateLastTwPremiumGrowthGlobal(alice, poolA, 42);
        assertEq(accountBalance.getLastTwPremiumGrowthGlobalX96(alice, poolA), 42);
    }

    function testAccessControl() public {
        vm.expectRevert(abi.encodeWithSelector(AccountBalance.Unauthorized.selector, alice));
        vm.prank(alice);
        accountBalance.modifyTakerBalance(alice, poolA, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(AccountBalance.Unauthorized.selector, bob));
        vm.prank(bob);
        accountBalance.settleOwedRealizedPnl(alice);
    }

    function testPerpMathFunctions() public view {
        assertEq(perpMathHarness.abs(-5), 5);
        assertEq(perpMathHarness.neg256(7), -7);
        assertEq(perpMathHarness.neg256U(7), -7);
        assertEq(perpMathHarness.neg128(8), -8);
        assertEq(perpMathHarness.neg128U(8), -8);
        assertEq(perpMathHarness.divBy10_18I(3 ether), 3);
        assertEq(perpMathHarness.divBy10_18U(3 ether), 3);
        assertEq(perpMathHarness.subRatio(100_000, 60_000), 40_000);
        assertEq(perpMathHarness.mulDiv(-6, 3, 2), -9);
        assertEq(perpMathHarness.mulRatio(1_000_000, 62_500), 62_500);
        assertEq(perpMathHarness.mulRatioI(-1_000_000, 62_500), -62_500);
        assertEq(perpMathHarness.divRatio(62_500, 62_500), 1_000_000);
        assertEq(perpMathHarness.min(-2, 3), -2);
        assertEq(perpMathHarness.max(-2, 3), 3);
        assertEq(perpMathHarness.findMedianOfThree(10, 30, 20), 20);
        uint256 x96 = perpMathHarness.formatX10_18ToX96(1 ether);
        assertEq(perpMathHarness.formatX96ToX10_18(x96), 1 ether);
        assertEq(perpMathHarness.formatSqrtPriceX96ToPriceX96(2 ** 96), 2 ** 96);
    }

    function testPerpMathRevertCases() public {
        vm.expectRevert(PerpMath.Int256Overflow.selector);
        perpMathHarness.neg256(type(int256).min);

        vm.expectRevert(PerpMath.Int128Overflow.selector);
        perpMathHarness.neg128(type(int128).min);

        vm.expectRevert(PerpMath.DivisionByZero.selector);
        perpMathHarness.mulDiv(1, 1, 0);

        vm.expectRevert(PerpMath.RatioUnderflow.selector);
        perpMathHarness.subRatio(10, 11);
    }
}
