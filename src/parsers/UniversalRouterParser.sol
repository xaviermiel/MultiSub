// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title UniversalRouterParser
 * @notice Calldata parser for Uniswap Universal Router operations (V2, V3, and V4)
 * @dev Extracts token/amount from Universal Router's execute(bytes,bytes[],uint256) calldata
 *
 *      Universal Router uses command-based encoding:
 *      - commands: bytes where each byte is a command type
 *      - inputs: bytes[] where each element is the encoded params for the command
 *
 *      Supported commands:
 *      - 0x00: V3_SWAP_EXACT_IN
 *      - 0x01: V3_SWAP_EXACT_OUT
 *      - 0x07: V4_SWAP (alternate, used by some frontends)
 *      - 0x08: V2_SWAP_EXACT_IN
 *      - 0x09: V2_SWAP_EXACT_OUT
 *      - 0x0b: WRAP_ETH
 *      - 0x0c: UNWRAP_WETH
 *      - 0x0e: BALANCE_CHECK_ERC20 (skipped, non-swap)
 *      - 0x10: V4_SWAP
 */
contract UniversalRouterParser is ICalldataParser {
    error UnsupportedSelector();
    error InvalidCalldata();
    error UnsupportedV4ExactOutMultiHop();

    // Universal Router function selector
    bytes4 public constant EXECUTE_SELECTOR = 0x3593564c; // execute(bytes,bytes[],uint256)

    // Command types - V3/V2
    uint8 public constant V3_SWAP_EXACT_IN = 0x00;
    uint8 public constant V3_SWAP_EXACT_OUT = 0x01;
    uint8 public constant SWEEP = 0x04;
    uint8 public constant PAY_PORTION = 0x06;
    uint8 public constant V2_SWAP_EXACT_IN = 0x08;
    uint8 public constant V2_SWAP_EXACT_OUT = 0x09;
    uint8 public constant WRAP_ETH = 0x0b;
    uint8 public constant UNWRAP_WETH = 0x0c;
    uint8 public constant BALANCE_CHECK_ERC20 = 0x0e;

    // Command types - V4
    uint8 public constant V4_SWAP_ALT = 0x07; // Used by some frontends for V4 swaps
    uint8 public constant V4_SWAP = 0x10;

    // V4 Action types (inside V4_SWAP)
    uint8 public constant V4_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 public constant V4_SWAP_EXACT_IN = 0x07;
    uint8 public constant V4_SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 public constant V4_SWAP_EXACT_OUT = 0x09;

    // Universal Router special address constants (resolved at runtime)
    address public constant MSG_SENDER = address(1);
    address public constant ADDRESS_THIS = address(2);

    /// @inheritdoc ICalldataParser
    function extractInputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        if (data.length < 4) revert InvalidCalldata();
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
                if (swapInput.length >= 128) {
                    // Need at least recipient + amounts + path offset
                    // Path is at a dynamic offset, need to decode
                    (,,, bytes memory path,) = abi.decode(swapInput, (address, uint256, uint256, bytes, bool));
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
                    (,,, address[] memory path,) = abi.decode(swapInput, (address, uint256, uint256, address[], bool));
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
            } else if (command == V4_SWAP || command == V4_SWAP_ALT) {
                // V4_SWAP params: (bytes actions, bytes[] params)
                // Note: Some frontends use 0x07 for V4 swaps instead of 0x10
                bool found;
                (token, found) = _extractV4InputToken(inputs[i]);
                if (found) {
                    tokens = new address[](1);
                    tokens[0] = token; // address(0) = native ETH in V4
                    return tokens;
                }
            }
            // Skip BALANCE_CHECK_ERC20 and other non-swap commands
        }

        return new address[](0);
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmounts(address, bytes calldata data)
        external
        pure
        override
        returns (uint256[] memory amounts)
    {
        if (data.length < 4) revert InvalidCalldata();
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
                        (, amount,,,) = abi.decode(swapInput, (address, uint256, uint256, bytes, bool));
                    } else {
                        // EXACT_OUT: amountInMax is third param
                        (,, amount,,) = abi.decode(swapInput, (address, uint256, uint256, bytes, bool));
                    }
                    amounts = new uint256[](1);
                    amounts[0] = amount;
                    return amounts;
                }
            } else if (command == V2_SWAP_EXACT_IN || command == V2_SWAP_EXACT_OUT) {
                bytes memory swapInput = inputs[i];
                if (swapInput.length >= 128) {
                    if (command == V2_SWAP_EXACT_IN) {
                        (, amount,,,) = abi.decode(swapInput, (address, uint256, uint256, address[], bool));
                    } else {
                        (,, amount,,) = abi.decode(swapInput, (address, uint256, uint256, address[], bool));
                    }
                    amounts = new uint256[](1);
                    amounts[0] = amount;
                    return amounts;
                }
            } else if (command == V4_SWAP || command == V4_SWAP_ALT) {
                // V4_SWAP params: (bytes actions, bytes[] params)
                amount = _extractV4InputAmount(inputs[i]);
                if (amount > 0) {
                    amounts = new uint256[](1);
                    amounts[0] = amount;
                    return amounts;
                }
            }
            // Skip BALANCE_CHECK_ERC20 and other non-swap commands
        }

        return new uint256[](0);
    }

    /// @inheritdoc ICalldataParser
    function extractOutputTokens(address, bytes calldata data)
        external
        pure
        override
        returns (address[] memory tokens)
    {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);
        if (selector != EXECUTE_SELECTOR) revert UnsupportedSelector();

        (bytes memory commands, bytes[] memory inputs,) = abi.decode(data[4:], (bytes, bytes[], uint256));

        // Find last swap/unwrap command to get output token
        for (uint256 i = commands.length; i > 0; i--) {
            uint8 command = uint8(commands[i - 1]) & 0x3f;
            address token;

            if (command == UNWRAP_WETH) {
                // Output is native ETH
                tokens = new address[](1);
                tokens[0] = address(0);
                return tokens;
            } else if (command == V3_SWAP_EXACT_IN || command == V3_SWAP_EXACT_OUT) {
                bytes memory swapInput = inputs[i - 1];
                if (swapInput.length >= 128) {
                    (,,, bytes memory path,) = abi.decode(swapInput, (address, uint256, uint256, bytes, bool));
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
                bytes memory swapInput = inputs[i - 1];
                if (swapInput.length >= 128) {
                    (,,, address[] memory path,) = abi.decode(swapInput, (address, uint256, uint256, address[], bool));
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
            } else if (command == V4_SWAP || command == V4_SWAP_ALT) {
                // V4_SWAP params: (bytes actions, bytes[] params)
                bool found;
                (token, found) = _extractV4OutputToken(inputs[i - 1]);
                if (found) {
                    tokens = new address[](1);
                    tokens[0] = token; // address(0) = native ETH in V4
                    return tokens;
                }
            }
            // Skip BALANCE_CHECK_ERC20 and other non-swap commands
        }

        return new address[](0);
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address defaultRecipient)
        external
        pure
        override
        returns (address recipient)
    {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);
        if (selector != EXECUTE_SELECTOR) revert UnsupportedSelector();

        (bytes memory commands, bytes[] memory inputs,) = abi.decode(data[4:], (bytes, bytes[], uint256));

        // Universal Router uses special address constants:
        // - address(1) = MSG_SENDER: resolved to msg.sender at runtime
        // - address(2) = ADDRESS_THIS: resolved to router address at runtime (intermediate)
        //
        // Strategy: Look for final recipient in order of priority:
        // 1. SWEEP command (always sends to final recipient)
        // 2. UNWRAP_WETH (if recipient is not ADDRESS_THIS)
        // 3. Swap commands (if recipient is not ADDRESS_THIS)
        // 4. Default to Safe address

        // First pass: look for SWEEP which always has the final recipient
        for (uint256 i = 0; i < commands.length && i < inputs.length; i++) {
            uint8 command = uint8(commands[i]) & 0x3f;
            if (command == SWEEP) {
                // SWEEP params: (address token, address recipient, uint256 amountMin)
                bytes memory sweepInput = inputs[i];
                if (sweepInput.length >= 64) {
                    (, recipient) = abi.decode(sweepInput, (address, address));
                    return _resolveRecipient(recipient, defaultRecipient);
                }
            }
        }

        // Second pass: look for UNWRAP_WETH or swaps with non-intermediate recipient
        // Track if any command uses ADDRESS_THIS without a final delivery command
        bool sawAddressThis = false;

        for (uint256 i = 0; i < commands.length && i < inputs.length; i++) {
            uint8 command = uint8(commands[i]) & 0x3f;

            if (command == WRAP_ETH) {
                // WRAP_ETH params: (address recipient, uint256 amount)
                bytes memory wrapInput = inputs[i];
                if (wrapInput.length >= 64) {
                    (recipient,) = abi.decode(wrapInput, (address, uint256));
                    if (recipient == ADDRESS_THIS) {
                        sawAddressThis = true;
                    } else {
                        return _resolveRecipient(recipient, defaultRecipient);
                    }
                }
            } else if (command == UNWRAP_WETH) {
                // UNWRAP_WETH params: (address recipient, uint256 amountMin)
                bytes memory unwrapInput = inputs[i];
                if (unwrapInput.length >= 64) {
                    (recipient,) = abi.decode(unwrapInput, (address, uint256));
                    if (recipient == ADDRESS_THIS) {
                        sawAddressThis = true;
                    } else {
                        return _resolveRecipient(recipient, defaultRecipient);
                    }
                }
            } else if (
                command == V3_SWAP_EXACT_IN || command == V3_SWAP_EXACT_OUT || command == V2_SWAP_EXACT_IN
                    || command == V2_SWAP_EXACT_OUT
            ) {
                // V3/V2 swap params: (address recipient, uint256 amountIn, uint256 amountOutMin, ...)
                bytes memory swapInput = inputs[i];
                if (swapInput.length >= 32) {
                    recipient = abi.decode(swapInput, (address));
                    if (recipient == ADDRESS_THIS) {
                        sawAddressThis = true;
                    } else {
                        return _resolveRecipient(recipient, defaultRecipient);
                    }
                }
            }
            // V4_SWAP (0x10) and V4_SWAP_ALT (0x07) recipient is handled via SETTLE/TAKE actions which go to msg.sender
            // Skip BALANCE_CHECK_ERC20 and other non-swap commands
        }

        // If we saw ADDRESS_THIS but no final delivery command (SWEEP/UNWRAP to non-router),
        // return ADDRESS_THIS so the module's recipient != avatar check rejects it.
        // This prevents tokens from getting stuck in the router.
        if (sawAddressThis) {
            return ADDRESS_THIS;
        }

        // No explicit recipient found at all (e.g., V4-only swaps use SETTLE/TAKE),
        // default to Safe address
        return defaultRecipient;
    }

    /// @notice Resolve special Universal Router address constants
    /// @param recipient The recipient address from calldata
    /// @param defaultRecipient The Safe address to use for MSG_SENDER
    /// @return The resolved recipient address
    function _resolveRecipient(address recipient, address defaultRecipient) internal pure returns (address) {
        if (recipient == MSG_SENDER) {
            return defaultRecipient; // MSG_SENDER = Safe address (caller of Universal Router)
        }
        // ADDRESS_THIS is NOT resolved — it means tokens go to the router, not the Safe.
        // Callers filter it out in pass 2. If it reaches here (e.g., from SWEEP), return as-is
        // so the module's recipient != avatar check blocks it.
        return recipient;
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
        if (data.length < 4) revert InvalidCalldata();
        return 1; // SWAP
    }

    // ============ V4 Helper Functions ============

    /**
     * @notice Extract input token from V4_SWAP command
     * @dev V4_SWAP params: (bytes actions, bytes[] params)
     *      Actions contain action types, params contain encoded data for each action
     *      SWAP_EXACT_IN_SINGLE (0x06): (PoolKey, bool zeroForOne, uint128 amountIn, uint128 amountOutMin, bytes hookData)
     *      SWAP_EXACT_IN (0x07): (Currency currencyIn, PathKey[] path, uint128 amountIn, uint128 amountOutMin)
     * @return token The input token address (address(0) = native ETH)
     * @return found Whether a swap action was found
     */
    function _extractV4InputToken(bytes memory v4Input) internal pure returns (address token, bool found) {
        if (v4Input.length < 64) return (address(0), false);

        (bytes memory actions, bytes[] memory params) = abi.decode(v4Input, (bytes, bytes[]));

        for (uint256 i = 0; i < actions.length && i < params.length; i++) {
            uint8 action = uint8(actions[i]);

            if (action == V4_SWAP_EXACT_IN_SINGLE || action == V4_SWAP_EXACT_OUT_SINGLE) {
                // Single pool swap: first param is PoolKey which contains currency0 and currency1
                // PoolKey: (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks)
                // For EXACT_IN_SINGLE: zeroForOne determines direction
                if (params[i].length >= 160) {
                    // Decode PoolKey (first 5 slots) + zeroForOne
                    (address currency0, address currency1,,,, bool zeroForOne) =
                        abi.decode(params[i], (address, address, uint24, int24, address, bool));
                    // zeroForOne=true means swap currency0->currency1, so input is currency0
                    // zeroForOne=false means swap currency1->currency0, so input is currency1
                    if (action == V4_SWAP_EXACT_IN_SINGLE) {
                        return (zeroForOne ? currency0 : currency1, true);
                    } else {
                        // EXACT_OUT: input is opposite
                        return (zeroForOne ? currency1 : currency0, true);
                    }
                }
            } else if (action == V4_SWAP_EXACT_IN) {
                // Multi-hop swap: (Currency currencyIn, PathKey[] path, uint128 amountIn, uint128 amountOutMin)
                // Note: params may be wrapped in a tuple, so first slot could be an offset (0x20)
                if (params[i].length >= 64) {
                    bytes memory paramData = params[i];
                    // Check if first slot is a small offset (indicates wrapped tuple)
                    uint256 firstSlot;
                    assembly {
                        firstSlot := mload(add(paramData, 32))
                    }

                    address currencyIn;
                    if (firstSlot < 256 && firstSlot > 0) {
                        // First slot is an offset, read currencyIn from offset position
                        assembly {
                            currencyIn := mload(add(add(paramData, 32), firstSlot))
                        }
                    } else {
                        // Direct encoding, currencyIn is first slot
                        currencyIn = address(uint160(firstSlot));
                    }
                    return (currencyIn, true);
                }
            } else if (action == V4_SWAP_EXACT_OUT) {
                // Multi-hop exact out requires decoding PathKey[] which contains dynamic data
                // Revert to prevent zero-spending bypass
                revert UnsupportedV4ExactOutMultiHop();
            }
        }

        return (address(0), false);
    }

    /**
     * @notice Extract input amount from V4_SWAP command
     */
    function _extractV4InputAmount(bytes memory v4Input) internal pure returns (uint256 amount) {
        if (v4Input.length < 64) return 0;

        (bytes memory actions, bytes[] memory params) = abi.decode(v4Input, (bytes, bytes[]));

        for (uint256 i = 0; i < actions.length && i < params.length; i++) {
            uint8 action = uint8(actions[i]);

            if (action == V4_SWAP_EXACT_IN_SINGLE) {
                // (PoolKey, bool zeroForOne, uint128 amountIn, uint128 amountOutMin, bytes hookData)
                // PoolKey is 5 slots (160 bytes), then zeroForOne (32 bytes), then amountIn
                if (params[i].length >= 224) {
                    // Skip PoolKey (5 slots) + zeroForOne (1 slot) to get amountIn
                    assembly {
                        // params[i] starts at params[i]+32, PoolKey is 160 bytes, zeroForOne is 32 bytes
                        amount := mload(add(add(params, add(32, mul(i, 32))), 192))
                    }
                    // Decode properly
                    (,,,,,, uint128 amountIn,) =
                        abi.decode(params[i], (address, address, uint24, int24, address, bool, uint128, uint128));
                    return uint256(amountIn);
                }
            } else if (action == V4_SWAP_EXACT_IN) {
                // (Currency currencyIn, PathKey[] path, uint128 amountIn, uint128 amountOutMin)
                // Note: params may be wrapped in a tuple, so first slot could be an offset (0x20)
                if (params[i].length >= 128) {
                    bytes memory paramData = params[i];
                    uint256 firstSlot;
                    assembly {
                        firstSlot := mload(add(paramData, 32))
                    }

                    if (firstSlot < 256 && firstSlot > 0) {
                        // First slot is an offset, amountIn is at offset + 64 (skip currencyIn + path offset)
                        assembly {
                            amount := mload(add(add(paramData, 32), add(firstSlot, 64)))
                        }
                    } else {
                        // Direct encoding: slot 0=currencyIn, slot 1=path offset, slot 2=amountIn
                        assembly {
                            amount := mload(add(paramData, 96)) // slot 2
                        }
                    }
                    return amount;
                }
            } else if (action == V4_SWAP_EXACT_OUT_SINGLE) {
                // (PoolKey, bool zeroForOne, uint128 amountOut, uint128 amountInMax, bytes hookData)
                // For spending limits, use amountInMax (maximum input the user will spend)
                if (params[i].length >= 256) {
                    (,,,,,,, uint128 amountInMax) =
                        abi.decode(params[i], (address, address, uint24, int24, address, bool, uint128, uint128));
                    return uint256(amountInMax);
                }
            } else if (action == V4_SWAP_EXACT_OUT) {
                // Multi-hop exact out requires decoding PathKey[] which contains dynamic data
                // Revert to prevent zero-spending bypass
                revert UnsupportedV4ExactOutMultiHop();
            }
        }

        return 0;
    }

    /**
     * @notice Extract output token from V4_SWAP command
     * @return token The output token address (address(0) = native ETH)
     * @return found Whether a swap action was found
     */
    function _extractV4OutputToken(bytes memory v4Input) internal pure returns (address token, bool found) {
        if (v4Input.length < 64) return (address(0), false);

        (bytes memory actions, bytes[] memory params) = abi.decode(v4Input, (bytes, bytes[]));

        // Look for TAKE action which specifies the output token
        // V4 action 0x0e = TAKE, params: (Currency currency, address recipient, uint256 amount)
        for (uint256 i = 0; i < actions.length && i < params.length; i++) {
            uint8 action = uint8(actions[i]);
            if (action == 0x0e) {
                // TAKE action
                if (params[i].length >= 32) {
                    bytes memory paramData = params[i];
                    address currency;
                    assembly {
                        currency := mload(add(paramData, 32))
                    }
                    return (currency, true);
                }
            }
        }

        // Fallback: look for swap actions in reverse order (last swap determines output)
        for (uint256 i = actions.length; i > 0; i--) {
            uint8 action = uint8(actions[i - 1]);

            if (action == V4_SWAP_EXACT_IN_SINGLE || action == V4_SWAP_EXACT_OUT_SINGLE) {
                if (params[i - 1].length >= 160) {
                    (address currency0, address currency1,,,, bool zeroForOne) =
                        abi.decode(params[i - 1], (address, address, uint24, int24, address, bool));
                    // zeroForOne=true means swap currency0->currency1, so output is currency1
                    if (action == V4_SWAP_EXACT_IN_SINGLE) {
                        return (zeroForOne ? currency1 : currency0, true);
                    } else {
                        // EXACT_OUT: output is opposite
                        return (zeroForOne ? currency0 : currency1, true);
                    }
                }
            }
        }

        return (address(0), false);
    }
}
