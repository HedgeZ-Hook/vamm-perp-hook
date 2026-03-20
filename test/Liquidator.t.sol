// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Liquidator} from "../src/Liquidator.sol";
import {IVammClearingHouse} from "../src/interfaces/IVammClearingHouse.sol";
import {IVammLiquidityController} from "../src/interfaces/IVammLiquidityController.sol";
import {IVammOracle} from "../src/interfaces/IVammOracle.sol";
import {IVammVault} from "../src/interfaces/IVammVault.sol";

contract MockVammOracle is IVammOracle {
    uint256 public latestPrice;
    uint256 public updateCalls;

    function updateOraclePrice(uint256 priceE18) external {
        latestPrice = priceE18;
        updateCalls++;
    }
}

contract MockVammLiquidityController is IVammLiquidityController {
    bool public executed = true;
    bool public zeroForOne;
    uint256 public usedAmountIn = 1e18;
    uint256 public updateCalls;

    function setResult(bool executed_, bool zeroForOne_, uint256 usedAmountIn_) external {
        executed = executed_;
        zeroForOne = zeroForOne_;
        usedAmountIn = usedAmountIn_;
    }

    function updateFromOracle() external returns (bool, bool, uint256) {
        updateCalls++;
        return (executed, zeroForOne, usedAmountIn);
    }
}

contract MockVammVault is IVammVault {
    mapping(address => bool) public liquidatable;
    mapping(address => bool) public shouldRevert;

    function setLiquidatable(address trader, bool value) external {
        liquidatable[trader] = value;
    }

    function setShouldRevert(address trader, bool value) external {
        shouldRevert[trader] = value;
    }

    function isLiquidatable(address trader) external view returns (bool) {
        if (shouldRevert[trader]) revert("vault-check-failed");
        return liquidatable[trader];
    }
}

contract MockVammClearingHouse is IVammClearingHouse {
    uint256 public liquidateCalls;
    mapping(address => uint256) public traderCalls;

    bool public isFullyLiquidated;
    uint256 public liquidatedSize;
    uint256 public penalty;
    bool public shouldRevert;

    function setLiquidateResult(bool isFullyLiquidated_, uint256 liquidatedSize_, uint256 penalty_) external {
        isFullyLiquidated = isFullyLiquidated_;
        liquidatedSize = liquidatedSize_;
        penalty = penalty_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function liquidate(address trader) external returns (bool, uint256, uint256) {
        if (shouldRevert) revert("liquidate-failed");
        liquidateCalls++;
        traderCalls[trader]++;
        return (isFullyLiquidated, liquidatedSize, penalty);
    }
}

contract LiquidatorTest is Test {
    Liquidator internal liquidator;
    MockVammOracle internal oracle;
    MockVammClearingHouse internal clearingHouse;
    MockVammVault internal vault;
    MockVammLiquidityController internal liquidityController;

    address internal aggregator = address(0xA11CE);
    address internal traderA = address(0x1111);
    address internal traderB = address(0x2222);
    address internal traderC = address(0x3333);

    function setUp() public {
        oracle = new MockVammOracle();
        clearingHouse = new MockVammClearingHouse();
        vault = new MockVammVault();
        liquidityController = new MockVammLiquidityController();

        liquidator = new Liquidator(address(oracle), address(clearingHouse), address(this));
        liquidator.setTrustedAggregator(aggregator);
        liquidator.setVaultContract(address(vault));
        liquidator.setLiquidityControllerContract(address(liquidityController));
    }

    function testOnAggregatedPriceRevertsWhenVaultCheckReverts() public {
        vm.prank(address(clearingHouse));
        liquidator.updateTrader(traderA, 1e18, false);
        vault.setShouldRevert(traderA, true);

        vm.expectRevert(bytes("vault-check-failed"));
        liquidator.onAggregatedPrice(address(0xBEEF), aggregator, 2_300e18, 1);

        assertEq(clearingHouse.liquidateCalls(), 0);
    }

    function testOnAggregatedPriceProcessesAllTrackedTradersEachCall() public {
        vm.prank(address(clearingHouse));
        liquidator.updateTrader(traderA, 1e18, false);
        vm.prank(address(clearingHouse));
        liquidator.updateTrader(traderB, 1e18, false);
        vm.prank(address(clearingHouse));
        liquidator.updateTrader(traderC, 1e18, false);

        vault.setLiquidatable(traderA, true);
        vault.setLiquidatable(traderB, true);
        vault.setLiquidatable(traderC, true);

        liquidator.onAggregatedPrice(address(0xBEEF), aggregator, 2_301e18, 1);
        assertEq(clearingHouse.liquidateCalls(), 3);
        assertEq(clearingHouse.traderCalls(traderA), 1);
        assertEq(clearingHouse.traderCalls(traderB), 1);
        assertEq(clearingHouse.traderCalls(traderC), 1);

        liquidator.onAggregatedPrice(address(0xBEEF), aggregator, 2_302e18, 1);
        assertEq(clearingHouse.liquidateCalls(), 6);
        assertEq(clearingHouse.traderCalls(traderA), 2);
        assertEq(clearingHouse.traderCalls(traderB), 2);
        assertEq(clearingHouse.traderCalls(traderC), 2);
    }

    function testUpdateTraderRemovesEntryWhenLiquidationPriceIsZeroAndWasLiquidated() public {
        vm.prank(address(clearingHouse));
        liquidator.updateTrader(traderA, 1e18, false);
        assertEq(liquidator.traderCount(), 1);
        assertEq(liquidator.tradersIdx(traderA), 1);

        vm.prank(address(clearingHouse));
        liquidator.updateTrader(traderA, 0, true);

        assertEq(liquidator.traderCount(), 0);
        assertEq(liquidator.tradersIdx(traderA), 0);
        assertEq(liquidator.liquidationPriceE18(traderA), 0);
    }

    function testUpdateTraderKeepsEntryWhenLiquidationPriceIsZeroButNotLiquidated() public {
        vm.prank(address(clearingHouse));
        liquidator.updateTrader(traderA, 1e18, false);
        vm.prank(address(clearingHouse));
        liquidator.updateTrader(traderA, 0, false);
        assertEq(liquidator.traderCount(), 1);
        assertEq(liquidator.tradersIdx(traderA), 1);
        assertEq(liquidator.liquidationPriceE18(traderA), 0);
    }
}
