// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

library FormatUtils {
    function formatX18(uint256 value) internal pure returns (string memory) {
        return formatScaled(value, 18, 6);
    }

    function formatSignedX18(int256 value) internal pure returns (string memory) {
        return formatSignedScaled(value, 18, 6);
    }

    function formatUsdcRaw(uint256 value) internal pure returns (string memory) {
        return formatScaled(value, 6, 6);
    }

    function formatEth(uint256 value) internal pure returns (string memory) {
        return formatScaled(value, 18, 6);
    }

    function formatScaled(uint256 value, uint8 decimals, uint8 precision) internal pure returns (string memory) {
        uint256 base = 10 ** decimals;
        uint256 whole = value / base;
        if (precision == 0) {
            return Strings.toString(whole);
        }

        uint256 scale = 10 ** precision;
        uint256 fraction = (value % base) * scale / base;
        return string.concat(Strings.toString(whole), ".", _padLeft(Strings.toString(fraction), precision));
    }

    function formatSignedScaled(int256 value, uint8 decimals, uint8 precision) internal pure returns (string memory) {
        if (value >= 0) {
            return formatScaled(uint256(value), decimals, precision);
        }
        return string.concat("-", formatScaled(_abs(value), decimals, precision));
    }

    function _padLeft(string memory value, uint256 width) private pure returns (string memory) {
        bytes memory raw = bytes(value);
        if (raw.length >= width) return value;
        bytes memory out = new bytes(width);
        uint256 pad = width - raw.length;
        for (uint256 i = 0; i < pad; ++i) {
            out[i] = bytes1("0");
        }
        for (uint256 i = 0; i < raw.length; ++i) {
            out[pad + i] = raw[i];
        }
        return string(out);
    }

    function _abs(int256 value) private pure returns (uint256) {
        if (value >= 0) return uint256(value);
        unchecked {
            return uint256(-(value + 1)) + 1;
        }
    }
}
