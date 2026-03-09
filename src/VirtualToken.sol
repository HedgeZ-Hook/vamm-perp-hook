// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VirtualToken is ERC20, Ownable {
    error SenderNotWhitelisted(address sender);
    error SupplyAlreadyMinted();

    mapping(address => bool) public whitelist;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {}

    function mintMaximumTo(address recipient) external onlyOwner {
        if (totalSupply() != 0) revert SupplyAlreadyMinted();
        _mint(recipient, type(uint256).max);
    }

    function addWhitelist(address account) external onlyOwner {
        whitelist[account] = true;
    }

    function removeWhitelist(address account) external onlyOwner {
        whitelist[account] = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && !whitelist[from]) revert SenderNotWhitelisted(from);
        super._update(from, to, value);
    }
}
