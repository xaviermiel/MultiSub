// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title OneInchParser
 * @notice Calldata parser for 1inch AggregationRouterV6 swap operations
 * @dev Extracts token/amount from 1inch swap function calldata
 *
 *      Supported contract:
 *      - AggregationRouterV6 (0x111111125421cA6dc452d289314280a0f8842A65)
 *
 *      Supported functions:
 *      - swap: Generic swap with executor
 *      - unoswapTo: Optimized single-pool swap
 *      - uniswapV3SwapTo: Optimized Uniswap V3 swap
 */
contract OneInchParser is ICalldataParser {
    error UnsupportedSelector();

    // ============ 1inch AggregationRouterV6 Selectors ============

    // swap(address executor, SwapDescription desc, bytes data, bytes permit)
    // SwapDescription: (address srcToken, address dstToken, address srcReceiver, address dstReceiver, uint256 amount, uint256 minReturnAmount, uint256 flags)
    bytes4 public constant SWAP_SELECTOR = 0x12aa3caf;

    // unoswapTo(address to, address srcToken, uint256 amount, uint256 minReturn, uint256[] pools)
    bytes4 public constant UNOSWAP_TO_SELECTOR = 0xf78dc253;

    // uniswapV3SwapTo(address recipient, uint256 amount, uint256 minReturn, uint256[] pools)
    // Note: srcToken is encoded in the first pool, dstToken in the last pool
    bytes4 public constant UNISWAP_V3_SWAP_TO_SELECTOR = 0xbc80f1a8;

    // clipperSwapTo(address clipperExchange, address recipient, address srcToken, address dstToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, bytes32 r, bytes32 vs)
    bytes4 public constant CLIPPER_SWAP_TO_SELECTOR = 0x093d4fa5;

    /// @inheritdoc ICalldataParser
    function extractInputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);
        address token;

        if (selector == SWAP_SELECTOR) {
            // swap(address executor, SwapDescription desc, bytes data, bytes permit)
            // SwapDescription starts at offset 32 (after executor)
            // srcToken is first field of SwapDescription struct
            assembly {
                // Skip selector (4) + executor (32) = 36
                // First 32 bytes of desc is offset to struct data
                // desc.srcToken is at offset 0 of the struct
                let descOffset := add(add(data.offset, 4), 32) // offset to desc
                let structOffset := add(add(data.offset, 4), calldataload(descOffset))
                token := calldataload(structOffset)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == UNOSWAP_TO_SELECTOR) {
            // unoswapTo(address to, address srcToken, uint256 amount, uint256 minReturn, uint256[] pools)
            (, token,,,) = abi.decode(data[4:], (address, address, uint256, uint256, uint256[]));
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == UNISWAP_V3_SWAP_TO_SELECTOR) {
            // uniswapV3SwapTo(address recipient, uint256 amount, uint256 minReturn, uint256[] pools)
            // srcToken is encoded in the first pool's lower 160 bits
            (,,, uint256[] memory pools) = abi.decode(data[4:], (address, uint256, uint256, uint256[]));
            if (pools.length > 0) {
                // Extract token from first pool (lower 160 bits)
                token = address(uint160(pools[0]));
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == CLIPPER_SWAP_TO_SELECTOR) {
            // clipperSwapTo(address clipperExchange, address recipient, address srcToken, ...)
            (,, token,,,,,,) = abi.decode(data[4:], (address, address, address, address, uint256, uint256, uint256, bytes32, bytes32));
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmounts(address, bytes calldata data) external pure override returns (uint256[] memory amounts) {
        bytes4 selector = bytes4(data[:4]);
        uint256 amount;

        if (selector == SWAP_SELECTOR) {
            // SwapDescription.amount is at offset 4 (5th field: srcToken, dstToken, srcReceiver, dstReceiver, amount)
            assembly {
                let descOffset := add(add(data.offset, 4), 32)
                let structOffset := add(add(data.offset, 4), calldataload(descOffset))
                // amount is 5th field = offset 128 (4 * 32)
                amount := calldataload(add(structOffset, 128))
            }
            amounts = new uint256[](1);
            amounts[0] = amount;
            return amounts;
        } else if (selector == UNOSWAP_TO_SELECTOR) {
            // unoswapTo(address to, address srcToken, uint256 amount, ...)
            (,, amount,,) = abi.decode(data[4:], (address, address, uint256, uint256, uint256[]));
            amounts = new uint256[](1);
            amounts[0] = amount;
            return amounts;
        } else if (selector == UNISWAP_V3_SWAP_TO_SELECTOR) {
            // uniswapV3SwapTo(address recipient, uint256 amount, ...)
            (, amount,,) = abi.decode(data[4:], (address, uint256, uint256, uint256[]));
            amounts = new uint256[](1);
            amounts[0] = amount;
            return amounts;
        } else if (selector == CLIPPER_SWAP_TO_SELECTOR) {
            // clipperSwapTo(..., uint256 inputAmount, ...)
            (,,,, amount,,,,) = abi.decode(data[4:], (address, address, address, address, uint256, uint256, uint256, bytes32, bytes32));
            amounts = new uint256[](1);
            amounts[0] = amount;
            return amounts;
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractOutputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);
        address token;

        if (selector == SWAP_SELECTOR) {
            // SwapDescription.dstToken is 2nd field
            assembly {
                let descOffset := add(add(data.offset, 4), 32)
                let structOffset := add(add(data.offset, 4), calldataload(descOffset))
                // dstToken is 2nd field = offset 32
                token := calldataload(add(structOffset, 32))
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == UNOSWAP_TO_SELECTOR) {
            // Output token is encoded in the last pool
            // For now, return empty - actual output tracked by balance diff
            return new address[](0);
        } else if (selector == UNISWAP_V3_SWAP_TO_SELECTOR) {
            // dstToken is encoded in the last pool
            (,,, uint256[] memory pools) = abi.decode(data[4:], (address, uint256, uint256, uint256[]));
            if (pools.length > 0) {
                // Extract token from last pool (lower 160 bits)
                token = address(uint160(pools[pools.length - 1]));
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == CLIPPER_SWAP_TO_SELECTOR) {
            // clipperSwapTo(..., address dstToken, ...)
            (,,, token,,,,,) = abi.decode(data[4:], (address, address, address, address, uint256, uint256, uint256, bytes32, bytes32));
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address defaultRecipient) external pure override returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SWAP_SELECTOR) {
            // SwapDescription.dstReceiver is 4th field
            assembly {
                let descOffset := add(add(data.offset, 4), 32)
                let structOffset := add(add(data.offset, 4), calldataload(descOffset))
                // dstReceiver is 4th field = offset 96 (3 * 32)
                recipient := calldataload(add(structOffset, 96))
            }
            // If dstReceiver is address(0), use default
            if (recipient == address(0)) {
                recipient = defaultRecipient;
            }
        } else if (selector == UNOSWAP_TO_SELECTOR) {
            // unoswapTo(address to, ...)
            (recipient,,,,) = abi.decode(data[4:], (address, address, uint256, uint256, uint256[]));
        } else if (selector == UNISWAP_V3_SWAP_TO_SELECTOR) {
            // uniswapV3SwapTo(address recipient, ...)
            (recipient,,,) = abi.decode(data[4:], (address, uint256, uint256, uint256[]));
        } else if (selector == CLIPPER_SWAP_TO_SELECTOR) {
            // clipperSwapTo(address clipperExchange, address recipient, ...)
            (, recipient,,,,,,,) = abi.decode(data[4:], (address, address, address, address, uint256, uint256, uint256, bytes32, bytes32));
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == SWAP_SELECTOR ||
               selector == UNOSWAP_TO_SELECTOR ||
               selector == UNISWAP_V3_SWAP_TO_SELECTOR ||
               selector == CLIPPER_SWAP_TO_SELECTOR;
    }

    /// @inheritdoc ICalldataParser
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        bytes4 selector = bytes4(data[:4]);

        // All 1inch functions are swaps
        if (selector == SWAP_SELECTOR ||
            selector == UNOSWAP_TO_SELECTOR ||
            selector == UNISWAP_V3_SWAP_TO_SELECTOR ||
            selector == CLIPPER_SWAP_TO_SELECTOR) {
            return 1; // SWAP
        }

        return 0; // UNKNOWN
    }
}
