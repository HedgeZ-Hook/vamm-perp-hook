// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract InitPoolsAndBootstrapUnichainSepolia is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error InvalidChain(uint256 actual, uint256 expected);
    error MissingAddress(string name);

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
        uint256 vammInitPriceX18;
        uint256 spotInitPriceX18;
        uint128 vammBootstrapLiquidity;
        uint128 spotBootstrapLiquidity;
    }

    function run() external {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        Inputs memory inp = _loadInputs(pk);
        (PoolKey memory vammPoolKey, PoolKey memory spotPoolKey) = _buildPoolKeys(inp);

        vm.startBroadcast(pk);
        _approveForPosm(inp);
        _initializeIfNeeded(inp.poolManager, vammPoolKey, _priceX18ToSqrtPriceX96(inp.vammInitPriceX18));
        _initializeIfNeeded(inp.poolManager, spotPoolKey, _priceX18ToSqrtPriceX96(inp.spotInitPriceX18));

        if (inp.vammBootstrapLiquidity > 0) {
            _mintFullRange(
                inp.positionManager,
                vammPoolKey,
                _priceX18ToSqrtPriceX96(inp.vammInitPriceX18),
                inp.vammBootstrapLiquidity,
                inp.lpRecipient
            );
        }
        if (inp.spotBootstrapLiquidity > 0) {
            _mintFullRange(
                inp.positionManager,
                spotPoolKey,
                _priceX18ToSqrtPriceX96(inp.spotInitPriceX18),
                inp.spotBootstrapLiquidity,
                inp.lpRecipient
            );
        }
        vm.stopBroadcast();

        console2.log("===== Pools Initialized / Liquidity Bootstrapped =====");
        console2.log("Deployer:", inp.deployer);
        console2.log("vAMM PoolId:", uint256(PoolId.unwrap(vammPoolKey.toId())));
        console2.log("Spot PoolId:", uint256(PoolId.unwrap(spotPoolKey.toId())));
        console2.log("vAMM bootstrap liquidity:", uint256(inp.vammBootstrapLiquidity));
        console2.log("Spot bootstrap liquidity:", uint256(inp.spotBootstrapLiquidity));
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
        inp.vammInitPriceX18 = vm.envOr("VAMM_INIT_PRICE_X18", uint256(3_000e18));
        inp.spotInitPriceX18 = vm.envOr("SPOT_INIT_PRICE_X18", uint256(3_000e18));
        inp.vammBootstrapLiquidity = uint128(vm.envOr("VAMM_BOOTSTRAP_LIQUIDITY", uint256(1_000e18)));
        inp.spotBootstrapLiquidity = uint128(vm.envOr("SPOT_BOOTSTRAP_LIQUIDITY", uint256(0)));
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

    function _mintFullRange(
        IPositionManager positionManager,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        uint128 liquidityAmount,
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
        positionManager.modifyLiquidities{value: valueToPass}(abi.encode(actions, params), block.timestamp + 1 hours);
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

    function _priceX18ToSqrtPriceX96(uint256 priceX18) internal pure returns (uint160 sqrtPriceX96) {
        uint256 ratioX192 = FullMath.mulDiv(priceX18, Q192, 1e18);
        sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
    }
}
