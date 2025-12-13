// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UniswapV4Parser} from "../src/parsers/UniswapV4Parser.sol";

/**
 * @title MockV4PositionManager
 * @notice Mock contract for testing INCREASE_LIQUIDITY position queries
 */
contract MockV4PositionManager {
    mapping(uint256 => address) public token0s;
    mapping(uint256 => address) public token1s;

    function setPosition(uint256 tokenId, address currency0, address currency1) external {
        token0s[tokenId] = currency0;
        token1s[tokenId] = currency1;
    }

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) {
        return (token0s[tokenId], token1s[tokenId], 3000, 60, address(0), -887220, 887220, 1000e6);
    }
}

/**
 * @title UniswapV4ParserTest
 * @notice Tests for the Uniswap V4 PositionManager parser
 */
contract UniswapV4ParserTest is Test {
    UniswapV4Parser public parser;
    MockV4PositionManager public mockPositionManager;

    // Test addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USER = address(0x1234);
    address constant V4_POSITION_MANAGER = address(0x5678);

    function setUp() public {
        parser = new UniswapV4Parser();
        mockPositionManager = new MockV4PositionManager();
    }

    // ============ Selector Tests ============

    function testSelectors() public view {
        assertEq(parser.MODIFY_LIQUIDITIES_SELECTOR(), bytes4(0xdd46508f), "Selector mismatch");
    }

    function testSupportsSelector() public view {
        assertTrue(parser.supportsSelector(parser.MODIFY_LIQUIDITIES_SELECTOR()), "Should support modifyLiquidities");
        assertFalse(parser.supportsSelector(bytes4(0xdeadbeef)), "Should not support unknown");
    }

    // ============ Action Type Constants ============

    function testActionConstants() public view {
        assertEq(parser.INCREASE_LIQUIDITY(), 0x00, "INCREASE_LIQUIDITY");
        assertEq(parser.DECREASE_LIQUIDITY(), 0x01, "DECREASE_LIQUIDITY");
        assertEq(parser.MINT_POSITION(), 0x02, "MINT_POSITION");
        assertEq(parser.BURN_POSITION(), 0x03, "BURN_POSITION");
        assertEq(parser.SETTLE(), 0x0b, "SETTLE");
        assertEq(parser.SETTLE_PAIR(), 0x0d, "SETTLE_PAIR");
        assertEq(parser.TAKE(), 0x0e, "TAKE");
        assertEq(parser.TAKE_PAIR(), 0x11, "TAKE_PAIR");
        assertEq(parser.SWEEP(), 0x14, "SWEEP");
    }

    // ============ Unsupported Selector Tests ============

    function testUnsupportedSelectorRevertsOnInputToken() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(UniswapV4Parser.UnsupportedSelector.selector);
        parser.extractInputTokens(V4_POSITION_MANAGER, badData);
    }

    function testUnsupportedSelectorRevertsOnInputAmount() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(UniswapV4Parser.UnsupportedSelector.selector);
        parser.extractInputAmounts(V4_POSITION_MANAGER, badData);
    }

    function testUnsupportedSelectorRevertsOnOutputTokens() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(UniswapV4Parser.UnsupportedSelector.selector);
        parser.extractOutputTokens(V4_POSITION_MANAGER, badData);
    }

    function testUnsupportedSelectorRevertsOnRecipient() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(UniswapV4Parser.UnsupportedSelector.selector);
        parser.extractRecipient(V4_POSITION_MANAGER, badData, USER);
    }

    // ============ Operation Type Tests ============

    function testGetOperationTypeUnsupported() public view {
        bytes memory unknownData = abi.encodeWithSelector(bytes4(0xdeadbeef));
        assertEq(parser.getOperationType(unknownData), 0, "Unknown should return 0");
    }

    // ============ Empty/Malformed Data Tests ============

    function testEmptyUnlockData() public view {
        // Create modifyLiquidities with empty unlockData
        bytes memory unlockData = "";
        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        // Should return empty array without reverting
        address[] memory inputTokens = parser.extractInputTokens(V4_POSITION_MANAGER, data);
        assertEq(inputTokens.length, 0, "Should return empty array for empty data");
    }

    function testMinimalUnlockData() public view {
        // Create unlockData with just enough bytes but no valid actions
        bytes memory unlockData = new bytes(64);
        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory inputTokens = parser.extractInputTokens(V4_POSITION_MANAGER, data);
        assertEq(inputTokens.length, 0, "Should return empty array for minimal data");
    }

    // ============ SETTLE Action Tests ============

    function testExtractInputTokenFromSettle() public view {
        // Build actions: [SETTLE]
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.SETTLE());

        // SETTLE params: (Currency currency, uint256 amount, bool payerIsUser)
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(USDC, 1000e6, true);

        // Encode unlockData: abi.encode(bytes actions, bytes[] params)
        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory inputTokens = parser.extractInputTokens(V4_POSITION_MANAGER, data);
        assertEq(inputTokens[0], USDC, "Input token should be USDC from SETTLE");
    }

    function testExtractInputAmountFromSettle() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.SETTLE());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(USDC, 1000e6, true);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        uint256[] memory amounts = parser.extractInputAmounts(V4_POSITION_MANAGER, data);
        assertEq(amounts[0], 1000e6, "Input amount should be 1000e6");
    }

    // ============ SETTLE_PAIR Action Tests ============

    function testExtractInputTokenFromSettlePair() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.SETTLE_PAIR());

        // SETTLE_PAIR params: (Currency currency0, Currency currency1)
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(USDC, WETH);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory inputTokens = parser.extractInputTokens(V4_POSITION_MANAGER, data);
        assertEq(inputTokens.length, 2, "SETTLE_PAIR should return 2 tokens");
        assertEq(inputTokens[0], USDC, "Input token should be first currency (USDC) from SETTLE_PAIR");
        assertEq(inputTokens[1], WETH, "Input token should be second currency (WETH) from SETTLE_PAIR");
    }

    function testSettlePairArrayLengthsMatch() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.SETTLE_PAIR());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(USDC, WETH);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory inputTokens = parser.extractInputTokens(V4_POSITION_MANAGER, data);
        uint256[] memory inputAmounts = parser.extractInputAmounts(V4_POSITION_MANAGER, data);

        // Critical: array lengths must match for DeFiInteractorModule
        assertEq(inputTokens.length, inputAmounts.length, "Token and amount arrays must have same length");
        assertEq(inputTokens.length, 2, "Should have 2 tokens");
        assertEq(inputAmounts[0], 0, "Amount0 should be 0 (tracked via balance changes)");
        assertEq(inputAmounts[1], 0, "Amount1 should be 0 (tracked via balance changes)");
    }

    // ============ TAKE Action Tests ============

    function testExtractOutputTokensFromTake() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.TAKE());

        // TAKE params: (Currency currency, address recipient, uint256 amount)
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(WETH, USER, 1e18);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory outputTokens = parser.extractOutputTokens(V4_POSITION_MANAGER, data);
        assertEq(outputTokens.length, 1, "Should have 1 output token");
        assertEq(outputTokens[0], WETH, "Output token should be WETH from TAKE");
    }

    function testExtractRecipientFromTake() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.TAKE());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(WETH, USER, 1e18);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address recipient = parser.extractRecipient(V4_POSITION_MANAGER, data, address(0));
        assertEq(recipient, USER, "Recipient should be USER from TAKE");
    }

    // ============ TAKE_PAIR Action Tests ============

    function testExtractOutputTokensFromTakePair() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.TAKE_PAIR());

        // TAKE_PAIR params: (Currency currency0, Currency currency1, address recipient)
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(USDC, WETH, USER);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory outputTokens = parser.extractOutputTokens(V4_POSITION_MANAGER, data);
        assertEq(outputTokens.length, 2, "Should have 2 output tokens from TAKE_PAIR");
        assertEq(outputTokens[0], USDC, "First output token should be USDC");
        assertEq(outputTokens[1], WETH, "Second output token should be WETH");
    }

    function testExtractRecipientFromTakePair() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.TAKE_PAIR());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(USDC, WETH, USER);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address recipient = parser.extractRecipient(V4_POSITION_MANAGER, data, address(0));
        assertEq(recipient, USER, "Recipient should be USER from TAKE_PAIR");
    }

    // ============ SWEEP Action Tests ============

    function testExtractOutputTokensFromSweep() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.SWEEP());

        // SWEEP params: (Currency currency, address recipient)
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(WETH, USER);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory outputTokens = parser.extractOutputTokens(V4_POSITION_MANAGER, data);
        assertEq(outputTokens.length, 1, "Should have 1 output token");
        assertEq(outputTokens[0], WETH, "Output token should be WETH from SWEEP");
    }

    function testExtractRecipientFromSweep() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.SWEEP());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(WETH, USER);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address recipient = parser.extractRecipient(V4_POSITION_MANAGER, data, address(0));
        assertEq(recipient, USER, "Recipient should be USER from SWEEP");
    }

    // ============ Default Recipient Tests ============

    function testDefaultRecipientWhenNoExplicitRecipient() public view {
        // Actions with no explicit recipient (e.g., SETTLE only)
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.SETTLE());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(USDC, 1000e6, true);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address defaultRecipient = address(0x9999);
        address recipient = parser.extractRecipient(V4_POSITION_MANAGER, data, defaultRecipient);
        assertEq(recipient, defaultRecipient, "Should return default recipient when no explicit one");
    }

    // ============ DECREASE_LIQUIDITY Operation Type Tests ============

    function testDecreaseLiquidityWithZeroLiquidityIsClaim() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.DECREASE_LIQUIDITY());

        // DecreaseLiquidityParams: (uint256 tokenId, uint128 liquidity, uint128 amount0Min, uint128 amount1Min, bytes hookData)
        // liquidity = 0 means just collecting fees
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(uint256(1), uint128(0), uint128(0), uint128(0), "");

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 4, "DECREASE_LIQUIDITY with 0 liquidity should be CLAIM (4)");
    }

    function testDecreaseLiquidityWithNonZeroIsWithdraw() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.DECREASE_LIQUIDITY());

        // liquidity > 0 means actual withdrawal
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(uint256(1), uint128(1000), uint128(0), uint128(0), "");

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 3, "DECREASE_LIQUIDITY with liquidity > 0 should be WITHDRAW (3)");
    }

    // ============ BURN_POSITION Operation Type Tests ============

    function testBurnPositionIsWithdraw() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.BURN_POSITION());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(uint256(1), uint128(0), uint128(0), "");

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 3, "BURN_POSITION should be WITHDRAW (3)");
    }

    function testDecreaseLiquidityExtractsOutputTokens() public {
        // Setup mock position with known tokens
        uint256 tokenId = 123;
        mockPositionManager.setPosition(tokenId, USDC, WETH);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.DECREASE_LIQUIDITY());

        // DecreaseLiquidityParams: (uint256 tokenId, uint128 liquidity, uint128 amount0Min, uint128 amount1Min, bytes hookData)
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, uint128(1000e6), uint128(0), uint128(0), "");

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        // Extract output tokens - should query position manager
        address[] memory outputTokens = parser.extractOutputTokens(address(mockPositionManager), data);
        assertEq(outputTokens.length, 2, "Should have 2 output tokens for DECREASE_LIQUIDITY");
        assertEq(outputTokens[0], USDC, "Token0 should be USDC from position");
        assertEq(outputTokens[1], WETH, "Token1 should be WETH from position");
    }

    function testBurnPositionExtractsOutputTokens() public {
        // Setup mock position with known tokens
        uint256 tokenId = 456;
        mockPositionManager.setPosition(tokenId, USDC, WETH);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.BURN_POSITION());

        // BurnPositionParams: (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes hookData)
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), "");

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        // Extract output tokens - should query position manager
        address[] memory outputTokens = parser.extractOutputTokens(address(mockPositionManager), data);
        assertEq(outputTokens.length, 2, "Should have 2 output tokens for BURN_POSITION");
        assertEq(outputTokens[0], USDC, "Token0 should be USDC from position");
        assertEq(outputTokens[1], WETH, "Token1 should be WETH from position");
    }

    // ============ MINT_POSITION Operation Type Tests ============

    function testMintPositionIsDeposit() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.MINT_POSITION());

        // MintPositionParams: PoolKey (currency0, currency1, fee, tickSpacing, hooks), int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0Max, uint256 amount1Max, address owner, bytes hookData
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(
            USDC, WETH, uint24(3000), int24(60), address(0), // PoolKey
            int24(-887220), int24(887220), // tick range
            uint128(1000e6), // liquidity
            uint256(1000e6), uint256(1e18), // max amounts
            USER, // owner
            "" // hookData
        );

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 2, "MINT_POSITION should be DEPOSIT (2)");
    }

    function testMintPositionArrayLengthsMatch() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.MINT_POSITION());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(
            USDC, WETH, uint24(3000), int24(60), address(0), // PoolKey
            int24(-887220), int24(887220), // tick range
            uint128(1000e6), // liquidity
            uint256(1000e6), uint256(1e18), // max amounts
            USER, // owner
            "" // hookData
        );

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory inputTokens = parser.extractInputTokens(V4_POSITION_MANAGER, data);
        uint256[] memory inputAmounts = parser.extractInputAmounts(V4_POSITION_MANAGER, data);

        // Critical: array lengths must match for DeFiInteractorModule
        assertEq(inputTokens.length, inputAmounts.length, "Token and amount arrays must have same length");
        assertEq(inputTokens.length, 2, "Should have 2 tokens for MINT_POSITION");
        assertEq(inputTokens[0], USDC, "Token0 should be USDC");
        assertEq(inputTokens[1], WETH, "Token1 should be WETH");
    }

    // ============ INCREASE_LIQUIDITY Operation Type Tests ============

    function testIncreaseLiquidityIsDeposit() public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.INCREASE_LIQUIDITY());

        // IncreaseLiquidityParams: (uint256 tokenId, uint128 liquidity, uint128 amount0Max, uint128 amount1Max, bytes hookData)
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(uint256(1), uint128(1000e6), uint128(1000e6), uint128(1e18), "");

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 2, "INCREASE_LIQUIDITY should be DEPOSIT (2)");
    }

    function testIncreaseLiquidityExtractsTokensAndAmounts() public {
        // Setup mock position
        uint256 tokenId = 42;
        mockPositionManager.setPosition(tokenId, USDC, WETH);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(parser.INCREASE_LIQUIDITY());

        // IncreaseLiquidityParams: (uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max, bytes hookData)
        // Offsets: tokenId=0, liquidity=32, amount0Max=64, amount1Max=96
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(
            tokenId,           // tokenId at offset 0
            uint256(1000e6),   // liquidity at offset 32
            uint128(500e6),    // amount0Max at offset 64
            uint128(2e18),     // amount1Max at offset 96
            ""                 // hookData
        );

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        // Extract tokens - queries the mock position manager
        address[] memory inputTokens = parser.extractInputTokens(address(mockPositionManager), data);
        assertEq(inputTokens.length, 2, "Should have 2 tokens");
        assertEq(inputTokens[0], USDC, "Token0 should be USDC from position");
        assertEq(inputTokens[1], WETH, "Token1 should be WETH from position");

        // Extract amounts - decoded from params
        uint256[] memory inputAmounts = parser.extractInputAmounts(address(mockPositionManager), data);
        assertEq(inputAmounts.length, 2, "Should have 2 amounts");
        assertEq(inputAmounts[0], 500e6, "Amount0 should be amount0Max");
        assertEq(inputAmounts[1], 2e18, "Amount1 should be amount1Max");

        // Verify lengths match for module compatibility
        assertEq(inputTokens.length, inputAmounts.length, "Token and amount arrays must match");
    }

    // ============ Multi-Action Tests ============

    function testMultipleSettleActionsReturnsFirst() public view {
        // With multiple SETTLE actions, parser returns the first one found
        bytes memory actions = new bytes(2);
        actions[0] = bytes1(parser.SETTLE());
        actions[1] = bytes1(parser.SETTLE());

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(USDC, 1000e6, true);
        params[1] = abi.encode(WETH, 2e18, true);

        bytes memory unlockData = abi.encode(actions, params);

        bytes memory data = abi.encodeWithSelector(
            parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        // Returns just the first SETTLE amount
        uint256[] memory amounts = parser.extractInputAmounts(V4_POSITION_MANAGER, data);
        assertEq(amounts.length, 1, "Should have 1 input amount from first SETTLE");
        assertEq(amounts[0], 1000e6, "Should return first SETTLE amount");

        // Returns just the first SETTLE token
        address[] memory tokens = parser.extractInputTokens(V4_POSITION_MANAGER, data);
        assertEq(tokens.length, 1, "Should have 1 input token from first SETTLE");
        assertEq(tokens[0], USDC, "Should return first SETTLE token");
    }
}
