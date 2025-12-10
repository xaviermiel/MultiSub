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

    // Uniswap V3 SwapRouter function selectors (with deadline in struct)
    bytes4 public constant EXACT_INPUT_SINGLE_SELECTOR = 0x414bf389;  // exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))
    bytes4 public constant EXACT_INPUT_SELECTOR = 0xc04b8d59;          // exactInput((bytes,address,uint256,uint256,uint256))
    bytes4 public constant EXACT_OUTPUT_SINGLE_SELECTOR = 0xdb3e2198; // exactOutputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))
    bytes4 public constant EXACT_OUTPUT_SELECTOR = 0xf28c0498;         // exactOutput((bytes,address,uint256,uint256,uint256))

    // SwapRouter02 function selectors (no deadline in struct, handled via multicall)
    bytes4 public constant EXACT_INPUT_SINGLE_02_SELECTOR = 0x04e45aaf;  // exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))
    bytes4 public constant EXACT_INPUT_02_SELECTOR = 0xb858183f;          // exactInput((bytes,address,uint256,uint256))
    bytes4 public constant EXACT_OUTPUT_SINGLE_02_SELECTOR = 0x5023b4df; // exactOutputSingle((address,address,uint24,address,uint256,uint256,uint160))
    bytes4 public constant EXACT_OUTPUT_02_SELECTOR = 0x09b81346;         // exactOutput((bytes,address,uint256,uint256))

    /// @inheritdoc ICalldataParser
    function extractInputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == EXACT_INPUT_SINGLE_SELECTOR) {
            // ExactInputSingleParams (V1): tokenIn is first field
            (token,,,,,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SINGLE_02_SELECTOR) {
            // ExactInputSingleParams (V2): no deadline, tokenIn is first field
            (token,,,,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint160));
        } else if (selector == EXACT_OUTPUT_SINGLE_SELECTOR) {
            // ExactOutputSingleParams (V1): tokenIn is first field, tokenOut is second
            (token,,,,,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_OUTPUT_SINGLE_02_SELECTOR) {
            // ExactOutputSingleParams (V2): no deadline
            (token,,,,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SELECTOR) {
            // ExactInputParams (V1): path contains tokenIn as first 20 bytes
            (bytes memory path,,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            assembly {
                token := shr(96, mload(add(path, 32)))
            }
        } else if (selector == EXACT_INPUT_02_SELECTOR) {
            // ExactInputParams (V2): no deadline
            (bytes memory path,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            assembly {
                token := shr(96, mload(add(path, 32)))
            }
        } else if (selector == EXACT_OUTPUT_SELECTOR) {
            // ExactOutputParams (V1): path is reversed, tokenIn is last 20 bytes
            (bytes memory path,,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            assembly {
                token := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
            }
        } else if (selector == EXACT_OUTPUT_02_SELECTOR) {
            // ExactOutputParams (V2): no deadline
            (bytes memory path,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
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
            // ExactInputSingleParams (V1): amountIn is 6th field (index 5, after deadline)
            (,,,,, amount,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SINGLE_02_SELECTOR) {
            // ExactInputSingleParams (V2): amountIn is 5th field (no deadline)
            (,,,, amount,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SELECTOR) {
            // ExactInputParams (V1): amountIn is 4th field
            (,,, amount,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
        } else if (selector == EXACT_INPUT_02_SELECTOR) {
            // ExactInputParams (V2): amountIn is 3rd field (no deadline)
            (,, amount,) = abi.decode(data[4:], (bytes, address, uint256, uint256));
        } else if (selector == EXACT_OUTPUT_SINGLE_SELECTOR) {
            // ExactOutputSingleParams (V1): amountInMaximum is 7th field
            (,,,,,, amount,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_OUTPUT_SINGLE_02_SELECTOR) {
            // ExactOutputSingleParams (V2): amountInMaximum is 6th field (no deadline)
            (,,,,, amount,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint160));
        } else if (selector == EXACT_OUTPUT_SELECTOR) {
            // ExactOutputParams (V1): amountInMaximum is 5th field
            (,,,, amount) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
        } else if (selector == EXACT_OUTPUT_02_SELECTOR) {
            // ExactOutputParams (V2): amountInMaximum is 4th field (no deadline)
            (,,, amount) = abi.decode(data[4:], (bytes, address, uint256, uint256));
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractOutputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == EXACT_INPUT_SINGLE_SELECTOR || selector == EXACT_OUTPUT_SINGLE_SELECTOR) {
            // tokenOut is second field (V1)
            (, token,,,,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SINGLE_02_SELECTOR || selector == EXACT_OUTPUT_SINGLE_02_SELECTOR) {
            // tokenOut is second field (V2, no deadline)
            (, token,,,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SELECTOR) {
            // ExactInputParams (V1): path contains tokenOut as last 20 bytes
            (bytes memory path,,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            assembly {
                token := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
            }
        } else if (selector == EXACT_INPUT_02_SELECTOR) {
            // ExactInputParams (V2): no deadline
            (bytes memory path,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            assembly {
                token := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
            }
        } else if (selector == EXACT_OUTPUT_SELECTOR) {
            // ExactOutputParams (V1): path is reversed, tokenOut is first 20 bytes
            (bytes memory path,,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            assembly {
                token := shr(96, mload(add(path, 32)))
            }
        } else if (selector == EXACT_OUTPUT_02_SELECTOR) {
            // ExactOutputParams (V2): no deadline
            (bytes memory path,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256));
            if (path.length < 20) revert InvalidPath();
            assembly {
                token := shr(96, mload(add(path, 32)))
            }
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address) external pure override returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == EXACT_INPUT_SINGLE_SELECTOR || selector == EXACT_OUTPUT_SINGLE_SELECTOR) {
            // V1 Single: (tokenIn, tokenOut, fee, recipient, deadline, amountIn, amountOutMin, sqrtPriceLimitX96)
            (,,, recipient,,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SINGLE_02_SELECTOR || selector == EXACT_OUTPUT_SINGLE_02_SELECTOR) {
            // V2 Single (no deadline): (tokenIn, tokenOut, fee, recipient, amountIn, amountOutMin, sqrtPriceLimitX96)
            (,,, recipient,,,) = abi.decode(data[4:], (address, address, uint24, address, uint256, uint256, uint160));
        } else if (selector == EXACT_INPUT_SELECTOR || selector == EXACT_OUTPUT_SELECTOR) {
            // V1 Multi: (path, recipient, deadline, amountIn, amountOutMin)
            (, recipient,,,) = abi.decode(data[4:], (bytes, address, uint256, uint256, uint256));
        } else if (selector == EXACT_INPUT_02_SELECTOR || selector == EXACT_OUTPUT_02_SELECTOR) {
            // V2 Multi (no deadline): (path, recipient, amountIn, amountOutMin)
            (, recipient,,) = abi.decode(data[4:], (bytes, address, uint256, uint256));
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == EXACT_INPUT_SINGLE_SELECTOR ||
               selector == EXACT_INPUT_SELECTOR ||
               selector == EXACT_OUTPUT_SINGLE_SELECTOR ||
               selector == EXACT_OUTPUT_SELECTOR ||
               selector == EXACT_INPUT_SINGLE_02_SELECTOR ||
               selector == EXACT_INPUT_02_SELECTOR ||
               selector == EXACT_OUTPUT_SINGLE_02_SELECTOR ||
               selector == EXACT_OUTPUT_02_SELECTOR;
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
            selector == EXACT_OUTPUT_SELECTOR ||
            selector == EXACT_INPUT_SINGLE_02_SELECTOR ||
            selector == EXACT_INPUT_02_SELECTOR ||
            selector == EXACT_OUTPUT_SINGLE_02_SELECTOR ||
            selector == EXACT_OUTPUT_02_SELECTOR) {
            return 1; // SWAP
        }
        return 0; // UNKNOWN
    }
}
