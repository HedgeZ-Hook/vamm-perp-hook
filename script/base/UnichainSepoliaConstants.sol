// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library UnichainSepoliaConstants {
    uint256 internal constant CHAIN_ID = 1301;

    // Uniswap v4 infra (team deployments on Unichain Sepolia)
    address internal constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant UNIVERSAL_ROUTER = 0xf70536B3bcC1bD1a972dc186A2cf84cC6da6Be5D;
    address internal constant POSITION_MANAGER = 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664;
    address internal constant STATE_VIEW = 0xc199F1072a74D4e905ABa1A84d9a45E2546B6222;
    address internal constant QUOTER = 0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472;
    address internal constant POOL_SWAP_TEST = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;
    address internal constant POOL_MODIFY_LIQUIDITY_TEST = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Hookmate v4 router (supports IUniswapV4Router04 + msgSender()).
    // Recommended for this repo's contracts (Vault/LiquidityController).
    address internal constant HOOKMATE_V4_ROUTER = 0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba;
}
