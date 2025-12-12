// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UniversalRouterParser} from "../src/parsers/UniversalRouterParser.sol";

/**
 * @title UniversalRouterParserTest
 * @notice Tests for the Universal Router parser
 */
contract UniversalRouterParserTest is Test {
    UniversalRouterParser public parser;

    // Test addresses (mainnet style)
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USER = address(0x1234);
    address constant UNIVERSAL_ROUTER = address(0x5678);

    function setUp() public {
        parser = new UniversalRouterParser();
    }

    // ============ Selector Tests ============

    function testSelectors() public view {
        assertEq(parser.EXECUTE_SELECTOR(), bytes4(0x3593564c), "Execute selector mismatch");
    }

    function testSupportsSelector() public view {
        assertTrue(parser.supportsSelector(parser.EXECUTE_SELECTOR()), "Should support execute");
        assertFalse(parser.supportsSelector(bytes4(0xdeadbeef)), "Should not support unknown");
    }

    // ============ Command Constants ============

    function testCommandConstants() public view {
        assertEq(parser.V3_SWAP_EXACT_IN(), 0x00, "V3_SWAP_EXACT_IN");
        assertEq(parser.V3_SWAP_EXACT_OUT(), 0x01, "V3_SWAP_EXACT_OUT");
        assertEq(parser.V2_SWAP_EXACT_IN(), 0x08, "V2_SWAP_EXACT_IN");
        assertEq(parser.V2_SWAP_EXACT_OUT(), 0x09, "V2_SWAP_EXACT_OUT");
        assertEq(parser.WRAP_ETH(), 0x0b, "WRAP_ETH");
        assertEq(parser.UNWRAP_WETH(), 0x0c, "UNWRAP_WETH");
    }

    // ============ Unsupported Selector Tests ============

    function testUnsupportedSelectorRevertsOnInputToken() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(UniversalRouterParser.UnsupportedSelector.selector);
        parser.extractInputToken(UNIVERSAL_ROUTER, badData);
    }

    function testUnsupportedSelectorRevertsOnInputAmount() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(UniversalRouterParser.UnsupportedSelector.selector);
        parser.extractInputAmount(UNIVERSAL_ROUTER, badData);
    }

    function testUnsupportedSelectorRevertsOnOutputToken() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(UniversalRouterParser.UnsupportedSelector.selector);
        parser.extractOutputToken(UNIVERSAL_ROUTER, badData);
    }

    function testUnsupportedSelectorRevertsOnRecipient() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(UniversalRouterParser.UnsupportedSelector.selector);
        parser.extractRecipient(UNIVERSAL_ROUTER, badData, USER);
    }

    // ============ Operation Type Tests ============

    function testGetOperationType() public view {
        // Universal Router is always SWAP
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V3_SWAP_EXACT_IN());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV3SwapExactIn(USER, 1000e6, 0, _encodePath(USDC, 3000, WETH), true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        assertEq(parser.getOperationType(data), 1, "Should always return SWAP (1)");
    }

    // ============ V3_SWAP_EXACT_IN Tests ============

    function testV3SwapExactInExtractInputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V3_SWAP_EXACT_IN());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV3SwapExactIn(USER, 1000e6, 900e18, _encodePath(USDC, 3000, WETH), true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractInputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, USDC, "Input token should be USDC");
    }

    function testV3SwapExactInExtractInputAmount() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V3_SWAP_EXACT_IN());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV3SwapExactIn(USER, 1000e6, 900e18, _encodePath(USDC, 3000, WETH), true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        uint256 amount = parser.extractInputAmount(UNIVERSAL_ROUTER, data);
        assertEq(amount, 1000e6, "Input amount should be 1000e6");
    }

    function testV3SwapExactInExtractOutputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V3_SWAP_EXACT_IN());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV3SwapExactIn(USER, 1000e6, 900e18, _encodePath(USDC, 3000, WETH), true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractOutputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, WETH, "Output token should be WETH");
    }

    function testV3SwapExactInExtractRecipient() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V3_SWAP_EXACT_IN());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV3SwapExactIn(USER, 1000e6, 900e18, _encodePath(USDC, 3000, WETH), true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address recipient = parser.extractRecipient(UNIVERSAL_ROUTER, data, address(0));
        assertEq(recipient, USER, "Recipient should be USER");
    }

    // ============ V3_SWAP_EXACT_OUT Tests ============

    function testV3SwapExactOutExtractInputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V3_SWAP_EXACT_OUT());

        // For EXACT_OUT, path is reversed: tokenOut first, tokenIn last
        // The path is WETH -> USDC, meaning we want WETH, we pay USDC
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV3SwapExactIn(USER, 1e18, 1100e6, _encodePath(WETH, 3000, USDC), true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractInputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, USDC, "Input token should be USDC (last in reversed path)");
    }

    function testV3SwapExactOutExtractOutputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V3_SWAP_EXACT_OUT());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV3SwapExactIn(USER, 1e18, 1100e6, _encodePath(WETH, 3000, USDC), true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractOutputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, WETH, "Output token should be WETH (first in reversed path)");
    }

    // ============ V2_SWAP_EXACT_IN Tests ============

    function testV2SwapExactInExtractInputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V2_SWAP_EXACT_IN());

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, uint256(1000e6), uint256(900e18), path, true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractInputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, USDC, "Input token should be USDC");
    }

    function testV2SwapExactInExtractInputAmount() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V2_SWAP_EXACT_IN());

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, uint256(1000e6), uint256(900e18), path, true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        uint256 amount = parser.extractInputAmount(UNIVERSAL_ROUTER, data);
        assertEq(amount, 1000e6, "Input amount should be 1000e6");
    }

    function testV2SwapExactInExtractOutputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V2_SWAP_EXACT_IN());

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, uint256(1000e6), uint256(900e18), path, true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractOutputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, WETH, "Output token should be WETH");
    }

    // ============ V2_SWAP_EXACT_OUT Tests ============

    function testV2SwapExactOutExtractInputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V2_SWAP_EXACT_OUT());

        // V2 EXACT_OUT: path is normal order, input is last
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, uint256(1e18), uint256(1100e6), path, true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractInputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, WETH, "Input token should be WETH (last in path)");
    }

    function testV2SwapExactOutExtractOutputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V2_SWAP_EXACT_OUT());

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, uint256(1e18), uint256(1100e6), path, true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractOutputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, USDC, "Output token should be USDC (first in path)");
    }

    // ============ WRAP_ETH Tests ============

    function testWrapEthExtractInputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.WRAP_ETH());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, uint256(1e18));

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractInputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, address(0), "Input token should be address(0) for native ETH");
    }

    function testWrapEthExtractInputAmount() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.WRAP_ETH());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, uint256(1e18));

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        uint256 amount = parser.extractInputAmount(UNIVERSAL_ROUTER, data);
        assertEq(amount, 1e18, "Input amount should be 1e18");
    }

    function testWrapEthExtractRecipient() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.WRAP_ETH());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, uint256(1e18));

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address recipient = parser.extractRecipient(UNIVERSAL_ROUTER, data, address(0));
        assertEq(recipient, USER, "Recipient should be USER");
    }

    // ============ UNWRAP_WETH Tests ============

    function testUnwrapWethExtractOutputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.UNWRAP_WETH());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, uint256(1e18));

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractOutputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, address(0), "Output token should be address(0) for native ETH");
    }

    function testUnwrapWethExtractRecipient() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.UNWRAP_WETH());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, uint256(1e18));

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address recipient = parser.extractRecipient(UNIVERSAL_ROUTER, data, address(0));
        assertEq(recipient, USER, "Recipient should be USER");
    }

    // ============ Multi-Hop V3 Tests ============

    function testV3MultiHopExtractInputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V3_SWAP_EXACT_IN());

        // USDC -> DAI -> WETH (3 tokens = 2 hops)
        bytes memory path = _encodeMultiHopPath(USDC, 500, DAI, 3000, WETH);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV3SwapExactIn(USER, 1000e6, 800e18, path, true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractInputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, USDC, "Input token should be USDC (first in multi-hop path)");
    }

    function testV3MultiHopExtractOutputToken() public view {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V3_SWAP_EXACT_IN());

        bytes memory path = _encodeMultiHopPath(USDC, 500, DAI, 3000, WETH);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV3SwapExactIn(USER, 1000e6, 800e18, path, true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractOutputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, WETH, "Output token should be WETH (last in multi-hop path)");
    }

    // ============ Default Recipient Tests ============

    function testDefaultRecipientWhenNoCommands() public view {
        bytes memory commands = "";
        bytes[] memory inputs = new bytes[](0);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address defaultRecipient = address(0x9999);
        address recipient = parser.extractRecipient(UNIVERSAL_ROUTER, data, defaultRecipient);
        assertEq(recipient, defaultRecipient, "Should return default recipient when no commands");
    }

    // ============ Command Flag Masking Tests ============

    function testCommandFlagMasking() public view {
        // Commands can have flag bits set in upper 2 bits (0x40, 0x80)
        // Parser should mask these off with & 0x3f
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(parser.V3_SWAP_EXACT_IN() | 0x40); // With flag

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV3SwapExactIn(USER, 1000e6, 900e18, _encodePath(USDC, 3000, WETH), true);

        bytes memory data = abi.encodeWithSelector(
            parser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address token = parser.extractInputToken(UNIVERSAL_ROUTER, data);
        assertEq(token, USDC, "Should parse correctly with flag bits");
    }

    // ============ Helper Functions ============

    function _encodePath(address tokenA, uint24 fee, address tokenB) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenA, fee, tokenB);
    }

    function _encodeMultiHopPath(
        address token0,
        uint24 fee0,
        address token1,
        uint24 fee1,
        address token2
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(token0, fee0, token1, fee1, token2);
    }

    function _encodeV3SwapExactIn(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory path,
        bool payerIsUser
    ) internal pure returns (bytes memory) {
        return abi.encode(recipient, amountIn, amountOutMin, path, payerIsUser);
    }
}
