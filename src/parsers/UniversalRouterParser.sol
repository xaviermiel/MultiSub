// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title UniversalRouterParser
 * @notice Calldata parser for Uniswap Universal Router operations
 * @dev Extracts token/amount from Universal Router's execute(bytes,bytes[],uint256) calldata
 *
 *      Universal Router uses command-based encoding:
 *      - commands: bytes where each byte is a command type
 *      - inputs: bytes[] where each element is the encoded params for the command
 *
 *      Common commands:
 *      - 0x00: V3_SWAP_EXACT_IN
 *      - 0x01: V3_SWAP_EXACT_OUT
 *      - 0x08: V2_SWAP_EXACT_IN
 *      - 0x09: V2_SWAP_EXACT_OUT
 *      - 0x0b: WRAP_ETH
 *      - 0x0c: UNWRAP_WETH
 */
contract UniversalRouterParser is ICalldataParser {
    error UnsupportedSelector();

    // Universal Router function selector
    bytes4 public constant EXECUTE_SELECTOR = 0x3593564c; // execute(bytes,bytes[],uint256)

    // Command types
    uint8 public constant V3_SWAP_EXACT_IN = 0x00;
    uint8 public constant V3_SWAP_EXACT_OUT = 0x01;
    uint8 public constant V2_SWAP_EXACT_IN = 0x08;
    uint8 public constant V2_SWAP_EXACT_OUT = 0x09;
    uint8 public constant WRAP_ETH = 0x0b;
    uint8 public constant UNWRAP_WETH = 0x0c;

    // WETH address on Sepolia (also used to represent native ETH in paths)
    address public constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    /// @inheritdoc ICalldataParser
    function extractInputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != EXECUTE_SELECTOR) revert UnsupportedSelector();

        // Decode execute(bytes commands, bytes[] inputs, uint256 deadline)
        (bytes memory commands, bytes[] memory inputs,) = abi.decode(data[4:], (bytes, bytes[], uint256));
        address token;

        // Find first swap command to get input token
        for (uint256 i = 0; i < commands.length && i < inputs.length; i++) {
            uint8 command = uint8(commands[i]) & 0x3f; // Mask off flag bits

            if (command == WRAP_ETH) {
                // WRAP_ETH means ETH is input - return address(0) for native ETH
                tokens = new address[](1);
                tokens[0] = address(0);
                return tokens;
            } else if (command == V3_SWAP_EXACT_IN || command == V3_SWAP_EXACT_OUT) {
                // V3 swap params: (address recipient, uint256 amountIn, uint256 amountOutMin, bytes path, bool payerIsUser)
                // First token is at start of path
                bytes memory swapInput = inputs[i];
                if (swapInput.length >= 128) { // Need at least recipient + amounts + path offset
                    // Path is at a dynamic offset, need to decode
                    (, , , bytes memory path, ) = abi.decode(swapInput, (address, uint256, uint256, bytes, bool));
                    if (path.length >= 20) {
                        // First 20 bytes of path is tokenIn for EXACT_IN
                        // For EXACT_OUT, path is reversed so first is tokenOut
                        if (command == V3_SWAP_EXACT_IN) {
                            assembly {
                                token := shr(96, mload(add(path, 32)))
                            }
                        } else {
                            // EXACT_OUT: last 20 bytes is tokenIn
                            assembly {
                                token := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
                            }
                        }
                        tokens = new address[](1);
                        tokens[0] = token;
                        return tokens;
                    }
                }
            } else if (command == V2_SWAP_EXACT_IN || command == V2_SWAP_EXACT_OUT) {
                // V2 swap params: (address recipient, uint256 amountIn, uint256 amountOutMin, address[] path, bool payerIsUser)
                bytes memory swapInput = inputs[i];
                if (swapInput.length >= 128) {
                    (, , , address[] memory path, ) = abi.decode(swapInput, (address, uint256, uint256, address[], bool));
                    if (path.length > 0) {
                        tokens = new address[](1);
                        if (command == V2_SWAP_EXACT_IN) {
                            tokens[0] = path[0];
                        } else {
                            tokens[0] = path[path.length - 1];
                        }
                        return tokens;
                    }
                }
            }
        }

        return new address[](0);
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmounts(address, bytes calldata data) external pure override returns (uint256[] memory amounts) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != EXECUTE_SELECTOR) revert UnsupportedSelector();

        (bytes memory commands, bytes[] memory inputs,) = abi.decode(data[4:], (bytes, bytes[], uint256));
        uint256 amount;

        // Find first swap command to get input amount
        for (uint256 i = 0; i < commands.length && i < inputs.length; i++) {
            uint8 command = uint8(commands[i]) & 0x3f;

            if (command == WRAP_ETH) {
                // WRAP_ETH params: (address recipient, uint256 amount)
                bytes memory wrapInput = inputs[i];
                if (wrapInput.length >= 64) {
                    (, amount) = abi.decode(wrapInput, (address, uint256));
                    amounts = new uint256[](1);
                    amounts[0] = amount;
                    return amounts;
                }
            } else if (command == V3_SWAP_EXACT_IN || command == V3_SWAP_EXACT_OUT) {
                bytes memory swapInput = inputs[i];
                if (swapInput.length >= 128) {
                    if (command == V3_SWAP_EXACT_IN) {
                        // amountIn is second param
                        (, amount, , , ) = abi.decode(swapInput, (address, uint256, uint256, bytes, bool));
                    } else {
                        // EXACT_OUT: amountInMax is third param
                        (, , amount, , ) = abi.decode(swapInput, (address, uint256, uint256, bytes, bool));
                    }
                    amounts = new uint256[](1);
                    amounts[0] = amount;
                    return amounts;
                }
            } else if (command == V2_SWAP_EXACT_IN || command == V2_SWAP_EXACT_OUT) {
                bytes memory swapInput = inputs[i];
                if (swapInput.length >= 128) {
                    if (command == V2_SWAP_EXACT_IN) {
                        (, amount, , , ) = abi.decode(swapInput, (address, uint256, uint256, address[], bool));
                    } else {
                        (, , amount, , ) = abi.decode(swapInput, (address, uint256, uint256, address[], bool));
                    }
                    amounts = new uint256[](1);
                    amounts[0] = amount;
                    return amounts;
                }
            }
        }

        return new uint256[](0);
    }

    /// @inheritdoc ICalldataParser
    function extractOutputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != EXECUTE_SELECTOR) revert UnsupportedSelector();

        (bytes memory commands, bytes[] memory inputs,) = abi.decode(data[4:], (bytes, bytes[], uint256));

        // Find last swap/unwrap command to get output token
        for (uint256 i = commands.length; i > 0; i--) {
            uint8 command = uint8(commands[i-1]) & 0x3f;
            address token;

            if (command == UNWRAP_WETH) {
                // Output is native ETH
                tokens = new address[](1);
                tokens[0] = address(0);
                return tokens;
            } else if (command == V3_SWAP_EXACT_IN || command == V3_SWAP_EXACT_OUT) {
                bytes memory swapInput = inputs[i-1];
                if (swapInput.length >= 128) {
                    (, , , bytes memory path, ) = abi.decode(swapInput, (address, uint256, uint256, bytes, bool));
                    if (path.length >= 20) {
                        if (command == V3_SWAP_EXACT_IN) {
                            // Last 20 bytes of path is tokenOut
                            assembly {
                                token := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
                            }
                        } else {
                            // EXACT_OUT: first 20 bytes is tokenOut
                            assembly {
                                token := shr(96, mload(add(path, 32)))
                            }
                        }
                        tokens = new address[](1);
                        tokens[0] = token;
                        return tokens;
                    }
                }
            } else if (command == V2_SWAP_EXACT_IN || command == V2_SWAP_EXACT_OUT) {
                bytes memory swapInput = inputs[i-1];
                if (swapInput.length >= 128) {
                    (, , , address[] memory path, ) = abi.decode(swapInput, (address, uint256, uint256, address[], bool));
                    if (path.length > 0) {
                        tokens = new address[](1);
                        if (command == V2_SWAP_EXACT_IN) {
                            tokens[0] = path[path.length - 1];
                        } else {
                            tokens[0] = path[0];
                        }
                        return tokens;
                    }
                }
            }
        }

        return new address[](0);
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address defaultRecipient) external pure override returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != EXECUTE_SELECTOR) revert UnsupportedSelector();

        (bytes memory commands, bytes[] memory inputs,) = abi.decode(data[4:], (bytes, bytes[], uint256));

        // Find first swap or wrap/unwrap command to get recipient
        for (uint256 i = 0; i < commands.length && i < inputs.length; i++) {
            uint8 command = uint8(commands[i]) & 0x3f; // Mask off flag bits

            if (command == WRAP_ETH) {
                // WRAP_ETH params: (address recipient, uint256 amount)
                bytes memory wrapInput = inputs[i];
                if (wrapInput.length >= 64) {
                    (recipient,) = abi.decode(wrapInput, (address, uint256));
                    return recipient;
                }
            } else if (command == UNWRAP_WETH) {
                // UNWRAP_WETH params: (address recipient, uint256 amountMin)
                bytes memory unwrapInput = inputs[i];
                if (unwrapInput.length >= 64) {
                    (recipient,) = abi.decode(unwrapInput, (address, uint256));
                    return recipient;
                }
            } else if (command == V3_SWAP_EXACT_IN || command == V3_SWAP_EXACT_OUT ||
                       command == V2_SWAP_EXACT_IN || command == V2_SWAP_EXACT_OUT) {
                // V3/V2 swap params: (address recipient, uint256 amountIn, uint256 amountOutMin, ...)
                bytes memory swapInput = inputs[i];
                if (swapInput.length >= 32) {
                    recipient = abi.decode(swapInput, (address));
                    return recipient;
                }
            }
        }

        // No explicit recipient found, use default (Safe address)
        return defaultRecipient;
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == EXECUTE_SELECTOR;
    }

    /**
     * @notice Get the operation type - always SWAP for Universal Router
     * @param data The calldata (unused - Universal Router is always SWAP)
     * @return opType 1=SWAP
     */
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        return 1; // SWAP
    }
}
