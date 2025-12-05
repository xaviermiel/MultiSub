// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title UniswapV3Parser
 * @notice Calldata parser for Uniswap V3 SwapRouter operations
 * @dev Extracts token/amount from Uniswap V3 function calldata
 */
contract UniswapV3Parser is ICalldataParser {
    error UnsupportedSelector();
    error InvalidPath();

    // Uniswap V3 SwapRouter function selectors
    bytes4 public constant EXACT_INPUT_SINGLE_SELECTOR = 0x414bf389;  // exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))
    bytes4 public constant EXACT_INPUT_SELECTOR = 0xc04b8d59;          // exactInput((bytes,address,uint256,uint256,uint256))
    bytes4 public constant EXACT_OUTPUT_SINGLE_SELECTOR = 0xdb3e2198; // exactOutputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))
    bytes4 public constant EXACT_OUTPUT_SELECTOR = 0xf28c0498;         // exactOutput((bytes,address,uint256,uint256,uint256))

    /// @inheritdoc ICalldataParser
    function extractInputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == EXACT_INPUT_SINGLE_SELECTOR) {
            // ExactInputSingleParams: tokenIn is first field
            (token,,,,,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_OUTPUT_SINGLE_SELECTOR) {
            // ExactOutputSingleParams: tokenIn is first field, tokenOut is second
            (token,,,,,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SELECTOR) {
            // ExactInputParams: path contains tokenIn as first 20 bytes
            (bytes memory path,,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            // Extract first 20 bytes of path as address
            assembly {
                // Load 32 bytes starting at path + 32 (skip length)
                // Shift right 96 bits to get address in lower 20 bytes
                token := shr(96, mload(add(path, 32)))
            }
        } else if (selector == EXACT_OUTPUT_SELECTOR) {
            // ExactOutputParams: path is reversed, tokenIn is last 20 bytes
            (bytes memory path,,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            // Extract last 20 bytes of path as address
            assembly {
                token := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
            }
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmount(address, bytes calldata data) external pure override returns (uint256 amount) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == EXACT_INPUT_SINGLE_SELECTOR) {
            // ExactInputSingleParams: amountIn is 6th field (index 5)
            (,,,,, amount,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SELECTOR) {
            // ExactInputParams: amountIn is 4th field
            (,,, amount,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
        } else if (selector == EXACT_OUTPUT_SINGLE_SELECTOR) {
            // ExactOutputSingleParams: amountInMaximum is 7th field
            (,,,,,, amount,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_OUTPUT_SELECTOR) {
            // ExactOutputParams: amountInMaximum is 5th field
            (,,,, amount) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractOutputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == EXACT_INPUT_SINGLE_SELECTOR || selector == EXACT_OUTPUT_SINGLE_SELECTOR) {
            // tokenOut is second field
            (, token,,,,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SELECTOR) {
            // ExactInputParams: path contains tokenOut as last 20 bytes
            (bytes memory path,,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            // Extract last 20 bytes of path as address
            // path layout: [length (32 bytes)][data...]
            // We need bytes at position (length - 20) to (length)
            assembly {
                // Load 32 bytes starting at (path + 32 + length - 20)
                // This gives us [12 garbage bytes][20 address bytes]
                // Shift right 96 bits (12 bytes) to get address in lower 20 bytes
                token := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
            }
        } else if (selector == EXACT_OUTPUT_SELECTOR) {
            // ExactOutputParams: path is reversed, tokenOut is first 20 bytes
            (bytes memory path,,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            // Extract first 20 bytes of path as address
            assembly {
                // Load 32 bytes starting at path + 32 (skip length)
                // This gives us [20 address bytes][12 garbage bytes]
                // Shift right 96 bits to get address in lower 20 bytes
                token := shr(96, mload(add(path, 32)))
            }
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == EXACT_INPUT_SINGLE_SELECTOR ||
               selector == EXACT_INPUT_SELECTOR ||
               selector == EXACT_OUTPUT_SINGLE_SELECTOR ||
               selector == EXACT_OUTPUT_SELECTOR;
    }

    /**
     * @notice Get the operation type for a given selector
     * @param selector The function selector
     * @return opType 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     */
    function getOperationType(bytes4 selector) external pure returns (uint8 opType) {
        if (selector == EXACT_INPUT_SINGLE_SELECTOR ||
            selector == EXACT_INPUT_SELECTOR ||
            selector == EXACT_OUTPUT_SINGLE_SELECTOR ||
            selector == EXACT_OUTPUT_SELECTOR) {
            return 1; // SWAP
        }
        return 0; // UNKNOWN
    }
}
