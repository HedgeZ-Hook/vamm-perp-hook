// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {PerpHook} from "../src/PerpHook.sol";
import {VirtualToken} from "../src/VirtualToken.sol";
import {Config} from "../src/Config.sol";
import {AccountBalance} from "../src/AccountBalance.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {Vault} from "../src/Vault.sol";
import {FundingRate} from "../src/FundingRate.sol";
import {LiquidityController} from "../src/LiquidityController.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract InspectSystemStateUnichainSepolia is Script {
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    error InvalidChain(uint256 actual, uint256 expected);

    struct Inputs {
        address deployer;
        address trader;
        IERC20 usdc;
        IPoolManager poolManager;
        IPositionManager positionManager;
        PerpHook hook;
        VirtualToken veth;
        VirtualToken vusdc;
        Config config;
        AccountBalance accountBalance;
        ClearingHouse clearingHouse;
        Vault vault;
        FundingRate fundingRate;
        LiquidityController liquidityController;
        InsuranceFund insuranceFund;
        uint256 vammTokenId;
        uint256 spotTokenId;
    }

    function run() external view {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        Inputs memory inp = _loadInputs();
        _printContracts(inp);
        _printRiskConfig(inp);
        _printPoolState(inp);
        _printOracleState(inp);
        _printBalances(inp);
        _printTraderState(inp);
        _printOptionalPosition(inp.positionManager, inp.vammTokenId, "vAMM NFT");
        _printOptionalPosition(inp.positionManager, inp.spotTokenId, "Spot NFT");
    }

    function _loadInputs() internal view returns (Inputs memory inp) {
        inp.deployer = vm.envOr("DEPLOYER", address(0));
        if (inp.deployer == address(0)) {
            inp.deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        }
        inp.trader = vm.envOr("INSPECT_TRADER", inp.deployer);
        inp.clearingHouse = ClearingHouse(vm.envAddress("CLEARING_HOUSE"));
        inp.vault = Vault(payable(address(inp.clearingHouse.vault())));
        inp.accountBalance = AccountBalance(address(inp.clearingHouse.accountBalance()));
        inp.fundingRate = FundingRate(address(inp.clearingHouse.fundingRate()));
        inp.config = inp.accountBalance.config();
        inp.poolManager = inp.clearingHouse.poolManager();
        inp.positionManager = inp.vault.positionManager();
        inp.usdc = inp.vault.usdc();

        (,,,, IHooks vammHooks) = inp.clearingHouse.vammPoolKey();
        address hookAddress = vm.envOr("PERP_HOOK", address(vammHooks));
        inp.hook = PerpHook(hookAddress);

        inp.veth = VirtualToken(Currency.unwrap(inp.clearingHouse.baseCurrency()));
        inp.vusdc = VirtualToken(Currency.unwrap(inp.clearingHouse.quoteCurrency()));
        inp.liquidityController = LiquidityController(inp.hook.liquidityController());
        inp.insuranceFund = InsuranceFund(inp.vault.insuranceFund());

        inp.vammTokenId = vm.envOr("INSPECT_VAMM_TOKEN_ID", uint256(0));
        inp.spotTokenId = vm.envOr("INSPECT_SPOT_TOKEN_ID", uint256(0));
    }

    function _printContracts(Inputs memory inp) internal view {
        console2.log("===== Contracts =====");
        console2.log("Deployer:", inp.deployer);
        console2.log("Inspect trader:", inp.trader);
        console2.log("USDC:", address(inp.usdc));
        console2.log("PoolManager:", address(inp.poolManager));
        console2.log("PositionManager:", address(inp.positionManager));
        console2.log("Hook:", address(inp.hook));
        console2.log("vETH:", address(inp.veth));
        console2.log("vUSDC:", address(inp.vusdc));
        console2.log("Config:", address(inp.config));
        console2.log("AccountBalance:", address(inp.accountBalance));
        console2.log("ClearingHouse:", address(inp.clearingHouse));
        console2.log("Vault:", address(inp.vault));
        console2.log("FundingRate:", address(inp.fundingRate));
        console2.log("LiquidityController:", address(inp.liquidityController));
        console2.log("InsuranceFund:", address(inp.insuranceFund));
        console2.log("Hook owner:", inp.hook.owner());
        console2.log("CH owner:", inp.clearingHouse.owner());
        console2.log("Vault owner:", inp.vault.owner());
    }

    function _printRiskConfig(Inputs memory inp) internal view {
        console2.log("===== Config =====");
        console2.log("imRatio:", inp.config.imRatio());
        console2.log("mmRatio:", inp.config.mmRatio());
        console2.log("liquidationPenaltyRatio:", inp.config.liquidationPenaltyRatio());
        console2.log("maxFundingRate:", inp.config.maxFundingRate());
        console2.log("twapInterval:", inp.config.twapInterval());
        console2.log("insuranceFundFeeRatio:", inp.config.insuranceFundFeeRatio());
        console2.log("Hook clearingHouse:", inp.hook.clearingHouse());
        console2.log("Hook liquidityController:", inp.hook.liquidityController());
        console2.log("Hook verified PositionManager:", inp.hook.verifiedRouters(address(inp.positionManager)));
        console2.log(
            "Hook verified LC swapRouter:", inp.hook.verifiedRouters(address(inp.liquidityController.swapRouter()))
        );
        console2.log("Vault clearingHouse:", inp.vault.clearingHouse());
        console2.log("Vault insuranceFund:", inp.vault.insuranceFund());
        console2.log("CH vault:", address(inp.clearingHouse.vault()));
        console2.log("CH fundingRate:", address(inp.clearingHouse.fundingRate()));
        console2.log("CH liquidationTracker:", address(inp.clearingHouse.liquidationTracker()));
    }

    function _printPoolState(Inputs memory inp) internal view {
        console2.log("===== Pools =====");
        PoolId vammPoolId = inp.clearingHouse.vammPoolId();
        PoolId spotPoolId = inp.vault.spotPoolId();
        (uint160 vammSqrtPriceX96, int24 vammTick,,) = inp.poolManager.getSlot0(vammPoolId);
        (uint160 spotSqrtPriceX96, int24 spotTick,,) = inp.poolManager.getSlot0(spotPoolId);
        console2.log("vAMM PoolId:", uint256(PoolId.unwrap(vammPoolId)));
        console2.log("vAMM sqrtPriceX96:", uint256(vammSqrtPriceX96));
        console2.log("vAMM tick:", int256(vammTick));
        console2.log("vAMM liquidity:", uint256(inp.poolManager.getLiquidity(vammPoolId)));
        console2.log("vAMM price x18:", inp.hook.getVammPriceX18());
        console2.log("Spot PoolId:", uint256(PoolId.unwrap(spotPoolId)));
        console2.log("Spot sqrtPriceX96:", uint256(spotSqrtPriceX96));
        console2.log("Spot tick:", int256(spotTick));
        console2.log("Spot liquidity:", uint256(inp.poolManager.getLiquidity(spotPoolId)));
        console2.log("Spot price x18:", inp.hook.getSpotPriceX18());
        console2.log(
            "Spot fee params min/base/max bps:", inp.hook.minFeeBps(), inp.hook.baseFeeBps(), inp.hook.maxFeeBps()
        );
        console2.log("Spot vol EMA bps:", inp.hook.spotVolEmaBps());
        console2.log("Spot last price x18:", inp.hook.lastSpotPriceX18());
    }

    function _printOracleState(Inputs memory inp) internal view {
        console2.log("===== Oracle =====");
        IPriceOracle hookOracle = inp.hook.priceOracle();
        console2.log("Hook oracle:", address(hookOracle));
        if (address(hookOracle) != address(0)) {
            console2.log("Hook oracle latest x18:", hookOracle.latestOraclePriceE18());
        }
        console2.log("Vault oracle:", address(inp.vault.priceOracle()));
        console2.log("Vault mark price x18:", inp.vault.getMarkPriceX18());
        console2.log("FundingRate oracle:", address(inp.fundingRate.priceOracle()));
        console2.log("LiquidityController oracle:", address(inp.liquidityController.priceOracle()));
        console2.log("LiquidityController oracle latest x18:", inp.liquidityController.getOraclePriceX18());
        console2.log("LiquidityController vAMM price x18:", inp.liquidityController.getVammPriceX18());
        console2.log("LC deadband/maxReprice/maxAmountIn/minLiquidity:");
        console2.log("  deadbandBps:", inp.liquidityController.deadbandBps());
        console2.log("  maxRepriceBpsPerUpdate:", inp.liquidityController.maxRepriceBpsPerUpdate());
        console2.log("  maxAmountInPerUpdate:", inp.liquidityController.maxAmountInPerUpdate());
        console2.log("  minVammLiquidity:", uint256(inp.liquidityController.minVammLiquidity()));
    }

    function _printBalances(Inputs memory inp) internal view {
        console2.log("===== External Token Balances =====");
        _printAccountBalances("Deployer", inp.deployer, inp.usdc, inp.veth, inp.vusdc);
        _printAccountBalances("Vault", address(inp.vault), inp.usdc, inp.veth, inp.vusdc);
        _printAccountBalances("ClearingHouse", address(inp.clearingHouse), inp.usdc, inp.veth, inp.vusdc);
        _printAccountBalances("LiquidityController", address(inp.liquidityController), inp.usdc, inp.veth, inp.vusdc);
        _printAccountBalances("InsuranceFund", address(inp.insuranceFund), inp.usdc, inp.veth, inp.vusdc);

        console2.log("===== Internal Vault Balances x18 =====");
        console2.log("Deployer vault usdcBalance:", _toUint(inp.vault.usdcBalance(inp.deployer)));
        console2.log("Trader vault usdcBalance:", _toUint(inp.vault.usdcBalance(inp.trader)));
        console2.log("InsuranceFund vault usdcBalance:", _toUint(inp.vault.usdcBalance(address(inp.insuranceFund))));
        console2.log("InsuranceFund capacity:", _toUint(inp.insuranceFund.getInsuranceFundCapacity()));
    }

    function _printTraderState(Inputs memory inp) internal view {
        console2.log("===== Trader State =====");
        PoolId vammPoolId = inp.clearingHouse.vammPoolId();
        console2.log(
            "Trader takerPositionSize:", _toInt(inp.accountBalance.getTakerPositionSize(inp.trader, vammPoolId))
        );
        console2.log(
            "Trader takerOpenNotional:", _toInt(inp.accountBalance.getTakerOpenNotional(inp.trader, vammPoolId))
        );
        console2.log("Trader accountValue:", _toInt(inp.vault.getAccountValue(inp.trader)));
        console2.log("Trader freeCollateral:", _toInt(inp.vault.getFreeCollateral(inp.trader)));
        console2.log("Trader netCashBalance:", _toInt(inp.vault.getNetCashBalance(inp.trader)));
        console2.log("Trader LP collateral value:", inp.vault.getLPCollateralValue(inp.trader));
        console2.log("Trader has LP collateral:", inp.vault.hasLPCollateral(inp.trader));
        console2.log("Trader liquidationPriceX18:", inp.vault.getLiquidationPriceX18(inp.trader));
        console2.log("Trader isLiquidatable:", inp.vault.isLiquidatable(inp.trader));

        uint256[] memory tokenIds = inp.vault.getUserLPTokenIds(inp.trader);
        console2.log("Trader LP token count:", tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            console2.log("Trader LP tokenId:", tokenIds[i]);
        }
    }

    function _printOptionalPosition(IPositionManager positionManager, uint256 tokenId, string memory label)
        internal
        view
    {
        if (tokenId == 0) return;

        console2.log("===== Position NFT =====");
        console2.log("Label:", label);
        console2.log("TokenId:", tokenId);
        console2.log("Owner:", IERC721(address(positionManager)).ownerOf(tokenId));
        console2.log("Liquidity:", uint256(positionManager.getPositionLiquidity(tokenId)));

        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        console2.log("Currency0:", Currency.unwrap(key.currency0));
        console2.log("Currency1:", Currency.unwrap(key.currency1));
        console2.log("TickLower:", int256(info.tickLower()));
        console2.log("TickUpper:", int256(info.tickUpper()));
    }

    function _printAccountBalances(
        string memory label,
        address account,
        IERC20 usdc,
        VirtualToken veth,
        VirtualToken vusdc
    ) internal view {
        console2.log("Account:", label);
        console2.log("  address:", account);
        console2.log("  native:", account.balance);
        console2.log("  usdc raw:", usdc.balanceOf(account));
        console2.log("  vETH:", veth.balanceOf(account));
        console2.log("  vUSDC:", vusdc.balanceOf(account));
    }

    function _toUint(int256 value) internal pure returns (uint256) {
        return value > 0 ? uint256(value) : 0;
    }

    function _toInt(int256 value) internal pure returns (int256) {
        return value;
    }
}
