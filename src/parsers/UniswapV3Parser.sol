// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title UniswapV3Parser
 * @notice Calldata parser for Uniswap V3 SwapRouter and NonfungiblePositionManager operations
 * @dev Extracts token/amount from Uniswap V3 function calldata
 *
 *      Supported contracts:
 *      - SwapRouter (0xE592427A0AEce92De3Edee1F18E0157C05861564)
 *      - SwapRouter02 (0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45)
 *      - NonfungiblePositionManager (0xC36442b4a4522E871399CD717aBDD847Ab11FE88)
 */
contract UniswapV3Parser is ICalldataParser {
    error UnsupportedSelector();
    error InvalidPath();

    // ============ SwapRouter Selectors ============

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

    // ============ NonfungiblePositionManager Selectors ============

    // mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))
    bytes4 public constant MINT_SELECTOR = 0x88316456;
    // increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256))
    bytes4 public constant INCREASE_LIQUIDITY_SELECTOR = 0x219f5d17;
    // decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))
    bytes4 public constant DECREASE_LIQUIDITY_SELECTOR = 0x0c49ccbe;
    // collect((uint256,address,uint128,uint128))
    bytes4 public constant COLLECT_SELECTOR = 0xfc6f7865;

    /// @inheritdoc ICalldataParser
    function extractInputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        // ============ SwapRouter Functions ============
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
        }
        // ============ NonfungiblePositionManager Functions ============
        else if (selector == MINT_SELECTOR) {
            // MintParams: (token0, token1, fee, tickLower, tickUpper, amount0Desired, amount1Desired, amount0Min, amount1Min, recipient, deadline)
            // Return token0 as the input token (both tokens are input)
            (token,,,,,,,,,) = abi.decode(data[4:], (address, address, uint24, int24, int24, uint256, uint256, uint256, uint256, address));
        } else if (selector == INCREASE_LIQUIDITY_SELECTOR) {
            // IncreaseLiquidityParams: (tokenId, amount0Desired, amount1Desired, amount0Min, amount1Min, deadline)
            // No token address in calldata - return address(0), tracked via balance change
            return address(0);
        } else if (selector == DECREASE_LIQUIDITY_SELECTOR || selector == COLLECT_SELECTOR) {
            // These are withdraw/claim operations - no input token
            return address(0);
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmount(address, bytes calldata data) external pure override returns (uint256 amount) {
        bytes4 selector = bytes4(data[:4]);

        // ============ SwapRouter Functions ============
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
        }
        // ============ NonfungiblePositionManager Functions ============
        else if (selector == MINT_SELECTOR) {
            // MintParams: (token0, token1, fee, tickLower, tickUpper, amount0Desired, amount1Desired, amount0Min, amount1Min, recipient, deadline)
            // Return amount0Desired as the primary input amount (tracked via balance change for both)
            (,,,,, amount,,,,) = abi.decode(data[4:], (address, address, uint24, int24, int24, uint256, uint256, uint256, uint256, address));
        } else if (selector == INCREASE_LIQUIDITY_SELECTOR) {
            // IncreaseLiquidityParams: (tokenId, amount0Desired, amount1Desired, amount0Min, amount1Min, deadline)
            // Return amount0Desired
            (, amount,,,,) = abi.decode(data[4:], (uint256, uint256, uint256, uint256, uint256, uint256));
        } else if (selector == DECREASE_LIQUIDITY_SELECTOR || selector == COLLECT_SELECTOR) {
            // These are withdraw/claim operations - no input amount
            return 0;
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractOutputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        // ============ SwapRouter Functions ============
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
        }
        // ============ NonfungiblePositionManager Functions ============
        else if (selector == MINT_SELECTOR || selector == INCREASE_LIQUIDITY_SELECTOR) {
            // Deposit operations - output is LP NFT, tracked via balance change
            return address(0);
        } else if (selector == DECREASE_LIQUIDITY_SELECTOR) {
            // DecreaseLiquidityParams: (tokenId, liquidity, amount0Min, amount1Min, deadline)
            // Output tokens tracked via balance change (both tokens returned)
            return address(0);
        } else if (selector == COLLECT_SELECTOR) {
            // CollectParams: (tokenId, recipient, amount0Max, amount1Max)
            // Output tokens tracked via balance change (fees in both tokens)
            return address(0);
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address defaultRecipient) external pure override returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);

        // ============ SwapRouter Functions ============
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
        }
        // ============ NonfungiblePositionManager Functions ============
        else if (selector == MINT_SELECTOR) {
            // MintParams: (token0, token1, fee, tickLower, tickUpper, amount0Desired, amount1Desired, amount0Min, amount1Min, recipient, deadline)
            (,,,,,,,,, recipient,) = abi.decode(data[4:], (address, address, uint24, int24, int24, uint256, uint256, uint256, uint256, address, uint256));
        } else if (selector == INCREASE_LIQUIDITY_SELECTOR || selector == DECREASE_LIQUIDITY_SELECTOR) {
            // These operate on existing positions owned by the caller
            // No explicit recipient - tokens go to/from msg.sender (Safe)
            return defaultRecipient;
        } else if (selector == COLLECT_SELECTOR) {
            // CollectParams: (tokenId, recipient, amount0Max, amount1Max)
            (, recipient,,) = abi.decode(data[4:], (uint256, address, uint128, uint128));
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
               selector == EXACT_OUTPUT_02_SELECTOR ||
               selector == MINT_SELECTOR ||
               selector == INCREASE_LIQUIDITY_SELECTOR ||
               selector == DECREASE_LIQUIDITY_SELECTOR ||
               selector == COLLECT_SELECTOR;
    }

    /**
     * @notice Get the operation type for the given calldata
     * @param data The calldata to analyze
     * @return opType 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     */
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        bytes4 selector = bytes4(data[:4]);
        // Swap operations
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
        // Deposit operations (adding liquidity)
        if (selector == MINT_SELECTOR || selector == INCREASE_LIQUIDITY_SELECTOR) {
            return 2; // DEPOSIT
        }
        // Withdraw operations (removing liquidity)
        if (selector == DECREASE_LIQUIDITY_SELECTOR) {
            return 3; // WITHDRAW
        }
        // Claim operations (collecting fees)
        if (selector == COLLECT_SELECTOR) {
            return 4; // CLAIM
        }
        return 0; // UNKNOWN
    }
}
