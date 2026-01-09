// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title ParaswapParser
 * @notice Calldata parser for Paraswap AugustusSwapper V6 swap operations
 * @dev Extracts token/amount from Paraswap swap function calldata
 *
 *      Supported contract:
 *      - AugustusSwapper V6 (0x6A000F20005980200259B80c5102003040001068)
 *      - AugustusSwapper V5 (0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57)
 *
 *      Supported functions:
 *      - swapExactAmountIn: Standard exact input swap
 *      - swapExactAmountOut: Exact output swap
 *      - swapExactAmountInOnUniswapV2: Optimized Uniswap V2 swap
 *      - swapExactAmountInOnUniswapV3: Optimized Uniswap V3 swap
 */
contract ParaswapParser is ICalldataParser {
    error UnsupportedSelector();
    error InvalidCalldata();

    // Minimum calldata lengths for bounds checking
    // SWAP_EXACT_AMOUNT_IN/OUT: selector(4) + executor(32) + swapDataOffset(32) + SwapData(224 min) = 292
    uint256 private constant MIN_SWAP_EXACT_LENGTH = 292;
    // SWAP_EXACT_IN_UNISWAP_V2/V3: selector(4) + swapDataOffset(32) + SwapData(224 min) = 260
    uint256 private constant MIN_UNISWAP_SWAP_LENGTH = 260;
    // SIMPLE_SWAP: selector(4) + dataOffset(32) + SimpleData(320 min for beneficiary at 288) = 356
    uint256 private constant MIN_SIMPLE_SWAP_LENGTH = 356;
    // MULTI_SWAP/MEGA_SWAP: selector(4) + dataOffset(32) + data(160 min for beneficiary at 128) = 196
    uint256 private constant MIN_MULTI_SWAP_LENGTH = 196;

    // Address mask for cleaning upper bits (addresses are 160 bits)
    uint256 private constant ADDRESS_MASK = 0x00ffffffffffffffffffffffffffffffffffffffff;

    // ============ AugustusSwapper V6 Selectors ============

    // swapExactAmountIn(address executor, SwapData swapData, PartnerAndFee partnerAndFee, bytes permit, bytes executorData)
    // SwapData: (address srcToken, address destToken, uint256 fromAmount, uint256 toAmount, uint256 quotedAmount, bytes32 metadata, address beneficiary)
    bytes4 public constant SWAP_EXACT_AMOUNT_IN_SELECTOR = 0xe3ead59e;

    // swapExactAmountOut(address executor, SwapData swapData, PartnerAndFee partnerAndFee, bytes permit, bytes executorData)
    bytes4 public constant SWAP_EXACT_AMOUNT_OUT_SELECTOR = 0x4c1ca4e9;

    // swapExactAmountInOnUniswapV2(SwapData swapData, uint256 partnerAndFee, uint256 permit, bytes pools)
    bytes4 public constant SWAP_EXACT_IN_UNISWAP_V2_SELECTOR = 0x54840d1a;

    // swapExactAmountInOnUniswapV3(SwapData swapData, uint256 partnerAndFee, uint256 permit, bytes pools)
    bytes4 public constant SWAP_EXACT_IN_UNISWAP_V3_SELECTOR = 0x876a02f6;

    // ============ AugustusSwapper V5 Selectors (legacy) ============

    // simpleSwap(SimpleData data)
    // SimpleData: (address fromToken, address toToken, uint256 fromAmount, uint256 toAmount, uint256 expectedAmount, address[] callees, bytes exchangeData, uint256[] startIndexes, uint256[] values, address beneficiary, address partner, uint256 feePercent, bytes permit, uint256 deadline, bytes16 uuid)
    bytes4 public constant SIMPLE_SWAP_SELECTOR = 0x54e3f31b;

    // multiSwap(MultiSwapData data)
    bytes4 public constant MULTI_SWAP_SELECTOR = 0xa94e78ef;

    // megaSwap(MegaSwapData data)
    bytes4 public constant MEGA_SWAP_SELECTOR = 0x46c67b6d;

    /// @inheritdoc ICalldataParser
    function extractInputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);
        address token;

        if (selector == SWAP_EXACT_AMOUNT_IN_SELECTOR || selector == SWAP_EXACT_AMOUNT_OUT_SELECTOR) {
            // Bounds check
            if (data.length < MIN_SWAP_EXACT_LENGTH) revert InvalidCalldata();
            // swapExactAmountIn/Out(address executor, SwapData swapData, ...)
            // SwapData starts at second parameter (after executor)
            assembly {
                // Skip selector (4) + executor (32) = 36
                // swapData offset is at position 36
                let swapDataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 36)))
                // srcToken is first field of SwapData - mask to 160 bits
                token := and(calldataload(swapDataOffset), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == SWAP_EXACT_IN_UNISWAP_V2_SELECTOR || selector == SWAP_EXACT_IN_UNISWAP_V3_SELECTOR) {
            // Bounds check
            if (data.length < MIN_UNISWAP_SWAP_LENGTH) revert InvalidCalldata();
            // swapExactAmountInOnUniswapV2/V3(SwapData swapData, ...)
            assembly {
                // SwapData offset is first parameter
                let swapDataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // srcToken is first field - mask to 160 bits
                token := and(calldataload(swapDataOffset), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == SIMPLE_SWAP_SELECTOR) {
            // Bounds check
            if (data.length < MIN_SIMPLE_SWAP_LENGTH) revert InvalidCalldata();
            // simpleSwap(SimpleData data) - fromToken is first field
            assembly {
                // SimpleData offset
                let dataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // fromToken is first field - mask to 160 bits
                token := and(calldataload(dataOffset), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == MULTI_SWAP_SELECTOR) {
            // Bounds check
            if (data.length < MIN_MULTI_SWAP_LENGTH) revert InvalidCalldata();
            // multiSwap - fromToken in path[0].from
            assembly {
                let dataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // fromToken is first field - mask to 160 bits
                token := and(calldataload(dataOffset), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == MEGA_SWAP_SELECTOR) {
            // Bounds check
            if (data.length < MIN_MULTI_SWAP_LENGTH) revert InvalidCalldata();
            // megaSwap - fromToken in path[0][0].from
            assembly {
                let dataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // fromToken is first field - mask to 160 bits
                token := and(calldataload(dataOffset), ADDRESS_MASK)
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

        if (selector == SWAP_EXACT_AMOUNT_IN_SELECTOR || selector == SWAP_EXACT_AMOUNT_OUT_SELECTOR) {
            // Bounds check
            if (data.length < MIN_SWAP_EXACT_LENGTH) revert InvalidCalldata();
            // SwapData.fromAmount is 3rd field (offset 64)
            assembly {
                let swapDataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 36)))
                amount := calldataload(add(swapDataOffset, 64))
            }
            amounts = new uint256[](1);
            amounts[0] = amount;
            return amounts;
        } else if (selector == SWAP_EXACT_IN_UNISWAP_V2_SELECTOR || selector == SWAP_EXACT_IN_UNISWAP_V3_SELECTOR) {
            // Bounds check
            if (data.length < MIN_UNISWAP_SWAP_LENGTH) revert InvalidCalldata();
            // SwapData.fromAmount is 3rd field
            assembly {
                let swapDataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                amount := calldataload(add(swapDataOffset, 64))
            }
            amounts = new uint256[](1);
            amounts[0] = amount;
            return amounts;
        } else if (selector == SIMPLE_SWAP_SELECTOR) {
            // Bounds check
            if (data.length < MIN_SIMPLE_SWAP_LENGTH) revert InvalidCalldata();
            // SimpleData.fromAmount is 3rd field
            assembly {
                let dataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                amount := calldataload(add(dataOffset, 64))
            }
            amounts = new uint256[](1);
            amounts[0] = amount;
            return amounts;
        } else if (selector == MULTI_SWAP_SELECTOR || selector == MEGA_SWAP_SELECTOR) {
            // Bounds check
            if (data.length < MIN_MULTI_SWAP_LENGTH) revert InvalidCalldata();
            // fromAmount is 3rd field
            assembly {
                let dataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                amount := calldataload(add(dataOffset, 64))
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

        if (selector == SWAP_EXACT_AMOUNT_IN_SELECTOR || selector == SWAP_EXACT_AMOUNT_OUT_SELECTOR) {
            // Bounds check
            if (data.length < MIN_SWAP_EXACT_LENGTH) revert InvalidCalldata();
            // SwapData.destToken is 2nd field (offset 32)
            assembly {
                let swapDataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 36)))
                // destToken is 2nd field - mask to 160 bits
                token := and(calldataload(add(swapDataOffset, 32)), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == SWAP_EXACT_IN_UNISWAP_V2_SELECTOR || selector == SWAP_EXACT_IN_UNISWAP_V3_SELECTOR) {
            // Bounds check
            if (data.length < MIN_UNISWAP_SWAP_LENGTH) revert InvalidCalldata();
            // SwapData.destToken is 2nd field
            assembly {
                let swapDataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // destToken is 2nd field - mask to 160 bits
                token := and(calldataload(add(swapDataOffset, 32)), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == SIMPLE_SWAP_SELECTOR) {
            // Bounds check
            if (data.length < MIN_SIMPLE_SWAP_LENGTH) revert InvalidCalldata();
            // SimpleData.toToken is 2nd field
            assembly {
                let dataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // toToken is 2nd field - mask to 160 bits
                token := and(calldataload(add(dataOffset, 32)), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == MULTI_SWAP_SELECTOR || selector == MEGA_SWAP_SELECTOR) {
            // Bounds check
            if (data.length < MIN_MULTI_SWAP_LENGTH) revert InvalidCalldata();
            // toToken is 2nd field
            assembly {
                let dataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // toToken is 2nd field - mask to 160 bits
                token := and(calldataload(add(dataOffset, 32)), ADDRESS_MASK)
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

        if (selector == SWAP_EXACT_AMOUNT_IN_SELECTOR || selector == SWAP_EXACT_AMOUNT_OUT_SELECTOR) {
            // Bounds check
            if (data.length < MIN_SWAP_EXACT_LENGTH) revert InvalidCalldata();
            // SwapData.beneficiary is 7th field (offset 192)
            assembly {
                let swapDataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 36)))
                // beneficiary is 7th field - mask to 160 bits
                recipient := and(calldataload(add(swapDataOffset, 192)), ADDRESS_MASK)
            }
            if (recipient == address(0)) {
                recipient = defaultRecipient;
            }
        } else if (selector == SWAP_EXACT_IN_UNISWAP_V2_SELECTOR || selector == SWAP_EXACT_IN_UNISWAP_V3_SELECTOR) {
            // Bounds check
            if (data.length < MIN_UNISWAP_SWAP_LENGTH) revert InvalidCalldata();
            // SwapData.beneficiary is 7th field
            assembly {
                let swapDataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // beneficiary is 7th field - mask to 160 bits
                recipient := and(calldataload(add(swapDataOffset, 192)), ADDRESS_MASK)
            }
            if (recipient == address(0)) {
                recipient = defaultRecipient;
            }
        } else if (selector == SIMPLE_SWAP_SELECTOR) {
            // Bounds check
            if (data.length < MIN_SIMPLE_SWAP_LENGTH) revert InvalidCalldata();
            // SimpleData.beneficiary is 10th field (offset 288)
            assembly {
                let dataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // beneficiary is 10th field - mask to 160 bits
                recipient := and(calldataload(add(dataOffset, 288)), ADDRESS_MASK)
            }
            if (recipient == address(0)) {
                recipient = defaultRecipient;
            }
        } else if (selector == MULTI_SWAP_SELECTOR || selector == MEGA_SWAP_SELECTOR) {
            // Bounds check
            if (data.length < MIN_MULTI_SWAP_LENGTH) revert InvalidCalldata();
            // MultiSwapData/MegaSwapData.beneficiary is 5th field (offset 128)
            // Struct: (fromToken, fromAmount, toAmount, expectedAmount, beneficiary, ...)
            assembly {
                let dataOffset := add(add(data.offset, 4), calldataload(add(data.offset, 4)))
                // beneficiary is 5th field - mask to 160 bits
                recipient := and(calldataload(add(dataOffset, 128)), ADDRESS_MASK)
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
        return selector == SWAP_EXACT_AMOUNT_IN_SELECTOR ||
               selector == SWAP_EXACT_AMOUNT_OUT_SELECTOR ||
               selector == SWAP_EXACT_IN_UNISWAP_V2_SELECTOR ||
               selector == SWAP_EXACT_IN_UNISWAP_V3_SELECTOR ||
               selector == SIMPLE_SWAP_SELECTOR ||
               selector == MULTI_SWAP_SELECTOR ||
               selector == MEGA_SWAP_SELECTOR;
    }

    /// @inheritdoc ICalldataParser
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);

        // All Paraswap functions are swaps
        if (selector == SWAP_EXACT_AMOUNT_IN_SELECTOR ||
            selector == SWAP_EXACT_AMOUNT_OUT_SELECTOR ||
            selector == SWAP_EXACT_IN_UNISWAP_V2_SELECTOR ||
            selector == SWAP_EXACT_IN_UNISWAP_V3_SELECTOR ||
            selector == SIMPLE_SWAP_SELECTOR ||
            selector == MULTI_SWAP_SELECTOR ||
            selector == MEGA_SWAP_SELECTOR) {
            return 1; // SWAP
        }

        return 0; // UNKNOWN
    }
}
