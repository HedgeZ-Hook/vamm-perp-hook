// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {UnichainSepoliaConstants} from "./base/UnichainSepoliaConstants.sol";

contract WithdrawBootstrapLiquidityUnichainSepolia is Script {
    error InvalidChain(uint256 actual, uint256 expected);
    error MissingAddress(string name);
    error NothingToWithdraw();

    struct Inputs {
        uint256 pk;
        address deployer;
        address recipient;
        IPositionManager positionManager;
        uint256 vammTokenId;
        uint256 spotTokenId;
    }

    function run() external {
        _assertChain();

        Inputs memory inp = loadInputsFromEnv();
        _execute(inp);
    }

    function loadInputsFromEnv() public view returns (Inputs memory inp) {
        _assertChain();

        inp.pk = vm.envUint("PRIVATE_KEY");
        inp.deployer = vm.addr(inp.pk);
        inp.recipient = vm.envOr("WITHDRAW_RECIPIENT", inp.deployer);
        inp.positionManager = IPositionManager(vm.envOr("POSITION_MANAGER", UnichainSepoliaConstants.POSITION_MANAGER));
        inp.vammTokenId = vm.envOr("VAMM_TOKEN_ID", uint256(0));
        inp.spotTokenId = vm.envOr("SPOT_TOKEN_ID", uint256(0));
        if (address(inp.positionManager) == address(0)) revert MissingAddress("POSITION_MANAGER");
    }

    function execute(
        uint256 pk,
        IPositionManager positionManager,
        address recipient,
        uint256 vammTokenId,
        uint256 spotTokenId
    ) external {
        _assertChain();
        Inputs memory inp = Inputs({
            pk: pk,
            deployer: vm.addr(pk),
            recipient: recipient,
            positionManager: positionManager,
            vammTokenId: vammTokenId,
            spotTokenId: spotTokenId
        });
        _execute(inp);
    }

    function _assertChain() internal view {
        if (block.chainid != UnichainSepoliaConstants.CHAIN_ID) {
            revert InvalidChain(block.chainid, UnichainSepoliaConstants.CHAIN_ID);
        }
    }

    function _execute(Inputs memory inp) internal {
        if (inp.vammTokenId == 0 && inp.spotTokenId == 0) revert NothingToWithdraw();

        vm.startBroadcast(inp.pk);
        if (inp.vammTokenId != 0) {
            _withdrawFullPosition(inp.positionManager, inp.vammTokenId, inp.recipient, "vAMM");
        }
        if (inp.spotTokenId != 0) {
            _withdrawFullPosition(inp.positionManager, inp.spotTokenId, inp.recipient, "Spot");
        }
        vm.stopBroadcast();
    }

    function _withdrawFullPosition(
        IPositionManager positionManager,
        uint256 tokenId,
        address recipient,
        string memory label
    ) internal {
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);

        if (liquidity > 0) {
            bytes[] memory decreaseParams = new bytes[](2);
            decreaseParams[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
            decreaseParams[1] = abi.encode(key.currency0, key.currency1, recipient);

            positionManager.modifyLiquidities(
                abi.encode(
                    abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), decreaseParams
                ),
                block.timestamp + 1 hours
            );
        }

        bytes[] memory burnParams = new bytes[](2);
        burnParams[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        burnParams[1] = abi.encode(key.currency0, key.currency1, recipient);

        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)), burnParams),
            block.timestamp + 1 hours
        );

        console2.log("===== Position Withdrawn =====");
        console2.log("Label:", label);
        console2.log("TokenId:", tokenId);
        console2.log("Recipient:", recipient);
        console2.log("Currency0:", Currency.unwrap(key.currency0));
        console2.log("Currency1:", Currency.unwrap(key.currency1));
    }
}
