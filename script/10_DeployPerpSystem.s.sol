// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

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
import {ILiquidationTracker} from "../src/interfaces/ILiquidationTracker.sol";
import {ManualPriceOracle} from "../src/ManualPriceOracle.sol";

import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

// ===== Perp System Deployed (Unichain Sepolia) =====
//   Deployer: 0x91d5e66951c47FbBFaFe57C9Ff42d45c46b6044c
//   PoolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC
//   PositionManager: 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664
//   SwapRouter: 0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba
//   USDC: 0x31d0220469e10c4E71834a79b1f276d740d3768F
//   PerpHook: 0xAB680fAff2fb5EDd44E7dF8b4a3d698ac6b70fC0
//   vETH: 0xa155C64e596B95799E90395C55d7BB9582E7F571
//   vUSDC: 0x15207845fBF12Ec6dCe838141cbfe7FdfDEd1281
//   Config: 0xD0e20b73d771543527028483c87685Ef203AB093
//   AccountBalance: 0x9595113f5E9d772d4752b31F377C82F9da23647C
//   ClearingHouse: 0x77e2f60F4fe6d11A34cA4aF1043A604eEfF85a7c
//   Vault: 0xf01465d2E1ba55e5362acae22cAE4dDE59EB13e4
//   FundingRate: 0xE29877362BE887Ca421D28Ec04796019D9316647
//   LiquidityController: 0x67657652B6eb27cFd312eEc89e3780608B65B382
//   InsuranceFund: 0x2a75451b45d3713152168F1D58F624e0ae482535
//   PriceOracle: 0xE6D19cBA9e4c978688dfbFEf1D63805e4f3D71Be
//   LiquidationTracker: 0xE6D19cBA9e4c978688dfbFEf1D63805e4f3D71Be

contract DeployPerpSystemUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error InvalidUsdc(address usdc);
    error UnsupportedUsdcDecimals(uint8 decimals);
    error HookAddressMismatch(address expected, address actual);
    error HookOwnerMismatch(address expected, address actual);

    struct Inputs {
        address deployer;
        address usdc;
        address permit2;
        address swapRouter;
        address oracleAddress;
        bool verifySwapRouterAsMsgSender;
        IPoolManager poolManager;
        IPositionManager positionManager;
        uint24 deadbandBps;
        uint24 maxRepriceBpsPerUpdate;
        uint256 maxAmountInPerUpdate;
        uint128 minVammLiquidity;
        uint256 initialOraclePriceX18;
        uint256 chVethInventory;
        uint256 chVusdcInventory;
        uint256 lcVethInventory;
        uint256 lcVusdcInventory;
        address insuranceBeneficiary;
        uint256 insuranceThreshold;
        address liquidationTracker;
    }

    struct Deployed {
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
        address oracle;
    }

    function run() external returns (Deployed memory deployed) {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        Inputs memory inp = _loadInputs(pk);

        vm.startBroadcast(pk);
        deployed = _deployAndWire(inp);
        vm.stopBroadcast();

        _printSummary(inp, deployed);
    }

    function _loadInputs(uint256 pk) internal view returns (Inputs memory inp) {
        inp.deployer = vm.addr(pk);
        inp.usdc = vm.envAddress("USDC");
        if (inp.usdc == address(0)) revert InvalidUsdc(inp.usdc);
        uint8 usdcDecimals = IERC20Metadata(inp.usdc).decimals();
        if (usdcDecimals > 18) revert UnsupportedUsdcDecimals(usdcDecimals);

        inp.poolManager = IPoolManager(vm.envOr("POOL_MANAGER", UnichainSepoliaConstants.POOL_MANAGER));
        inp.positionManager = IPositionManager(vm.envOr("POSITION_MANAGER", UnichainSepoliaConstants.POSITION_MANAGER));
        inp.permit2 = vm.envOr("PERMIT2", UnichainSepoliaConstants.PERMIT2);
        inp.swapRouter = vm.envOr("SWAP_ROUTER", UnichainSepoliaConstants.HOOKMATE_V4_ROUTER);

        inp.oracleAddress = vm.envOr("PRICE_ORACLE", address(0));
        inp.initialOraclePriceX18 = vm.envOr("INITIAL_ORACLE_PRICE_X18", uint256(3_000e18));

        inp.deadbandBps = uint24(vm.envOr("LC_DEADBAND_BPS", uint256(10)));
        inp.maxRepriceBpsPerUpdate = uint24(vm.envOr("LC_MAX_REPRICE_BPS", uint256(30)));
        inp.maxAmountInPerUpdate = vm.envOr("LC_MAX_AMOUNT_IN", uint256(5e18));
        inp.minVammLiquidity = uint128(vm.envOr("LC_MIN_VAMM_LIQUIDITY", uint256(1_000e18)));

        inp.chVethInventory = vm.envOr("CH_VETH_INVENTORY", uint256(1_000_000e18));
        inp.chVusdcInventory = vm.envOr("CH_VUSDC_INVENTORY", uint256(10_000_000_000e18));
        inp.lcVethInventory = vm.envOr("LC_VETH_INVENTORY", uint256(50_000e18));
        inp.lcVusdcInventory = vm.envOr("LC_VUSDC_INVENTORY", uint256(150_000_000e18));

        inp.verifySwapRouterAsMsgSender = vm.envOr("VERIFY_SWAP_ROUTER_AS_MSG_SENDER", true);
        inp.insuranceBeneficiary = vm.envOr("INSURANCE_BENEFICIARY", inp.deployer);
        inp.insuranceThreshold = vm.envOr("INSURANCE_DISTRIBUTION_THRESHOLD", uint256(200_000e18));
        inp.liquidationTracker = vm.envOr("LIQUIDATION_TRACKER", address(0));
    }

    function _deployAndWire(Inputs memory inp) internal returns (Deployed memory d) {
        IPriceOracle oracle = _resolveOracle(inp);
        d.oracle = address(oracle);

        d.hook = _deployHook(inp.poolManager, inp.deployer);
        d.veth = new VirtualToken("Virtual ETH", "vETH");
        d.vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        d.veth.mintMaximumTo(inp.deployer);
        d.vusdc.mintMaximumTo(inp.deployer);

        (PoolKey memory vammPoolKey, PoolKey memory spotPoolKey, Currency baseCurrency, Currency quoteCurrency) =
            _buildPoolKeys(d.hook, d.veth, d.vusdc, inp.usdc);

        d.config = new Config();
        d.accountBalance = new AccountBalance(d.config);
        d.clearingHouse =
            new ClearingHouse(inp.poolManager, d.accountBalance, d.config, vammPoolKey, baseCurrency, quoteCurrency);
        d.vault = new Vault(
            d.accountBalance,
            d.config,
            IERC20(inp.usdc),
            oracle,
            inp.poolManager,
            inp.positionManager,
            IUniswapV4Router04(payable(inp.swapRouter)),
            spotPoolKey
        );
        d.fundingRate = new FundingRate(inp.poolManager, oracle, d.accountBalance, d.config);
        d.liquidityController = _deployLiquidityController(inp, oracle, vammPoolKey, d.config, d.veth, d.vusdc);
        d.insuranceFund = new InsuranceFund(d.vault, IERC20(inp.usdc), inp.insuranceBeneficiary, inp.insuranceThreshold);

        _wireContracts(inp, d, vammPoolKey, spotPoolKey, oracle);
        _seedVirtualLiquidity(inp, d);
    }

    function _resolveOracle(Inputs memory inp) internal returns (IPriceOracle oracle) {
        if (inp.oracleAddress == address(0)) {
            ManualPriceOracle manualOracle = new ManualPriceOracle(inp.initialOraclePriceX18);
            return IPriceOracle(address(manualOracle));
        }
        return IPriceOracle(inp.oracleAddress);
    }

    function _deployLiquidityController(
        Inputs memory inp,
        IPriceOracle oracle,
        PoolKey memory vammPoolKey,
        Config config,
        VirtualToken veth,
        VirtualToken vusdc
    ) internal returns (LiquidityController controller) {
        IPoolManager poolManager = inp.poolManager;
        IUniswapV4Router04 router = IUniswapV4Router04(payable(inp.swapRouter));
        uint32 twapInterval = config.twapInterval();
        uint24 deadbandBps = inp.deadbandBps;
        uint24 maxRepriceBpsPerUpdate = inp.maxRepriceBpsPerUpdate;
        uint256 maxAmountInPerUpdate = inp.maxAmountInPerUpdate;
        uint128 minVammLiquidity = inp.minVammLiquidity;

        controller = new LiquidityController(
            poolManager,
            router,
            oracle,
            vammPoolKey,
            address(veth),
            address(vusdc),
            twapInterval,
            deadbandBps,
            maxRepriceBpsPerUpdate,
            maxAmountInPerUpdate,
            minVammLiquidity
        );
    }

    function _deployHook(IPoolManager poolManager, address initialOwner) internal returns (PerpHook hook) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, initialOwner);
        (address expectedHook, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(PerpHook).creationCode, constructorArgs);
        hook = new PerpHook{salt: salt}(poolManager, initialOwner);
        if (address(hook) != expectedHook) revert HookAddressMismatch(expectedHook, address(hook));
        if (hook.owner() != initialOwner) revert HookOwnerMismatch(initialOwner, hook.owner());
    }

    function _buildPoolKeys(PerpHook hook, VirtualToken veth, VirtualToken vusdc, address usdc)
        internal
        pure
        returns (PoolKey memory vammPoolKey, PoolKey memory spotPoolKey, Currency baseCurrency, Currency quoteCurrency)
    {
        (Currency vammCurrency0, Currency vammCurrency1) = _orderedCurrencies(address(veth), address(vusdc));
        vammPoolKey = PoolKey({
            currency0: vammCurrency0,
            currency1: vammCurrency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        spotPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        baseCurrency = Currency.wrap(address(veth));
        quoteCurrency = Currency.wrap(address(vusdc));
    }

    function _wireContracts(
        Inputs memory inp,
        Deployed memory d,
        PoolKey memory vammPoolKey,
        PoolKey memory spotPoolKey,
        IPriceOracle oracle
    ) internal {
        d.hook.registerVAMMPool(vammPoolKey, address(d.veth), address(d.vusdc));
        d.hook.registerSpotPool(spotPoolKey);
        d.hook.setClearingHouse(address(d.clearingHouse));
        d.hook.setPriceOracle(oracle, d.config.twapInterval());
        d.hook.setVerifiedRouter(address(inp.positionManager), true);
        if (inp.verifySwapRouterAsMsgSender) {
            d.hook.setVerifiedRouter(inp.swapRouter, true);
            d.hook.setLiquidityController(address(d.liquidityController));
        }

        d.accountBalance.setClearingHouse(address(d.clearingHouse));
        d.accountBalance.setVault(address(d.vault));
        d.clearingHouse.setVault(d.vault);
        d.clearingHouse.setFundingRate(d.fundingRate);
        if (inp.liquidationTracker != address(0)) {
            d.clearingHouse.setLiquidationTracker(ILiquidationTracker(inp.liquidationTracker));
        }
        d.vault.setClearingHouse(address(d.clearingHouse));
        d.vault.setFundingRate(d.fundingRate);
        d.vault.setInsuranceFund(address(d.insuranceFund));
        d.fundingRate.setClearingHouse(address(d.clearingHouse));
    }

    function _seedVirtualLiquidity(Inputs memory inp, Deployed memory d) internal {
        _allowVirtualToken(
            d.veth, inp.deployer, inp.permit2, address(inp.poolManager), address(inp.positionManager), inp.swapRouter
        );
        _allowVirtualToken(
            d.vusdc, inp.deployer, inp.permit2, address(inp.poolManager), address(inp.positionManager), inp.swapRouter
        );
        d.veth.addWhitelist(address(d.clearingHouse));
        d.vusdc.addWhitelist(address(d.clearingHouse));
        d.veth.addWhitelist(address(d.liquidityController));
        d.vusdc.addWhitelist(address(d.liquidityController));

        d.veth.transfer(address(d.clearingHouse), inp.chVethInventory);
        d.vusdc.transfer(address(d.clearingHouse), inp.chVusdcInventory);
        d.veth.transfer(address(d.liquidityController), inp.lcVethInventory);
        d.vusdc.transfer(address(d.liquidityController), inp.lcVusdcInventory);

        d.liquidityController.approveSpender(IERC20(address(d.veth)), inp.swapRouter, type(uint256).max);
        d.liquidityController.approveSpender(IERC20(address(d.vusdc)), inp.swapRouter, type(uint256).max);
    }

    function _allowVirtualToken(
        VirtualToken token,
        address deployer,
        address permit2,
        address poolManager,
        address positionManager,
        address swapRouter
    ) internal {
        token.addWhitelist(deployer);
        token.addWhitelist(poolManager);
        token.addWhitelist(positionManager);
        token.addWhitelist(swapRouter);
        token.addWhitelist(permit2);

        token.approve(permit2, type(uint256).max);
        token.approve(swapRouter, type(uint256).max);
        IPermit2(permit2).approve(address(token), positionManager, type(uint160).max, type(uint48).max);
        IPermit2(permit2).approve(address(token), poolManager, type(uint160).max, type(uint48).max);
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

    function _printSummary(Inputs memory inp, Deployed memory d) internal pure {
        console2.log("===== Perp System Deployed (Unichain Sepolia) =====");
        console2.log("Deployer:", inp.deployer);
        console2.log("PoolManager:", address(inp.poolManager));
        console2.log("PositionManager:", address(inp.positionManager));
        console2.log("SwapRouter:", inp.swapRouter);
        console2.log("USDC:", inp.usdc);
        console2.log("PerpHook:", address(d.hook));
        console2.log("vETH:", address(d.veth));
        console2.log("vUSDC:", address(d.vusdc));
        console2.log("Config:", address(d.config));
        console2.log("AccountBalance:", address(d.accountBalance));
        console2.log("ClearingHouse:", address(d.clearingHouse));
        console2.log("Vault:", address(d.vault));
        console2.log("FundingRate:", address(d.fundingRate));
        console2.log("LiquidityController:", address(d.liquidityController));
        console2.log("InsuranceFund:", address(d.insuranceFund));
        console2.log("PriceOracle:", d.oracle);
        console2.log("LiquidationTracker:", inp.liquidationTracker);
        if (!inp.verifySwapRouterAsMsgSender) {
            console2.log("WARN: swap router is not verified as msgSender; LiquidityController cannot swap vAMM.");
        }
    }
}
