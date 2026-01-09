// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";
import {IUniswapV2Pair} from "../interfaces/IUniswapV2Pair.sol";

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
    error InvalidCalldata();

    // Minimum calldata length for SWAP: selector(4) + executor(32) + descOffset(32) + SwapDescription(224 min) = 292
    uint256 private constant MIN_SWAP_LENGTH = 292;

    // Address mask for cleaning upper bits (addresses are 160 bits)
    uint256 private constant ADDRESS_MASK = 0x00ffffffffffffffffffffffffffffffffffffffff;

    // ============ 1inch AggregationRouterV6 Selectors ============

    // swap(address executor, SwapDescription desc, bytes data, bytes permit)
    // SwapDescription: (address srcToken, address dstToken, address srcReceiver, address dstReceiver, uint256 amount, uint256 minReturnAmount, uint256 flags)
    bytes4 public constant SWAP_SELECTOR = 0x12aa3caf;

    // unoswapTo(address to, address srcToken, uint256 amount, uint256 minReturn, uint256[] pools)
    // Pool encoding for unoswapTo (Uniswap V2 style):
    //   Bits 0-159:   Pool (pair) address (NOT token address)
    //   Bits 160-161: Pool type (0=UniswapV2, 1=Curve, etc.)
    //   Bit 255:      Direction flag
    // Note: Output token cannot be extracted from pools - it requires on-chain pool query
    bytes4 public constant UNOSWAP_TO_SELECTOR = 0xf78dc253;

    // uniswapV3SwapTo(address recipient, uint256 amount, uint256 minReturn, uint256[] pools)
    // Pool encoding for uniswapV3SwapTo:
    //   Bits 0-159:   Token address (the token being swapped TO in this hop)
    //   Bits 160-183: Fee tier (e.g., 500, 3000, 10000)
    //   Bit 255:      Direction flag (zeroForOne)
    // Note: First pool contains input token, last pool contains output token
    bytes4 public constant UNISWAP_V3_SWAP_TO_SELECTOR = 0xbc80f1a8;

    // clipperSwapTo(address clipperExchange, address recipient, address srcToken, address dstToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, bytes32 r, bytes32 vs)
    bytes4 public constant CLIPPER_SWAP_TO_SELECTOR = 0x093d4fa5;

    /// @inheritdoc ICalldataParser
    function extractInputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);
        address token;

        if (selector == SWAP_SELECTOR) {
            // Bounds check for SWAP calldata
            if (data.length < MIN_SWAP_LENGTH) revert InvalidCalldata();
            // swap(address executor, SwapDescription desc, bytes data, bytes permit)
            // SwapDescription starts at offset 32 (after executor)
            // srcToken is first field of SwapDescription struct
            assembly {
                // Skip selector (4) + executor (32) = 36
                // First 32 bytes of desc is offset to struct data
                // desc.srcToken is at offset 0 of the struct
                let descOffset := add(add(data.offset, 4), 32) // offset to desc
                let structOffset := add(add(data.offset, 4), calldataload(descOffset))
                token := and(calldataload(structOffset), ADDRESS_MASK)
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
            // uniswapV3SwapTo pools contain token addresses in lower 160 bits
            // First pool contains the input token
            (,,, uint256[] memory pools) = abi.decode(data[4:], (address, uint256, uint256, uint256[]));
            if (pools.length == 0) {
                return new address[](0);
            }
            // Extract input token from first pool (lower 160 bits)
            token = address(uint160(pools[0]));
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
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);
        uint256 amount;

        if (selector == SWAP_SELECTOR) {
            // Bounds check for SWAP calldata
            if (data.length < MIN_SWAP_LENGTH) revert InvalidCalldata();
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
    function extractOutputTokens(address, bytes calldata data) external view override returns (address[] memory tokens) {
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);
        address token;

        if (selector == SWAP_SELECTOR) {
            // Bounds check for SWAP calldata
            if (data.length < MIN_SWAP_LENGTH) revert InvalidCalldata();
            // SwapDescription.dstToken is 2nd field
            assembly {
                let descOffset := add(add(data.offset, 4), 32)
                let structOffset := add(add(data.offset, 4), calldataload(descOffset))
                // dstToken is 2nd field = offset 32 - mask to 160 bits
                token := and(calldataload(add(structOffset, 32)), ADDRESS_MASK)
            }
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == UNOSWAP_TO_SELECTOR) {
            // unoswapTo pools contain V2 pair addresses with direction flags
            // Query the last pool on-chain to determine output token
            (,,,, uint256[] memory pools) = abi.decode(data[4:], (address, address, uint256, uint256, uint256[]));
            if (pools.length == 0) {
                return new address[](0);
            }
            // Last pool determines output token
            uint256 lastPool = pools[pools.length - 1];
            address poolAddress = address(uint160(lastPool));
            // Bit 255: direction flag (0 = token0->token1, 1 = token1->token0)
            bool zeroForOne = (lastPool >> 255) == 0;

            // Query pool for token addresses
            address token0 = IUniswapV2Pair(poolAddress).token0();
            address token1 = IUniswapV2Pair(poolAddress).token1();

            // Output token depends on swap direction
            token = zeroForOne ? token1 : token0;
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == UNISWAP_V3_SWAP_TO_SELECTOR) {
            // uniswapV3SwapTo pools contain token addresses in lower 160 bits
            // Last pool contains the output token
            (,,, uint256[] memory pools) = abi.decode(data[4:], (address, uint256, uint256, uint256[]));
            if (pools.length == 0) {
                return new address[](0);
            }
            // Extract output token from last pool (lower 160 bits)
            token = address(uint160(pools[pools.length - 1]));
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
        if (data.length < 4) revert InvalidCalldata();
        bytes4 selector = bytes4(data[:4]);

        if (selector == SWAP_SELECTOR) {
            // Bounds check for SWAP calldata
            if (data.length < MIN_SWAP_LENGTH) revert InvalidCalldata();
            // SwapDescription.dstReceiver is 4th field
            assembly {
                let descOffset := add(add(data.offset, 4), 32)
                let structOffset := add(add(data.offset, 4), calldataload(descOffset))
                // dstReceiver is 4th field = offset 96 (3 * 32) - mask to 160 bits
                recipient := and(calldataload(add(structOffset, 96)), ADDRESS_MASK)
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
        if (data.length < 4) revert InvalidCalldata();
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
