// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UniswapV3Parser} from "../src/parsers/UniswapV3Parser.sol";

/**
 * @title UniswapV3ParserTest
 * @notice Tests for the Uniswap V3 SwapRouter parser
 */
contract UniswapV3ParserTest is Test {
    UniswapV3Parser public parser;

    // Test addresses
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant DAI = 0x6B175474e89094c44da98B954EedeaCB5BE3D86E;
    address constant USER = address(0x1234);

    uint24 constant FEE_LOW = 500;
    uint24 constant FEE_MEDIUM = 3000;

    function setUp() public {
        parser = new UniswapV3Parser();
    }

    // ============ Selector Tests ============

    function testSelectors() public view {
        assertEq(parser.EXACT_INPUT_SINGLE_SELECTOR(), bytes4(0x414bf389), "ExactInputSingle selector mismatch");
        assertEq(parser.EXACT_INPUT_SELECTOR(), bytes4(0xc04b8d59), "ExactInput selector mismatch");
        assertEq(parser.EXACT_OUTPUT_SINGLE_SELECTOR(), bytes4(0xdb3e2198), "ExactOutputSingle selector mismatch");
        assertEq(parser.EXACT_OUTPUT_SELECTOR(), bytes4(0xf28c0498), "ExactOutput selector mismatch");
    }

    function testSupportsSelector() public view {
        assertTrue(parser.supportsSelector(parser.EXACT_INPUT_SINGLE_SELECTOR()), "Should support exactInputSingle");
        assertTrue(parser.supportsSelector(parser.EXACT_INPUT_SELECTOR()), "Should support exactInput");
        assertTrue(parser.supportsSelector(parser.EXACT_OUTPUT_SINGLE_SELECTOR()), "Should support exactOutputSingle");
        assertTrue(parser.supportsSelector(parser.EXACT_OUTPUT_SELECTOR()), "Should support exactOutput");
        assertFalse(parser.supportsSelector(bytes4(0xdeadbeef)), "Should not support unknown");
    }

    // ============ ExactInputSingle Tests ============

    function testExactInputSingleExtractInputToken() public view {
        // exactInputSingle((address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 deadline, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96))
        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_INPUT_SINGLE_SELECTOR(),
            USDC,           // tokenIn
            WETH,           // tokenOut
            FEE_MEDIUM,     // fee
            USER,           // recipient
            block.timestamp + 3600, // deadline
            1000e6,         // amountIn
            0,              // amountOutMinimum
            uint160(0)      // sqrtPriceLimitX96
        );

        address token = parser.extractInputToken(SWAP_ROUTER, data);
        assertEq(token, USDC, "Input token should be USDC");
    }

    function testExactInputSingleExtractInputAmount() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_INPUT_SINGLE_SELECTOR(),
            USDC,
            WETH,
            FEE_MEDIUM,
            USER,
            block.timestamp + 3600,
            1000e6,
            0,
            uint160(0)
        );

        uint256 amount = parser.extractInputAmount(SWAP_ROUTER, data);
        assertEq(amount, 1000e6, "Input amount should be 1000e6");
    }

    function testExactInputSingleExtractOutputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_INPUT_SINGLE_SELECTOR(),
            USDC,
            WETH,
            FEE_MEDIUM,
            USER,
            block.timestamp + 3600,
            1000e6,
            0,
            uint160(0)
        );

        address[] memory tokens = parser.extractOutputTokens(SWAP_ROUTER, data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], WETH, "Output token should be WETH");
    }

    // ============ ExactInput (Multi-hop) Tests ============

    function testExactInputExtractInputToken() public view {
        // Path encoding: tokenIn (20 bytes) + fee (3 bytes) + tokenOut (20 bytes)
        // For multi-hop: tokenA + fee + tokenB + fee + tokenC
        bytes memory path = abi.encodePacked(USDC, FEE_MEDIUM, WETH);

        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_INPUT_SELECTOR(),
            path,
            USER,
            block.timestamp + 3600,
            1000e6,
            0
        );

        address token = parser.extractInputToken(SWAP_ROUTER, data);
        assertEq(token, USDC, "Input token should be USDC (first in path)");
    }

    function testExactInputExtractInputAmount() public view {
        bytes memory path = abi.encodePacked(USDC, FEE_MEDIUM, WETH);

        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_INPUT_SELECTOR(),
            path,
            USER,
            block.timestamp + 3600,
            1000e6,
            0
        );

        uint256 amount = parser.extractInputAmount(SWAP_ROUTER, data);
        assertEq(amount, 1000e6, "Input amount should be 1000e6");
    }

    function testExactInputExtractOutputTokens() public view {
        bytes memory path = abi.encodePacked(USDC, FEE_MEDIUM, WETH);

        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_INPUT_SELECTOR(),
            path,
            USER,
            block.timestamp + 3600,
            1000e6,
            0
        );

        address[] memory tokens = parser.extractOutputTokens(SWAP_ROUTER, data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], WETH, "Output token should be WETH (last in path)");
    }

    function testExactInputMultiHop() public view {
        // USDC -> WETH -> DAI (3-hop path)
        bytes memory path = abi.encodePacked(
            USDC,
            FEE_MEDIUM,
            WETH,
            FEE_LOW,
            DAI
        );

        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_INPUT_SELECTOR(),
            path,
            USER,
            block.timestamp + 3600,
            1000e6,
            0
        );

        address inputToken = parser.extractInputToken(SWAP_ROUTER, data);
        address[] memory outputTokens = parser.extractOutputTokens(SWAP_ROUTER, data);

        assertEq(inputToken, USDC, "Input should be first token (USDC)");
        assertEq(outputTokens.length, 1, "Should have 1 output token");
        assertEq(outputTokens[0], DAI, "Output should be last token (DAI)");
    }

    // ============ ExactOutputSingle Tests ============

    function testExactOutputSingleExtractInputToken() public view {
        // exactOutputSingle params: tokenIn, tokenOut, fee, recipient, deadline, amountOut, amountInMaximum, sqrtPriceLimitX96
        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_OUTPUT_SINGLE_SELECTOR(),
            USDC,           // tokenIn
            WETH,           // tokenOut
            FEE_MEDIUM,
            USER,
            block.timestamp + 3600,
            1e18,           // amountOut (want 1 WETH)
            2000e6,         // amountInMaximum
            uint160(0)
        );

        address token = parser.extractInputToken(SWAP_ROUTER, data);
        assertEq(token, USDC, "Input token should be USDC");
    }

    function testExactOutputSingleExtractInputAmount() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_OUTPUT_SINGLE_SELECTOR(),
            USDC,
            WETH,
            FEE_MEDIUM,
            USER,
            block.timestamp + 3600,
            1e18,
            2000e6,         // amountInMaximum
            uint160(0)
        );

        uint256 amount = parser.extractInputAmount(SWAP_ROUTER, data);
        assertEq(amount, 2000e6, "Input amount should be amountInMaximum");
    }

    function testExactOutputSingleExtractOutputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_OUTPUT_SINGLE_SELECTOR(),
            USDC,
            WETH,
            FEE_MEDIUM,
            USER,
            block.timestamp + 3600,
            1e18,
            2000e6,
            uint160(0)
        );

        address[] memory tokens = parser.extractOutputTokens(SWAP_ROUTER, data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], WETH, "Output token should be WETH");
    }

    // ============ ExactOutput (Multi-hop) Tests ============

    function testExactOutputExtractTokens() public view {
        // For exactOutput, path is REVERSED: tokenOut -> ... -> tokenIn
        // So if we want USDC -> WETH, path is WETH + fee + USDC
        bytes memory path = abi.encodePacked(WETH, FEE_MEDIUM, USDC);

        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_OUTPUT_SELECTOR(),
            path,
            USER,
            block.timestamp + 3600,
            1e18,           // amountOut
            2000e6          // amountInMaximum
        );

        address inputToken = parser.extractInputToken(SWAP_ROUTER, data);
        address[] memory outputTokens = parser.extractOutputTokens(SWAP_ROUTER, data);

        // In reversed path: last token is input, first token is output
        assertEq(inputToken, USDC, "Input token should be USDC (last in reversed path)");
        assertEq(outputTokens.length, 1, "Should have 1 output token");
        assertEq(outputTokens[0], WETH, "Output token should be WETH (first in reversed path)");
    }

    function testExactOutputExtractInputAmount() public view {
        bytes memory path = abi.encodePacked(WETH, FEE_MEDIUM, USDC);

        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_OUTPUT_SELECTOR(),
            path,
            USER,
            block.timestamp + 3600,
            1e18,
            2000e6
        );

        uint256 amount = parser.extractInputAmount(SWAP_ROUTER, data);
        assertEq(amount, 2000e6, "Input amount should be amountInMaximum");
    }

    // ============ Operation Type Tests ============

    function testGetOperationType() public view {
        // Helper to create minimal calldata from selector
        bytes memory exactInputSingleData = abi.encodeWithSelector(parser.EXACT_INPUT_SINGLE_SELECTOR());
        bytes memory exactInputData = abi.encodeWithSelector(parser.EXACT_INPUT_SELECTOR());
        bytes memory exactOutputSingleData = abi.encodeWithSelector(parser.EXACT_OUTPUT_SINGLE_SELECTOR());
        bytes memory exactOutputData = abi.encodeWithSelector(parser.EXACT_OUTPUT_SELECTOR());
        bytes memory unknownData = abi.encodeWithSelector(bytes4(0xdeadbeef));

        assertEq(parser.getOperationType(exactInputSingleData), 1, "ExactInputSingle should be SWAP (1)");
        assertEq(parser.getOperationType(exactInputData), 1, "ExactInput should be SWAP (1)");
        assertEq(parser.getOperationType(exactOutputSingleData), 1, "ExactOutputSingle should be SWAP (1)");
        assertEq(parser.getOperationType(exactOutputData), 1, "ExactOutput should be SWAP (1)");
        assertEq(parser.getOperationType(unknownData), 0, "Unknown should return 0");
    }

    // ============ Revert Tests ============

    function testUnsupportedSelectorReverts() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(UniswapV3Parser.UnsupportedSelector.selector);
        parser.extractInputToken(SWAP_ROUTER, badData);

        vm.expectRevert(UniswapV3Parser.UnsupportedSelector.selector);
        parser.extractInputAmount(SWAP_ROUTER, badData);

        vm.expectRevert(UniswapV3Parser.UnsupportedSelector.selector);
        parser.extractOutputTokens(SWAP_ROUTER, badData);
    }

    function testInvalidPathReverts() public {
        // Path too short (less than 20 bytes for a token address)
        bytes memory shortPath = hex"1234";

        bytes memory data = abi.encodeWithSelector(
            parser.EXACT_INPUT_SELECTOR(),
            shortPath,
            USER,
            block.timestamp + 3600,
            1000e6,
            0
        );

        vm.expectRevert(UniswapV3Parser.InvalidPath.selector);
        parser.extractInputToken(SWAP_ROUTER, data);
    }
}
