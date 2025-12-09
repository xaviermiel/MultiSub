// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title UniswapV4Parser
 * @notice Calldata parser for Uniswap V4 PositionManager operations
 * @dev Extracts token/amount from modifyLiquidities calldata
 *
 *      V4 uses a single entry point (modifyLiquidities) with encoded actions:
 *      - INCREASE_LIQUIDITY = 0x00 (add to position)
 *      - DECREASE_LIQUIDITY = 0x01 (remove from position)
 *      - MINT_POSITION = 0x02 (create new position)
 *      - BURN_POSITION = 0x03 (destroy position)
 *      - SETTLE = 0x0b (pay tokens)
 *      - TAKE = 0x0e (receive tokens)
 *      - SETTLE_PAIR = 0x0d (pay both tokens)
 *      - TAKE_PAIR = 0x11 (receive both tokens)
 */
contract UniswapV4Parser is ICalldataParser {
    error UnsupportedSelector();

    // Uniswap V4 PositionManager selector
    bytes4 public constant MODIFY_LIQUIDITIES_SELECTOR = 0xdd46508f; // modifyLiquidities(bytes,uint256)

    // V4 Action types
    uint8 public constant INCREASE_LIQUIDITY = 0x00;
    uint8 public constant DECREASE_LIQUIDITY = 0x01;
    uint8 public constant MINT_POSITION = 0x02;
    uint8 public constant BURN_POSITION = 0x03;
    uint8 public constant INCREASE_LIQUIDITY_FROM_DELTAS = 0x04;
    uint8 public constant MINT_POSITION_FROM_DELTAS = 0x05;
    uint8 public constant SETTLE = 0x0b;
    uint8 public constant SETTLE_ALL = 0x0c;
    uint8 public constant SETTLE_PAIR = 0x0d;
    uint8 public constant TAKE = 0x0e;
    uint8 public constant TAKE_ALL = 0x0f;
    uint8 public constant TAKE_PORTION = 0x10;
    uint8 public constant TAKE_PAIR = 0x11;
    uint8 public constant SWEEP = 0x14;

    /// @inheritdoc ICalldataParser
    function extractInputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != MODIFY_LIQUIDITIES_SELECTOR) revert UnsupportedSelector();

        // Decode modifyLiquidities(bytes unlockData, uint256 deadline)
        (bytes memory unlockData,) = abi.decode(data[4:], (bytes, uint256));

        // Find SETTLE or SETTLE_PAIR action to get input token
        (bytes memory actions, bytes[] memory params) = _decodeActionsAndParams(unlockData);

        for (uint256 i = 0; i < actions.length; i++) {
            uint8 action = uint8(actions[i]);

            if (action == SETTLE || action == SETTLE_ALL) {
                // SETTLE params: (Currency currency, uint256 amount, bool payerIsUser)
                // Currency is first 20 bytes (address)
                if (params[i].length >= 32) {
                    token = _readAddress(params[i], 0);
                    return token;
                }
            } else if (action == SETTLE_PAIR) {
                // SETTLE_PAIR params: (Currency currency0, Currency currency1)
                // Return first currency as input token
                if (params[i].length >= 32) {
                    token = _readAddress(params[i], 0);
                    return token;
                }
            } else if (action == MINT_POSITION || action == MINT_POSITION_FROM_DELTAS) {
                // MINT params include PoolKey which has currency0 and currency1
                // PoolKey: (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks)
                if (params[i].length >= 64) {
                    // currency0 is at offset 0
                    token = _readAddress(params[i], 0);
                    return token;
                }
            }
        }

        return address(0);
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmount(address, bytes calldata data) external pure override returns (uint256 amount) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != MODIFY_LIQUIDITIES_SELECTOR) revert UnsupportedSelector();

        (bytes memory unlockData,) = abi.decode(data[4:], (bytes, uint256));
        (bytes memory actions, bytes[] memory params) = _decodeActionsAndParams(unlockData);

        // Sum up all SETTLE amounts
        for (uint256 i = 0; i < actions.length; i++) {
            uint8 action = uint8(actions[i]);

            if (action == SETTLE) {
                // SETTLE params: (Currency currency, uint256 amount, bool payerIsUser)
                if (params[i].length >= 64) {
                    uint256 settleAmount = _readUint256(params[i], 32);
                    amount += settleAmount;
                }
            } else if (action == SETTLE_ALL) {
                // SETTLE_ALL: (Currency currency, uint256 maxAmount)
                if (params[i].length >= 64) {
                    uint256 maxAmount = _readUint256(params[i], 32);
                    amount += maxAmount;
                }
            }
        }

        return amount;
    }

    /// @inheritdoc ICalldataParser
    function extractOutputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != MODIFY_LIQUIDITIES_SELECTOR) revert UnsupportedSelector();

        (bytes memory unlockData,) = abi.decode(data[4:], (bytes, uint256));
        (bytes memory actions, bytes[] memory params) = _decodeActionsAndParams(unlockData);

        // Find TAKE, TAKE_PAIR, or SWEEP action to get output token
        for (uint256 i = 0; i < actions.length; i++) {
            uint8 action = uint8(actions[i]);

            if (action == TAKE || action == TAKE_ALL || action == TAKE_PORTION) {
                // TAKE params: (Currency currency, address recipient, uint256 amount)
                if (params[i].length >= 32) {
                    token = _readAddress(params[i], 0);
                    return token;
                }
            } else if (action == TAKE_PAIR) {
                // TAKE_PAIR params: (Currency currency0, Currency currency1, address recipient)
                if (params[i].length >= 32) {
                    token = _readAddress(params[i], 0);
                    return token;
                }
            } else if (action == SWEEP) {
                // SWEEP params: (Currency currency, address recipient)
                if (params[i].length >= 32) {
                    token = _readAddress(params[i], 0);
                    return token;
                }
            } else if (action == DECREASE_LIQUIDITY || action == BURN_POSITION) {
                // These return tokens - output tracked via balance change
                // Return address(0) to signal balance-based tracking
                return address(0);
            }
        }

        return address(0);
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == MODIFY_LIQUIDITIES_SELECTOR;
    }

    /**
     * @notice Get the primary operation type from the encoded actions
     * @param data The full calldata
     * @return opType 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     */
    function getOperationType(bytes calldata data) external pure returns (uint8 opType) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != MODIFY_LIQUIDITIES_SELECTOR) return 0;

        (bytes memory unlockData,) = abi.decode(data[4:], (bytes, uint256));
        (bytes memory actions,) = _decodeActionsAndParams(unlockData);

        // Check first liquidity action to determine operation type
        for (uint256 i = 0; i < actions.length; i++) {
            uint8 action = uint8(actions[i]);

            // Deposit operations (adding liquidity)
            if (action == MINT_POSITION ||
                action == MINT_POSITION_FROM_DELTAS ||
                action == INCREASE_LIQUIDITY ||
                action == INCREASE_LIQUIDITY_FROM_DELTAS) {
                return 2; // DEPOSIT
            }

            // Withdraw operations (removing liquidity)
            if (action == BURN_POSITION || action == DECREASE_LIQUIDITY) {
                return 3; // WITHDRAW
            }
        }

        return 0; // UNKNOWN
    }

    /**
     * @notice Decode the actions and params arrays from unlockData
     * @dev V4 encoding:
     *      - bytes[0:32] = offset to actions (0x40)
     *      - bytes[32:64] = offset to params
     *      - bytes[64:64+actionsLen] = actions byte array
     *      - Rest = params array (array of bytes)
     */
    function _decodeActionsAndParams(bytes memory unlockData)
        internal
        pure
        returns (bytes memory actions, bytes[] memory params)
    {
        if (unlockData.length < 64) {
            return (actions, params);
        }

        // The structure is: abi.encode(bytes actions, bytes[] params)
        // But V4 uses a custom tight encoding, not standard ABI

        // Read offset to actions (should be 0x40 = 64)
        uint256 actionsOffset;
        uint256 paramsOffset;

        assembly {
            actionsOffset := mload(add(unlockData, 32))
            paramsOffset := mload(add(unlockData, 64))
        }

        // Read actions length and data
        uint256 actionsLen;
        assembly {
            actionsLen := mload(add(unlockData, add(32, actionsOffset)))
        }

        if (actionsLen == 0 || actionsOffset + 32 + actionsLen > unlockData.length) {
            return (actions, params);
        }

        // Copy actions bytes
        actions = new bytes(actionsLen);
        for (uint256 i = 0; i < actionsLen; i++) {
            actions[i] = unlockData[actionsOffset + 32 + i];
        }

        // Read params array
        uint256 paramsLen;
        assembly {
            paramsLen := mload(add(unlockData, add(32, paramsOffset)))
        }

        params = new bytes[](paramsLen);

        // Each param is a dynamic bytes with its own offset
        uint256 paramsDataStart = paramsOffset + 32;

        for (uint256 i = 0; i < paramsLen && i < actionsLen; i++) {
            // Read offset to this param's data
            uint256 paramOffset;
            assembly {
                paramOffset := mload(add(unlockData, add(32, add(paramsDataStart, mul(i, 32)))))
            }

            // Read param length
            uint256 paramLen;
            uint256 absoluteParamOffset = paramsDataStart + paramOffset;

            if (absoluteParamOffset + 32 <= unlockData.length) {
                assembly {
                    paramLen := mload(add(unlockData, add(32, absoluteParamOffset)))
                }

                // Copy param data
                if (absoluteParamOffset + 32 + paramLen <= unlockData.length) {
                    params[i] = new bytes(paramLen);
                    for (uint256 j = 0; j < paramLen; j++) {
                        params[i][j] = unlockData[absoluteParamOffset + 32 + j];
                    }
                }
            }
        }

        return (actions, params);
    }

    /**
     * @notice Read an address from a memory bytes array at a given offset
     * @param data The bytes array
     * @param offset The offset in bytes (must be word-aligned for addresses)
     */
    function _readAddress(bytes memory data, uint256 offset) internal pure returns (address result) {
        require(data.length >= offset + 32, "Out of bounds");
        uint256 value;
        assembly {
            value := mload(add(add(data, 32), offset))
        }
        // Address is in the lower 20 bytes
        result = address(uint160(value));
    }

    /**
     * @notice Read a uint256 from a memory bytes array at a given offset
     * @param data The bytes array
     * @param offset The offset in bytes
     */
    function _readUint256(bytes memory data, uint256 offset) internal pure returns (uint256 result) {
        require(data.length >= offset + 32, "Out of bounds");
        assembly {
            result := mload(add(add(data, 32), offset))
        }
    }
}
