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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {MockPriceOracle} from "./MockPriceOracle.sol";

import {PerpHook} from "../src/PerpHook.sol";
import {VirtualToken} from "../src/VirtualToken.sol";
import {Config} from "../src/Config.sol";
import {AccountBalance} from "../src/AccountBalance.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {Vault} from "../src/Vault.sol";
import {FundingRate} from "../src/FundingRate.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {ManualPriceOracle} from "../src/ManualPriceOracle.sol";
import {LiquidityController} from "../src/LiquidityController.sol";

import {InitPoolsAndBootstrapUnichainSepolia} from "../script/11_InitPoolsAndBootstrap.s.sol";
import {ApproveBootstrapTokensUnichainSepolia} from "../script/11.1_ApproveBootstrapTokens.s.sol";
import {InitializePoolsUnichainSepolia} from "../script/11.2_InitializePools.s.sol";
import {BootstrapVammPoolUnichainSepolia} from "../script/11.3_BootstrapVammPool.s.sol";
import {BootstrapSpotPoolUnichainSepolia} from "../script/11.4_BootstrapSpotPool.s.sol";
import {WithdrawBootstrapLiquidityUnichainSepolia} from "../script/14_WithdrawBootstrapLiquidity.s.sol";
import {WithdrawVaultCollateralUnichainSepolia} from "../script/15_WithdrawVaultCollateral.s.sol";
import {FundInsuranceFundUnichainSepolia} from "../script/17_FundInsuranceFund.s.sol";
import {SmokeTestPerpUnichainSepolia} from "../script/12_SmokeTestPerp.s.sol";
import {SetManualOraclePriceUnichainSepolia} from "../script/13_SetManualOraclePrice.s.sol";
import {SetLiquidityControllerParamsUnichainSepolia} from "../script/27_SetLiquidityControllerParams.s.sol";
import {UnichainSepoliaConstants} from "../script/base/UnichainSepoliaConstants.sol";

contract ScriptsDryRunTest is BaseTest {
    using EasyPosm for IPositionManager;
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

    struct WithdrawCore {
        address deployer;
        PerpHook hook;
        VirtualToken veth;
        VirtualToken vusdc;
        MockERC20 usdc;
        uint256 vammTokenId;
        uint256 spotTokenId;
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

    function testSplit11ScriptsRunSequentially() public {
        address deployer = vm.addr(SCRIPT_PK);
        vm.deal(deployer, 1_000 ether);

        PerpHook hook = _deployHook(address(this));
        VirtualToken veth = new VirtualToken("Virtual ETH", "vETH");
        VirtualToken vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(deployer, 1_000_000_000_000e6);
        _seedBootstrapAssets(deployer, veth, vusdc);

        _setBaseInitEnv(hook, veth, vusdc, usdc);
        vm.setEnv("VAMM_BOOTSTRAP_LIQUIDITY", vm.toString(uint256(1_000e18)));
        vm.setEnv("SPOT_BOOTSTRAP_LIQUIDITY", vm.toString(uint256(0)));
        vm.setEnv("SPOT_BOOTSTRAP_ETH_AMOUNT", vm.toString(uint256(0.1 ether)));
        vm.setEnv("SPOT_BOOTSTRAP_USDC_AMOUNT", vm.toString(uint256(230_000_000)));

        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);
        ApproveBootstrapTokensUnichainSepolia approveScript = new ApproveBootstrapTokensUnichainSepolia();
        InitializePoolsUnichainSepolia initScript = new InitializePoolsUnichainSepolia();
        BootstrapVammPoolUnichainSepolia vammScript = new BootstrapVammPoolUnichainSepolia();
        BootstrapSpotPoolUnichainSepolia spotScript = new BootstrapSpotPoolUnichainSepolia();

        _setSequentialBootstrapEnv(hook, veth, vusdc, usdc);
        approveScript.run();
        _setSequentialBootstrapEnv(hook, veth, vusdc, usdc);
        initScript.run();
        _setSequentialBootstrapEnv(hook, veth, vusdc, usdc);
        vammScript.run();
        _setSequentialBootstrapEnv(hook, veth, vusdc, usdc);
        spotScript.run();

        (PoolKey memory vammPoolKey, PoolKey memory spotPoolKey) = _buildPoolKeys(hook, veth, vusdc, usdc);
        (uint160 vammSqrtPriceX96,,,) = poolManager.getSlot0(vammPoolKey.toId());
        (uint160 spotSqrtPriceX96,,,) = poolManager.getSlot0(spotPoolKey.toId());
        uint128 vammLiquidity = poolManager.getLiquidity(vammPoolKey.toId());
        uint128 spotLiquidity = poolManager.getLiquidity(spotPoolKey.toId());
        uint160 expectedVammSqrtPriceX96 = _vammInitSqrtPriceX96(vammPoolKey, address(veth), 3_000e18);
        uint160 expectedSpotSqrtPriceX96 = _priceX18ToSqrtPriceX96(2_300e18, 18, 6);

        assertEq(vammSqrtPriceX96, expectedVammSqrtPriceX96);
        assertEq(spotSqrtPriceX96, expectedSpotSqrtPriceX96);
        assertGt(vammLiquidity, 0);
        assertGt(spotLiquidity, 0);
    }

    function testScript14WithdrawBootstrapLiquidityRun() public {
        WithdrawCore memory core = _bootstrapPositionsForWithdraw();
        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);

        uint256 ethBefore = core.deployer.balance;
        uint256 usdcBefore = core.usdc.balanceOf(core.deployer);
        uint256 vethBefore = core.veth.balanceOf(core.deployer);
        uint256 vusdcBefore = core.vusdc.balanceOf(core.deployer);

        WithdrawBootstrapLiquidityUnichainSepolia withdrawScript = new WithdrawBootstrapLiquidityUnichainSepolia();
        withdrawScript.execute(SCRIPT_PK, positionManager, core.deployer, core.vammTokenId, core.spotTokenId);

        assertEq(positionManager.getPositionLiquidity(core.vammTokenId), 0);
        assertEq(positionManager.getPositionLiquidity(core.spotTokenId), 0);
        vm.expectRevert();
        IERC721(address(positionManager)).ownerOf(core.vammTokenId);
        vm.expectRevert();
        IERC721(address(positionManager)).ownerOf(core.spotTokenId);

        assertGt(core.deployer.balance, ethBefore);
        assertGt(core.usdc.balanceOf(core.deployer), usdcBefore);
        assertGt(core.veth.balanceOf(core.deployer), vethBefore);
        assertGt(core.vusdc.balanceOf(core.deployer), vusdcBefore);
    }

    function testScript12SmokeRunOpenCloseWithUSDC6() public {
        address trader = vm.addr(TRADER_PK);
        vm.deal(trader, 100 ether);

        SmokeCore memory core = _deployCoreForSmoke(true);

        core.usdc.mint(trader, 10_000 * 1e6);

        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);
        SmokeTestPerpUnichainSepolia script = new SmokeTestPerpUnichainSepolia();
        script.execute(TRADER_PK, address(core.usdc), core.vault, core.clearingHouse, 1_000 * 1e6, 1e18);

        assertEq(core.accountBalance.getTakerPositionSize(trader, core.vammPoolId), 0);
        assertEq(core.accountBalance.getTakerOpenNotional(trader, core.vammPoolId), 0);
        assertGt(core.vault.usdcBalance(trader), 0);
    }

    function testScript12RevertsEarlyWhenVammPoolNotInitialized() public {
        address trader = vm.addr(TRADER_PK);
        vm.deal(trader, 100 ether);

        SmokeCore memory core = _deployCoreForSmoke(false);
        core.usdc.mint(trader, 10_000 * 1e6);

        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);
        SmokeTestPerpUnichainSepolia script = new SmokeTestPerpUnichainSepolia();
        (bool ok, bytes memory err) = address(script)
            .call(
                abi.encodeCall(
                    SmokeTestPerpUnichainSepolia.execute,
                    (TRADER_PK, address(core.usdc), core.vault, core.clearingHouse, 1_000 * 1e6, 1e18)
                )
            );
        assertTrue(!ok);
        bytes4 selector;
        assembly {
            selector := mload(add(err, 0x20))
        }
        assertEq(selector, SmokeTestPerpUnichainSepolia.VammPoolNotInitialized.selector);
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

        SmokeCore memory core = _deployCoreForSmoke(false);
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

        SmokeCore memory core = _deployCoreForSmoke(false);
        core.usdc.mint(funder, 10_000 * 1e6);

        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);
        FundInsuranceFundUnichainSepolia script = new FundInsuranceFundUnichainSepolia();
        script.execute(SCRIPT_PK, core.insuranceFund, IERC20(address(core.usdc)), 2_500 * 1e6);

        assertEq(core.usdc.balanceOf(address(core.insuranceFund)), 2_500 * 1e6);
    }

    function testScript27SetLiquidityControllerParamsRun() public {
        address admin = vm.addr(SCRIPT_PK);
        vm.deal(admin, 100 ether);

        PerpHook hook = _deployHook(admin);
        VirtualToken veth = new VirtualToken("Virtual ETH", "vETH");
        VirtualToken vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        MockPriceOracle oracle = new MockPriceOracle(2_300e18);

        (Currency currency0, Currency currency1) = _orderedCurrencies(address(veth), address(vusdc));
        PoolKey memory vammPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));

        vm.startPrank(admin);
        LiquidityController controller = new LiquidityController(
            poolManager, swapRouter, oracle, vammPoolKey, address(veth), address(vusdc), 900, 10, 30, 5e18, 1_000e18
        );
        vm.stopPrank();

        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);
        SetLiquidityControllerParamsUnichainSepolia script = new SetLiquidityControllerParamsUnichainSepolia();
        script.execute(SCRIPT_PK, controller, 10, 30, 50e18, 1_000e18);

        assertEq(controller.deadbandBps(), 10);
        assertEq(controller.maxRepriceBpsPerUpdate(), 30);
        assertEq(controller.maxAmountInPerUpdate(), 50e18);
        assertEq(controller.minVammLiquidity(), 1_000e18);
    }

    function _deployCoreForSmoke(bool bootstrapVamm) internal returns (SmokeCore memory core) {
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
        MockPriceOracle priceOracle = new MockPriceOracle(1e18);
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

        if (bootstrapVamm) {
            poolManager.initialize(vammPoolKey, Constants.SQRT_PRICE_1_1);
            _mintVammFullRange(vammPoolKey, 1_000_000e18);
        }
    }

    function _bootstrapPositionsForWithdraw() internal returns (WithdrawCore memory core) {
        core.deployer = vm.addr(SCRIPT_PK);
        vm.deal(core.deployer, 1_000 ether);

        core.hook = _deployHook(address(this));
        core.veth = new VirtualToken("Virtual ETH", "vETH");
        core.vusdc = new VirtualToken("Virtual USDC", "vUSDC");
        core.usdc = new MockERC20("USD Coin", "USDC", 6);
        core.usdc.mint(core.deployer, 1_000_000_000_000e6);
        _seedBootstrapAssets(core.deployer, core.veth, core.vusdc);

        _setSequentialBootstrapEnv(core.hook, core.veth, core.vusdc, core.usdc);
        vm.chainId(UnichainSepoliaConstants.CHAIN_ID);

        ApproveBootstrapTokensUnichainSepolia approveScript = new ApproveBootstrapTokensUnichainSepolia();
        InitializePoolsUnichainSepolia initScript = new InitializePoolsUnichainSepolia();
        BootstrapVammPoolUnichainSepolia vammScript = new BootstrapVammPoolUnichainSepolia();
        BootstrapSpotPoolUnichainSepolia spotScript = new BootstrapSpotPoolUnichainSepolia();

        approveScript.run();
        _setSequentialBootstrapEnv(core.hook, core.veth, core.vusdc, core.usdc);
        initScript.run();

        core.vammTokenId = positionManager.nextTokenId();
        _setSequentialBootstrapEnv(core.hook, core.veth, core.vusdc, core.usdc);
        vammScript.run();

        core.spotTokenId = positionManager.nextTokenId();
        _setSequentialBootstrapEnv(core.hook, core.veth, core.vusdc, core.usdc);
        spotScript.run();
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

    function _setSequentialBootstrapEnv(PerpHook hook, VirtualToken veth, VirtualToken vusdc, MockERC20 usdc) internal {
        _setBaseInitEnv(hook, veth, vusdc, usdc);
        vm.setEnv("VAMM_BOOTSTRAP_LIQUIDITY", vm.toString(uint256(1_000e18)));
        vm.setEnv("SPOT_BOOTSTRAP_LIQUIDITY", vm.toString(uint256(0)));
        vm.setEnv("SPOT_BOOTSTRAP_ETH_AMOUNT", vm.toString(uint256(0.1 ether)));
        vm.setEnv("SPOT_BOOTSTRAP_USDC_AMOUNT", vm.toString(uint256(230_000_000)));
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

    function _mintVammFullRange(PoolKey memory key, uint128 liquidityAmount) internal returns (uint256 tokenId) {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
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
