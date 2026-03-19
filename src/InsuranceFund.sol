// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IVault} from "./interfaces/IVault.sol";

contract InsuranceFund is Ownable {
    error UnsupportedUsdcDecimals(uint8 decimals);

    IVault public immutable vault;
    IERC20 public immutable usdc;
    uint8 public immutable usdcDecimals;
    uint256 internal immutable usdcScaleTo1e18;

    address public beneficiary;
    uint256 public distributionThreshold;

    constructor(IVault vault_, IERC20 usdc_, address beneficiary_, uint256 distributionThreshold_) Ownable(msg.sender) {
        vault = vault_;
        usdc = usdc_;
        usdcDecimals = IERC20Metadata(address(usdc_)).decimals();
        if (usdcDecimals > 18) revert UnsupportedUsdcDecimals(usdcDecimals);
        usdcScaleTo1e18 = 10 ** (18 - usdcDecimals);
        beneficiary = beneficiary_;
        distributionThreshold = distributionThreshold_;
    }

    function setBeneficiary(address beneficiary_) external onlyOwner {
        beneficiary = beneficiary_;
    }

    function setDistributionThreshold(uint256 distributionThreshold_) external onlyOwner {
        distributionThreshold = distributionThreshold_;
    }

    function getInsuranceFundCapacity() public view returns (int256 capacity) {
        return vault.getAccountValue(address(this)) + int256(_toUsdcX18(usdc.balanceOf(address(this))));
    }

    function repay() external returns (uint256 amountRepaid) {
        int256 vaultAccountValue = vault.getAccountValue(address(this));
        if (vaultAccountValue >= 0) return 0;

        uint256 debt = uint256(-vaultAccountValue);
        uint256 walletBalanceX18 = _toUsdcX18(usdc.balanceOf(address(this)));
        uint256 amountRepaidX18 = debt < walletBalanceX18 ? debt : walletBalanceX18;
        amountRepaid = _fromUsdcX18(amountRepaidX18);
        if (amountRepaid == 0 || amountRepaidX18 == 0) return 0;

        usdc.approve(address(vault), amountRepaid);
        vault.deposit(amountRepaid);
    }

    function distributeFee() external returns (uint256 amountDistributed) {
        int256 capacity = getInsuranceFundCapacity();
        int256 threshold = int256(distributionThreshold);
        if (capacity <= threshold) return 0;

        uint256 overThreshold = uint256(capacity - threshold);
        int256 freeCollateral = vault.getFreeCollateral(address(this));
        uint256 withdrawableX18 = freeCollateral > 0 ? uint256(freeCollateral) : 0;

        int256 netCashBalance = vault.getNetCashBalance(address(this));
        uint256 internalBalanceX18 = netCashBalance > 0 ? uint256(netCashBalance) : 0;
        if (withdrawableX18 > internalBalanceX18) {
            withdrawableX18 = internalBalanceX18;
        }

        uint256 amountDistributedX18 = overThreshold < withdrawableX18 ? overThreshold : withdrawableX18;
        amountDistributed = _fromUsdcX18(amountDistributedX18);
        if (amountDistributed == 0 || amountDistributedX18 == 0) return 0;

        vault.withdraw(amountDistributed);
        usdc.transfer(beneficiary, amountDistributed);
    }

    function _toUsdcX18(uint256 usdcRaw) internal view returns (uint256 usdcX18) {
        if (usdcScaleTo1e18 == 1) return usdcRaw;
        usdcX18 = usdcRaw * usdcScaleTo1e18;
    }

    function _fromUsdcX18(uint256 usdcX18) internal view returns (uint256 usdcRaw) {
        if (usdcScaleTo1e18 == 1) return usdcX18;
        usdcRaw = usdcX18 / usdcScaleTo1e18;
    }
}
