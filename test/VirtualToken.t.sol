// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {VirtualToken} from "../src/VirtualToken.sol";
import {Config} from "../src/Config.sol";

contract VirtualTokenTest is Test {
    address internal clearingHouse = makeAddr("clearingHouse");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function testVirtualTokenWhitelistTransferRules() public {
        VirtualToken veth = new VirtualToken("Virtual ETH", "vETH");
        VirtualToken vusdc = new VirtualToken("Virtual USDC", "vUSDC");

        veth.mintMaximumTo(clearingHouse);
        vusdc.mintMaximumTo(clearingHouse);

        assertEq(veth.balanceOf(clearingHouse), type(uint256).max);
        assertEq(vusdc.balanceOf(clearingHouse), type(uint256).max);

        veth.addWhitelist(clearingHouse);

        vm.prank(clearingHouse);
        bool firstTransfer = veth.transfer(bob, 10 ether);
        assertTrue(firstTransfer);
        assertEq(veth.balanceOf(bob), 10 ether);

        vm.expectRevert(abi.encodeWithSelector(VirtualToken.SenderNotWhitelisted.selector, bob));
        vm.prank(bob);
        veth.transfer(alice, 1 ether);

        veth.addWhitelist(bob);

        vm.prank(bob);
        bool secondTransfer = veth.transfer(alice, 1 ether);
        assertTrue(secondTransfer);
        assertEq(veth.balanceOf(alice), 1 ether);
    }

    function testVirtualTokenOwnerGating() public {
        VirtualToken token = new VirtualToken("Virtual ETH", "vETH");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.addWhitelist(alice);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.mintMaximumTo(alice);

        token.mintMaximumTo(clearingHouse);
        vm.expectRevert(VirtualToken.SupplyAlreadyMinted.selector);
        token.mintMaximumTo(alice);
    }

    function testConfigDefaultsAndUpdates() public {
        Config config = new Config();

        assertEq(config.imRatio(), 100_000);
        assertEq(config.mmRatio(), 62_500);
        assertEq(config.liquidationPenaltyRatio(), 25_000);
        assertEq(config.maxFundingRate(), 100_000);
        assertEq(config.twapInterval(), 900);
        assertEq(config.insuranceFundFeeRatio(), 0);

        config.setImRatio(120_000);
        config.setMmRatio(70_000);
        config.setLiquidationPenaltyRatio(30_000);
        config.setMaxFundingRate(80_000);
        config.setTwapInterval(1_800);
        config.setInsuranceFundFeeRatio(5_000);

        assertEq(config.imRatio(), 120_000);
        assertEq(config.mmRatio(), 70_000);
        assertEq(config.liquidationPenaltyRatio(), 30_000);
        assertEq(config.maxFundingRate(), 80_000);
        assertEq(config.twapInterval(), 1_800);
        assertEq(config.insuranceFundFeeRatio(), 5_000);
    }

    function testConfigOnlyOwner() public {
        Config config = new Config();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        config.setImRatio(1);
    }
}
