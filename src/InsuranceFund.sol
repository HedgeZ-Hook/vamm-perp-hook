// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVault} from "./interfaces/IVault.sol";

contract InsuranceFund is Ownable {
    IVault public immutable vault;
    IERC20 public immutable usdc;

    address public beneficiary;
    uint256 public distributionThreshold;

    constructor(IVault vault_, IERC20 usdc_, address beneficiary_, uint256 distributionThreshold_) Ownable(msg.sender) {
        vault = vault_;
        usdc = usdc_;
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
        return vault.getAccountValue(address(this)) + int256(usdc.balanceOf(address(this)));
    }

    function repay() external returns (uint256 amountRepaid) {
        int256 vaultAccountValue = vault.getAccountValue(address(this));
        if (vaultAccountValue >= 0) return 0;

        uint256 debt = uint256(-vaultAccountValue);
        uint256 walletBalance = usdc.balanceOf(address(this));
        amountRepaid = debt < walletBalance ? debt : walletBalance;
        if (amountRepaid == 0) return 0;

        usdc.approve(address(vault), amountRepaid);
        vault.deposit(amountRepaid);
    }

    function distributeFee() external returns (uint256 amountDistributed) {
        int256 capacity = getInsuranceFundCapacity();
        int256 threshold = int256(distributionThreshold);
        if (capacity <= threshold) return 0;

        amountDistributed = uint256(capacity - threshold);
        vault.withdraw(amountDistributed);
        usdc.transfer(beneficiary, amountDistributed);
    }
}
