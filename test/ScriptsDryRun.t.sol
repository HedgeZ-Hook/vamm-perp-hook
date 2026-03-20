// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";

import {PerpHook} from "../src/PerpHook.sol";
import {VirtualToken} from "../src/VirtualToken.sol";
import {Config} from "../src/Config.sol";
import {AccountBalance} from "../src/AccountBalance.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {Vault} from "../src/Vault.sol";
import {FundingRate} from "../src/FundingRate.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {ManualPriceOracle} from "../src/ManualPriceOracle.sol";

import {InitPoolsAndBootstrapUnichainSepolia} from "../script/11_InitPoolsAndBootstrap.s.sol";
import {WithdrawVaultCollateralUnichainSepolia} from "../script/15_WithdrawVaultCollateral.s.sol";
import {FundInsuranceFundUnichainSepolia} from "../script/17_FundInsuranceFund.s.sol";
import {SetManualOraclePriceUnichainSepolia} from "../script/13_SetManualOraclePrice.s.sol";
import {UnichainSepoliaConstants} from "../script/base/UnichainSepoliaConstants.sol";

contract ScriptsDryRunTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant SCRIPT_PK = 0xA11CE;
    uint256 internal constant TRADER_PK = 0xB0B;
    uint256 internal constant Q192 = 2 ** 192;

    struct SmokeCore {
        MockERC20 usdc;
        Vault vault;
        ClearingHouse clearingHouse;
        AccountBalance accountBalance;
        InsuranceFund insuranceFund;
        PoolId vammPoolId;
    }

    function setUp() public {
        deployArtifactsAndLabel();
        vm.setEnv("SPOT_BOOTSTRAP_ETH_AMOUNT", "0");
        vm.setEnv("SPOT_BOOTSTRAP_USDC_AMOUNT", "0");
    }

    function testScript11InitPoolsRunOnLocalDryRun() public {
        address deployer = vm.addr(SCRIPT_PK);
        vm.deal(deployer, 1_000 ether);

        PerpHook hook = _deployHook(address(this));
        VirtualToken veth = new VirtualToken("Virtual ETH", "vETH");
        VirtualToken vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(deployer, 1_000_000_000_000e6);
        _seedBootstrapAssets(deployer, veth, vusdc);

        _setBaseInitEnv(hook, veth, vusdc, usdc);
        vm.setEnv("VAMM_BOOTSTRAP_LIQUIDITY", "0");
        vm.setEnv("SPOT_BOOTSTRAP_LIQUIDITY", "0");
        vm.setEnv("SPOT_BOOTSTRAP_ETH_AMOUNT", "0");
        vm.setEnv("SPOT_BOOTSTRAP_USDC_AMOUNT", "0");

        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);
        InitPoolsAndBootstrapUnichainSepolia script = new InitPoolsAndBootstrapUnichainSepolia();
        script.run();

        (PoolKey memory vammPoolKey, PoolKey memory spotPoolKey) = _buildPoolKeys(hook, veth, vusdc, usdc);
        (uint160 vammSqrtPriceX96,,,) = poolManager.getSlot0(vammPoolKey.toId());
        (uint160 spotSqrtPriceX96,,,) = poolManager.getSlot0(spotPoolKey.toId());
        uint160 expectedVammSqrtPriceX96 = _vammInitSqrtPriceX96(vammPoolKey, address(veth), 3_000e18);
        uint160 expectedSpotSqrtPriceX96 = _priceX18ToSqrtPriceX96(2_300e18, 18, 6);

        assertEq(vammSqrtPriceX96, expectedVammSqrtPriceX96);
        assertEq(spotSqrtPriceX96, expectedSpotSqrtPriceX96);
    }

    function testScript13SetManualOraclePriceRun() public {
        address updater = vm.addr(SCRIPT_PK);
        vm.deal(updater, 100 ether);

        ManualPriceOracle oracle = new ManualPriceOracle(1_000e18);
        oracle.transferOwnership(updater);

        vm.setEnv("PRIVATE_KEY", vm.toString(SCRIPT_PK));
        vm.setEnv("PRICE_ORACLE", vm.toString(address(oracle)));
        vm.setEnv("NEW_ORACLE_PRICE_X18", vm.toString(uint256(2_345e18)));

        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);
        SetManualOraclePriceUnichainSepolia script = new SetManualOraclePriceUnichainSepolia();
        script.run();

        assertEq(oracle.latestOraclePriceE18(), 2_345e18);
    }

    function testScript15WithdrawVaultCollateralRun() public {
        address trader = vm.addr(TRADER_PK);
        vm.deal(trader, 100 ether);

        SmokeCore memory core = _deployCoreForSmoke();
        core.usdc.mint(trader, 10_000 * 1e6);

        vm.startPrank(trader);
        core.usdc.approve(address(core.vault), type(uint256).max);
        core.vault.deposit(1_000 * 1e6);
        vm.stopPrank();

        uint256 walletBefore = core.usdc.balanceOf(trader);

        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);
        WithdrawVaultCollateralUnichainSepolia script = new WithdrawVaultCollateralUnichainSepolia();
        script.execute(TRADER_PK, core.vault, 0);

        assertEq(core.vault.usdcBalance(trader), 0);
        assertEq(core.usdc.balanceOf(trader), walletBefore + 1_000 * 1e6);
    }

    function testScript17FundInsuranceFundRun() public {
        address funder = vm.addr(SCRIPT_PK);
        vm.deal(funder, 100 ether);

        SmokeCore memory core = _deployCoreForSmoke();
        core.usdc.mint(funder, 10_000 * 1e6);

        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);
        FundInsuranceFundUnichainSepolia script = new FundInsuranceFundUnichainSepolia();
        script.execute(SCRIPT_PK, core.insuranceFund, IERC20(address(core.usdc)), 2_500 * 1e6);

        assertEq(core.usdc.balanceOf(address(core.insuranceFund)), 2_500 * 1e6);
    }

    function _deployCoreForSmoke() internal returns (SmokeCore memory core) {
        PerpHook hook = _deployHook(address(this));
        VirtualToken veth = new VirtualToken("Virtual ETH", "vETH");
        VirtualToken vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        core.usdc = new MockERC20("USD Coin", "USDC", 6);

        veth.mintMaximumTo(address(this));
        vusdc.mintMaximumTo(address(this));
        _allowVirtualToken(veth);
        _allowVirtualToken(vusdc);

        (Currency currency0, Currency currency1) = _orderedCurrencies(address(veth), address(vusdc));
        PoolKey memory vammPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolKey memory spotPoolKey = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(core.usdc)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(hook)
        );
        core.vammPoolId = vammPoolKey.toId();

        Config config = new Config();
        core.accountBalance = new AccountBalance(config);
        core.clearingHouse = new ClearingHouse(
            poolManager,
            core.accountBalance,
            config,
            vammPoolKey,
            Currency.wrap(address(veth)),
            Currency.wrap(address(vusdc))
        );
        ManualPriceOracle priceOracle = new ManualPriceOracle(1e18);
        core.vault = new Vault(
            core.accountBalance,
            config,
            IERC20(address(core.usdc)),
            priceOracle,
            poolManager,
            positionManager,
            swapRouter,
            spotPoolKey
        );
        FundingRate fundingRate = new FundingRate(poolManager, priceOracle, core.accountBalance, config);
        core.insuranceFund = new InsuranceFund(core.vault, IERC20(address(core.usdc)), address(this), 100e18);

        hook.registerVAMMPool(vammPoolKey, address(veth), address(vusdc));
        hook.registerSpotPool(spotPoolKey);
        hook.setClearingHouse(address(core.clearingHouse));
        hook.setPriceOracle(priceOracle, config.twapInterval());
        hook.setVerifiedRouter(address(positionManager), true);
        hook.setVerifiedRouter(address(swapRouter), true);

        core.accountBalance.setClearingHouse(address(core.clearingHouse));
        core.accountBalance.setVault(address(core.vault));
        core.clearingHouse.setVault(core.vault);
        core.clearingHouse.setFundingRate(fundingRate);
        core.vault.setClearingHouse(address(core.clearingHouse));
        core.vault.setFundingRate(fundingRate);
        core.vault.setInsuranceFund(address(core.insuranceFund));
        fundingRate.setClearingHouse(address(core.clearingHouse));

        veth.addWhitelist(address(core.clearingHouse));
        vusdc.addWhitelist(address(core.clearingHouse));
        veth.transfer(address(core.clearingHouse), 1_000_000_000e18);
        vusdc.transfer(address(core.clearingHouse), 1_000_000_000e18);
    }

    function _deployHook(address owner) internal returns (PerpHook hook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0xbeef << 144)
        );
        deployCodeTo("PerpHook.sol:PerpHook", abi.encode(poolManager, owner), flags);
        hook = PerpHook(flags);
    }

    function _buildPoolKeys(PerpHook hook, VirtualToken veth, VirtualToken vusdc, MockERC20 usdc)
        internal
        pure
        returns (PoolKey memory vammPoolKey, PoolKey memory spotPoolKey)
    {
        (Currency currency0, Currency currency1) = _orderedCurrencies(address(veth), address(vusdc));
        vammPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        spotPoolKey = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(usdc)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook)
        );
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

    function _seedBootstrapAssets(address deployer, VirtualToken veth, VirtualToken vusdc) internal {
        veth.mintMaximumTo(deployer);
        vusdc.mintMaximumTo(deployer);

        veth.addWhitelist(deployer);
        veth.addWhitelist(address(poolManager));
        veth.addWhitelist(address(positionManager));
        veth.addWhitelist(address(permit2));

        vusdc.addWhitelist(deployer);
        vusdc.addWhitelist(address(poolManager));
        vusdc.addWhitelist(address(positionManager));
        vusdc.addWhitelist(address(permit2));
    }

    function _setBaseInitEnv(PerpHook hook, VirtualToken veth, VirtualToken vusdc, MockERC20 usdc) internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(SCRIPT_PK));
        vm.setEnv("PERP_HOOK", vm.toString(address(hook)));
        vm.setEnv("VETH", vm.toString(address(veth)));
        vm.setEnv("VUSDC", vm.toString(address(vusdc)));
        vm.setEnv("USDC", vm.toString(address(usdc)));
        vm.setEnv("POOL_MANAGER", vm.toString(address(poolManager)));
        vm.setEnv("POSITION_MANAGER", vm.toString(address(positionManager)));
        vm.setEnv("PERMIT2", vm.toString(address(permit2)));
        vm.setEnv("LP_RECIPIENT", vm.toString(vm.addr(SCRIPT_PK)));
        vm.setEnv("VAMM_INIT_PRICE_X18", vm.toString(uint256(3_000e18)));
        vm.setEnv("SPOT_INIT_PRICE_X18", vm.toString(uint256(2_300e18)));
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

    function _priceX18ToSqrtPriceX96(uint256 priceX18, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint160)
    {
        uint256 rawPriceX18 = FullMath.mulDiv(priceX18, 10 ** quoteDecimals, 10 ** baseDecimals);
        uint256 ratioX192 = FullMath.mulDiv(rawPriceX18, Q192, 1e18);
        return uint160(Math.sqrt(ratioX192));
    }

    function _vammInitSqrtPriceX96(PoolKey memory key, address baseToken, uint256 quotePerBaseX18)
        internal
        pure
        returns (uint160)
    {
        uint256 rawPriceX18 = Currency.unwrap(key.currency0) == baseToken ? quotePerBaseX18 : 1e36 / quotePerBaseX18;
        return _priceX18ToSqrtPriceX96(rawPriceX18, 18, 18);
    }
}
