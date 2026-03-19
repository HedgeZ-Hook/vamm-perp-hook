// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

abstract contract InitPoolsBootstrapBase is Script {
    using StateLibrary for IPoolManager;

    error InvalidChain(uint256 actual, uint256 expected);
    error MissingAddress(string name);
    error InsufficientNativeBalance(uint256 required, uint256 available);
    error InsufficientTokenBalance(address token, uint256 required, uint256 available);
    error SpotBootstrapConfigConflict(uint128 liquidity, uint256 nativeAmount, uint256 quoteAmount);

    uint256 internal constant Q192 = 2 ** 192;

    struct Inputs {
        address deployer;
        address hook;
        address veth;
        address vusdc;
        address usdc;
        address permit2;
        IPoolManager poolManager;
        IPositionManager positionManager;
        address lpRecipient;
        uint8 usdcDecimals;
        uint256 vammInitPriceX18;
        uint256 spotInitPriceX18;
        uint128 vammBootstrapLiquidity;
        uint128 spotBootstrapLiquidity;
        uint256 spotBootstrapNativeAmount;
        uint256 spotBootstrapQuoteAmount;
    }

    function _assertChain() internal view {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }
    }

    function _loadInputs(uint256 pk) internal view returns (Inputs memory inp) {
        inp.deployer = vm.addr(pk);
        inp.hook = vm.envAddress("PERP_HOOK");
        inp.veth = vm.envAddress("VETH");
        inp.vusdc = vm.envAddress("VUSDC");
        inp.usdc = vm.envAddress("USDC");
        if (inp.hook == address(0)) revert MissingAddress("PERP_HOOK");
        if (inp.veth == address(0)) revert MissingAddress("VETH");
        if (inp.vusdc == address(0)) revert MissingAddress("VUSDC");
        if (inp.usdc == address(0)) revert MissingAddress("USDC");

        inp.poolManager = IPoolManager(vm.envOr("POOL_MANAGER", UnichainSepoliaConstants.POOL_MANAGER));
        inp.positionManager = IPositionManager(vm.envOr("POSITION_MANAGER", UnichainSepoliaConstants.POSITION_MANAGER));
        inp.permit2 = vm.envOr("PERMIT2", UnichainSepoliaConstants.PERMIT2);
        inp.lpRecipient = vm.envOr("LP_RECIPIENT", inp.deployer);
        inp.usdcDecimals = IERC20Metadata(inp.usdc).decimals();
        inp.vammInitPriceX18 = vm.envOr("VAMM_INIT_PRICE_X18", uint256(3_000e18));
        inp.spotInitPriceX18 = vm.envOr("SPOT_INIT_PRICE_X18", uint256(3_000e18));
        inp.vammBootstrapLiquidity = uint128(vm.envOr("VAMM_BOOTSTRAP_LIQUIDITY", uint256(1_000e18)));
        inp.spotBootstrapLiquidity = uint128(vm.envOr("SPOT_BOOTSTRAP_LIQUIDITY", uint256(0)));
        inp.spotBootstrapNativeAmount = vm.envOr("SPOT_BOOTSTRAP_ETH_AMOUNT", uint256(0));
        inp.spotBootstrapQuoteAmount = vm.envOr("SPOT_BOOTSTRAP_USDC_AMOUNT", uint256(0));
    }

    function _buildPoolKeys(Inputs memory inp)
        internal
        pure
        returns (PoolKey memory vammPoolKey, PoolKey memory spotPoolKey)
    {
        (Currency vammCurrency0, Currency vammCurrency1) = _orderedCurrencies(inp.veth, inp.vusdc);
        vammPoolKey = PoolKey({
            currency0: vammCurrency0,
            currency1: vammCurrency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(inp.hook)
        });
        spotPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(inp.usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(inp.hook)
        });
    }

    function _vammInitSqrtPriceX96(Inputs memory inp, PoolKey memory vammPoolKey) internal pure returns (uint160) {
        uint256 rawPriceX18 =
            Currency.unwrap(vammPoolKey.currency0) == inp.veth ? inp.vammInitPriceX18 : 1e36 / inp.vammInitPriceX18;
        return _priceX18ToSqrtPriceX96(rawPriceX18, 18, 18);
    }

    function _spotInitSqrtPriceX96(Inputs memory inp) internal pure returns (uint160) {
        return _priceX18ToSqrtPriceX96(inp.spotInitPriceX18, 18, inp.usdcDecimals);
    }

    function _approveForPosm(Inputs memory inp) internal {
        _approveToken(inp.veth, inp.permit2, address(inp.positionManager), address(inp.poolManager));
        _approveToken(inp.vusdc, inp.permit2, address(inp.positionManager), address(inp.poolManager));
        _approveToken(inp.usdc, inp.permit2, address(inp.positionManager), address(inp.poolManager));
    }

    function _approveToken(address token, address permit2, address positionManager, address poolManager) internal {
        IERC20(token).approve(permit2, type(uint256).max);
        IPermit2(permit2).approve(token, positionManager, type(uint160).max, type(uint48).max);
        IPermit2(permit2).approve(token, poolManager, type(uint160).max, type(uint48).max);
    }

    function _initializeIfNeeded(IPoolManager poolManager, PoolKey memory key, uint160 initSqrtPriceX96) internal {
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (currentSqrtPriceX96 == 0) poolManager.initialize(key, initSqrtPriceX96);
    }

    function _mintVammIfNeeded(Inputs memory inp, PoolKey memory vammPoolKey) internal returns (bool didMint) {
        if (inp.vammBootstrapLiquidity == 0) return false;

        _mintFullRange(
            inp.positionManager,
            vammPoolKey,
            _vammInitSqrtPriceX96(inp, vammPoolKey),
            inp.vammBootstrapLiquidity,
            inp.deployer,
            inp.lpRecipient
        );
        return true;
    }

    function _mintSpotIfNeeded(Inputs memory inp, PoolKey memory spotPoolKey)
        internal
        returns (uint128 liquidityMinted)
    {
        liquidityMinted = _resolveSpotBootstrapLiquidity(inp, spotPoolKey, _spotInitSqrtPriceX96(inp));
        if (liquidityMinted == 0) return 0;

        _mintFullRange(
            inp.positionManager, spotPoolKey, _spotInitSqrtPriceX96(inp), liquidityMinted, inp.deployer, inp.lpRecipient
        );
    }

    function _mintFullRange(
        IPositionManager positionManager,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        uint128 liquidityAmount,
        address payer,
        address recipient
    ) internal {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            key, tickLower, tickUpper, liquidityAmount, amount0Expected + 1, amount1Expected + 1, recipient, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, recipient);
        params[3] = abi.encode(key.currency1, recipient);

        uint256 valueToPass = Currency.unwrap(key.currency0) == address(0) ? amount0Expected + 1 : 0;
        _assertFundingAvailable(payer, key, amount0Expected + 1, amount1Expected + 1);
        positionManager.modifyLiquidities{value: valueToPass}(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _resolveSpotBootstrapLiquidity(Inputs memory inp, PoolKey memory spotPoolKey, uint160 spotInitSqrtPriceX96)
        internal
        pure
        returns (uint128 liquidityToMint)
    {
        if (inp.spotBootstrapNativeAmount == 0 && inp.spotBootstrapQuoteAmount == 0) {
            return inp.spotBootstrapLiquidity;
        }
        if (inp.spotBootstrapLiquidity > 0) {
            revert SpotBootstrapConfigConflict(
                inp.spotBootstrapLiquidity, inp.spotBootstrapNativeAmount, inp.spotBootstrapQuoteAmount
            );
        }

        int24 tickLower = TickMath.minUsableTick(spotPoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(spotPoolKey.tickSpacing);
        liquidityToMint = LiquidityAmounts.getLiquidityForAmounts(
            spotInitSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            inp.spotBootstrapNativeAmount,
            inp.spotBootstrapQuoteAmount
        );
    }

    function _assertFundingAvailable(
        address payer,
        PoolKey memory key,
        uint256 requiredAmount0,
        uint256 requiredAmount1
    ) internal view {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        if (token0 == address(0)) {
            uint256 availableNative = payer.balance;
            if (availableNative < requiredAmount0) {
                revert InsufficientNativeBalance(requiredAmount0, availableNative);
            }
        } else {
            uint256 token0Balance = IERC20(token0).balanceOf(payer);
            if (token0Balance < requiredAmount0) {
                revert InsufficientTokenBalance(token0, requiredAmount0, token0Balance);
            }
        }

        if (token1 == address(0)) {
            uint256 availableNative = payer.balance;
            if (availableNative < requiredAmount1) {
                revert InsufficientNativeBalance(requiredAmount1, availableNative);
            }
        } else {
            uint256 token1Balance = IERC20(token1).balanceOf(payer);
            if (token1Balance < requiredAmount1) {
                revert InsufficientTokenBalance(token1, requiredAmount1, token1Balance);
            }
        }
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
        returns (uint160 sqrtPriceX96)
    {
        uint256 rawPriceX18 = FullMath.mulDiv(priceX18, 10 ** quoteDecimals, 10 ** baseDecimals);
        uint256 ratioX192 = FullMath.mulDiv(rawPriceX18, Q192, 1e18);
        sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
    }
}
