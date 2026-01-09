// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title KyberSwapParser
 * @notice Calldata parser for KyberSwap MetaAggregationRouterV2 swap operations
 * @dev Extracts token/amount from KyberSwap swap function calldata
 *
 *      Supported contract:
 *      - MetaAggregationRouterV2 (0x6131B5fae19EA4f9D964eAc0408E4408b66337b5)
 *
 *      Supported functions:
 *      - swap: Generic meta-aggregation swap
 *      - swapSimpleMode: Simplified swap for common cases
 */
contract KyberSwapParser is ICalldataParser {
    error UnsupportedSelector();
    error InvalidCalldata();

    // Minimum calldata lengths for bounds checking
    // SWAP/SWAP_GENERIC: selector(4) + execOffset(32) + execStruct(128 min) + descStruct(256 min) = 420
    uint256 private constant MIN_SWAP_LENGTH = 420;
    // SWAP_SIMPLE_MODE: selector(4) + caller(32) + descOffset(32) + descStruct(256 min) = 324
    uint256 private constant MIN_SWAP_SIMPLE_LENGTH = 324;

    // Address mask for cleaning upper bits (addresses are 160 bits)
    uint256 private constant ADDRESS_MASK = 0x00ffffffffffffffffffffffffffffffffffffffff;

    // ============ KyberSwap MetaAggregationRouterV2 Selectors ============

    // swap(SwapExecutionParams execution)
    // SwapExecutionParams: (address callTarget, address approveTarget, bytes targetData, SwapDescription desc, bytes clientData)
    // SwapDescription struct layout (ABI-encoded head - dynamic types store offset pointers):
    //   Slot 0 (offset 0):   srcToken (address)
    //   Slot 1 (offset 32):  dstToken (address)
    //   Slot 2 (offset 64):  srcReceivers offset (pointer to address[] data)
    //   Slot 3 (offset 96):  srcAmounts offset (pointer to uint256[] data)
    //   Slot 4 (offset 128): feeReceivers offset (pointer to address[] data)
    //   Slot 5 (offset 160): feeAmounts offset (pointer to uint256[] data)
    //   Slot 6 (offset 192): dstReceiver (address)
    //   Slot 7 (offset 224): amount (uint256)
    //   Slot 8 (offset 256): minReturnAmount (uint256)
    //   Slot 9 (offset 288): flags (uint256)
    //   Slot 10 (offset 320): permit offset (pointer to bytes data)
    bytes4 public constant SWAP_SELECTOR = 0xe21fd0e9;

    // swapSimpleMode(address caller, SwapDescription desc, bytes executorData, bytes clientData)
    bytes4 public constant SWAP_SIMPLE_MODE_SELECTOR = 0x8af033fb;

    // swapGeneric(SwapExecutionParams execution)
    bytes4 public constant SWAP_GENERIC_SELECTOR = 0x59e50fed;

    /// @inheritdoc ICalldataParser
    function extractInputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);
        address token;

        if (selector == SWAP_SELECTOR || selector == SWAP_GENERIC_SELECTOR) {
            // Bounds check for SWAP calldata
            if (data.length < MIN_SWAP_LENGTH) revert InvalidCalldata();
            // swap(SwapExecutionParams execution)
            // SwapExecutionParams is a struct with desc at offset 3 (after callTarget, approveTarget, targetData)
            // We need to navigate to SwapDescription.srcToken
            assembly {
                // execution is first param, get its offset
                let execOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // desc offset is 4th field in execution (after callTarget, approveTarget, targetData offset)
                // callTarget: 32, approveTarget: 32, targetData offset: 32, desc offset: at 96
                let descRelOffset := calldataload(add(execOffset, 96))
                let descOffset := add(execOffset, descRelOffset)
                // srcToken is first field of SwapDescription - mask to 160 bits
                token := and(calldataload(descOffset), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == SWAP_SIMPLE_MODE_SELECTOR) {
            // Bounds check for SWAP_SIMPLE_MODE calldata
            if (data.length < MIN_SWAP_SIMPLE_LENGTH) revert InvalidCalldata();
            // swapSimpleMode(address caller, SwapDescription desc, bytes executorData, bytes clientData)
            // desc is second parameter
            assembly {
                // Skip selector (4) + caller (32) = 36
                // desc offset at position 36
                let descOffset := add(add(data.offset, 4), calldataload(add(data.offset, 36)))
                // srcToken is first field - mask to 160 bits
                token := and(calldataload(descOffset), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmounts(address, bytes calldata data) external pure override returns (uint256[] memory amounts) {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);
        uint256 amount;

        if (selector == SWAP_SELECTOR || selector == SWAP_GENERIC_SELECTOR) {
            // Bounds check for SWAP calldata
            if (data.length < MIN_SWAP_LENGTH) revert InvalidCalldata();
            // SwapDescription.amount is at slot 7 (offset 224)
            // Dynamic arrays (srcReceivers, etc.) store offset pointers in the head,
            // so amount remains at a fixed offset regardless of array contents
            assembly {
                let execOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                let descRelOffset := calldataload(add(execOffset, 96))
                let descOffset := add(execOffset, descRelOffset)
                // amount is at slot 7 (offset 224) - see struct layout in SWAP_SELECTOR comment
                amount := calldataload(add(descOffset, 224))
            }
            amounts = new uint256[](1);
            amounts[0] = amount;
            return amounts;
        } else if (selector == SWAP_SIMPLE_MODE_SELECTOR) {
            // Bounds check for SWAP_SIMPLE_MODE calldata
            if (data.length < MIN_SWAP_SIMPLE_LENGTH) revert InvalidCalldata();
            // Same SwapDescription struct layout - amount at slot 7 (offset 224)
            assembly {
                let descOffset := add(add(data.offset, 4), calldataload(add(data.offset, 36)))
                amount := calldataload(add(descOffset, 224))
            }
            amounts = new uint256[](1);
            amounts[0] = amount;
            return amounts;
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractOutputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);
        address token;

        if (selector == SWAP_SELECTOR || selector == SWAP_GENERIC_SELECTOR) {
            // Bounds check for SWAP calldata
            if (data.length < MIN_SWAP_LENGTH) revert InvalidCalldata();
            // SwapDescription.dstToken is 2nd field
            assembly {
                let execOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                let descRelOffset := calldataload(add(execOffset, 96))
                let descOffset := add(execOffset, descRelOffset)
                // dstToken at offset 32 - mask to 160 bits
                token := and(calldataload(add(descOffset, 32)), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == SWAP_SIMPLE_MODE_SELECTOR) {
            // Bounds check for SWAP_SIMPLE_MODE calldata
            if (data.length < MIN_SWAP_SIMPLE_LENGTH) revert InvalidCalldata();
            assembly {
                let descOffset := add(add(data.offset, 4), calldataload(add(data.offset, 36)))
                // dstToken - mask to 160 bits
                token := and(calldataload(add(descOffset, 32)), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address defaultRecipient) external pure override returns (address recipient) {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);

        if (selector == SWAP_SELECTOR || selector == SWAP_GENERIC_SELECTOR) {
            // Bounds check for SWAP calldata
            if (data.length < MIN_SWAP_LENGTH) revert InvalidCalldata();
            // SwapDescription.dstReceiver is at slot 6 (offset 192)
            assembly {
                let execOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                let descRelOffset := calldataload(add(execOffset, 96))
                let descOffset := add(execOffset, descRelOffset)
                // dstReceiver at slot 6 (offset 192) - mask to 160 bits
                recipient := and(calldataload(add(descOffset, 192)), ADDRESS_MASK)
            }
            if (recipient == address(0)) {
                recipient = defaultRecipient;
            }
        } else if (selector == SWAP_SIMPLE_MODE_SELECTOR) {
            // Bounds check for SWAP_SIMPLE_MODE calldata
            if (data.length < MIN_SWAP_SIMPLE_LENGTH) revert InvalidCalldata();
            // Same SwapDescription struct layout - dstReceiver at slot 6 (offset 192)
            assembly {
                let descOffset := add(add(data.offset, 4), calldataload(add(data.offset, 36)))
                recipient := and(calldataload(add(descOffset, 192)), ADDRESS_MASK)
            }
            if (recipient == address(0)) {
                recipient = defaultRecipient;
            }
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == SWAP_SELECTOR ||
               selector == SWAP_SIMPLE_MODE_SELECTOR ||
               selector == SWAP_GENERIC_SELECTOR;
    }

    /// @inheritdoc ICalldataParser
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);

        // All KyberSwap functions are swaps
        if (selector == SWAP_SELECTOR ||
            selector == SWAP_SIMPLE_MODE_SELECTOR ||
            selector == SWAP_GENERIC_SELECTOR) {
            return 1; // SWAP
        }

        return 0; // UNKNOWN
    }
}
