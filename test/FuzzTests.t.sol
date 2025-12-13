// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeFiInteractorModule} from "../src/DeFiInteractorModule.sol";
import {UniswapV4Parser} from "../src/parsers/UniswapV4Parser.sol";
import {UniswapV3Parser} from "../src/parsers/UniswapV3Parser.sol";
import {AaveV3Parser} from "../src/parsers/AaveV3Parser.sol";
import {UniversalRouterParser} from "../src/parsers/UniversalRouterParser.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockERC20
 * @notice Simple mock for testing
 */
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    uint8 public decimals = 18;

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setDecimals(uint8 _decimals) external {
        decimals = _decimals;
    }
}

/**
 * @title MockPriceFeed
 * @notice Mock Chainlink price feed for testing
 */
contract MockPriceFeed {
    int256 public price;
    uint8 public decimals_;
    uint256 public updatedAt;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimals_ = _decimals;
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt_,
        uint80 answeredInRound
    ) {
        return (1, price, block.timestamp, updatedAt, 1);
    }

    function setPrice(int256 _price) external {
        price = _price;
    }
}

/**
 * @title MockSafe
 * @notice Mock Safe for testing module execution
 */
contract MockSafe {
    bool public execSuccess = true;

    function execTransactionFromModule(
        address,
        uint256,
        bytes calldata,
        uint8
    ) external returns (bool) {
        return execSuccess;
    }

    function setExecSuccess(bool _success) external {
        execSuccess = _success;
    }
}

/**
 * @title MockV3PositionManager
 * @notice Mock for Uniswap V3 position queries
 */
contract MockV3PositionManager {
    address public token0;
    address public token1;

    function setPosition(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function positions(uint256) external view returns (
        uint96 nonce,
        address operator,
        address token0_,
        address token1_,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) {
        return (0, address(0), token0, token1, 3000, -887220, 887220, 1000e6, 0, 0, 0, 0);
    }
}

/**
 * @title MockV4PositionManager
 * @notice Mock for Uniswap V4 position queries
 */
contract MockV4PositionManager {
    address public token0;
    address public token1;

    function setPosition(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function getPoolAndPositionInfo(uint256) external view returns (
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) {
        return (token0, token1, 3000, 60, address(0), -887220, 887220, 1000e6);
    }
}

/**
 * @title MockAavePool
 * @notice Mock Aave pool for reserve data queries
 */
contract MockAavePool {
    address public aToken;

    function setAToken(address _aToken) external {
        aToken = _aToken;
    }

    function getReserveData(address) external view returns (
        uint256 configuration,
        uint128 liquidityIndex,
        uint128 currentLiquidityRate,
        uint128 variableBorrowIndex,
        uint128 currentVariableBorrowRate,
        uint128 currentStableBorrowRate,
        uint40 lastUpdateTimestamp,
        uint16 id,
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress,
        address interestRateStrategyAddress,
        uint128 accruedToTreasury,
        uint128 unbacked,
        uint128 isolationModeTotalDebt
    ) {
        return (0, 0, 0, 0, 0, 0, 0, 0, aToken, address(0), address(0), address(0), 0, 0, 0);
    }
}

/**
 * @title FuzzTests
 * @notice Comprehensive fuzz tests for DeFi module and parsers
 */
contract FuzzTests is Test {
    UniswapV4Parser public v4Parser;
    UniswapV3Parser public v3Parser;
    AaveV3Parser public aaveParser;
    UniversalRouterParser public universalParser;
    MockV3PositionManager public mockV3PM;
    MockV4PositionManager public mockV4PM;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USER = address(0x1234);

    function setUp() public {
        v4Parser = new UniswapV4Parser();
        v3Parser = new UniswapV3Parser();
        aaveParser = new AaveV3Parser();
        universalParser = new UniversalRouterParser();
        mockV3PM = new MockV3PositionManager();
        mockV4PM = new MockV4PositionManager();

        mockV3PM.setPosition(USDC, WETH);
        mockV4PM.setPosition(USDC, WETH);
    }

    // ============ UniswapV4Parser Fuzz Tests ============

    /**
     * @notice Fuzz test: SETTLE action with various amounts
     * @dev Ensures amount extraction works for all uint256 values
     */
    function testFuzzV4SettleAmount(uint256 amount) public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(v4Parser.SETTLE());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(USDC, amount, true);

        bytes memory unlockData = abi.encode(actions, params);
        bytes memory data = abi.encodeWithSelector(
            v4Parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        uint256[] memory amounts = v4Parser.extractInputAmounts(address(mockV4PM), data);
        assertEq(amounts.length, 1, "Should have 1 amount");
        assertEq(amounts[0], amount, "Amount should match input");
    }

    /**
     * @notice Fuzz test: SETTLE_PAIR returns consistent arrays
     * @dev Critical: token and amount array lengths must always match
     */
    function testFuzzV4SettlePairArrayLengthsMatch(address token0, address token1) public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(v4Parser.SETTLE_PAIR());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(token0, token1);

        bytes memory unlockData = abi.encode(actions, params);
        bytes memory data = abi.encodeWithSelector(
            v4Parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory tokens = v4Parser.extractInputTokens(address(mockV4PM), data);
        uint256[] memory amounts = v4Parser.extractInputAmounts(address(mockV4PM), data);

        // Critical invariant: lengths must match
        assertEq(tokens.length, amounts.length, "CRITICAL: Array lengths must match");
        assertEq(tokens.length, 2, "Should have 2 tokens");
    }

    /**
     * @notice Fuzz test: MINT_POSITION with various amounts
     * @dev Tests amount decoding from complex params structure
     */
    function testFuzzV4MintPositionAmounts(uint128 amount0Max, uint128 amount1Max) public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(v4Parser.MINT_POSITION());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(
            USDC, WETH, uint24(3000), int24(60), address(0), // PoolKey
            int24(-887220), int24(887220), // tick range
            uint128(1000e6), // liquidity
            uint256(amount0Max), uint256(amount1Max), // max amounts
            USER, // owner
            "" // hookData
        );

        bytes memory unlockData = abi.encode(actions, params);
        bytes memory data = abi.encodeWithSelector(
            v4Parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory tokens = v4Parser.extractInputTokens(address(mockV4PM), data);
        uint256[] memory amounts = v4Parser.extractInputAmounts(address(mockV4PM), data);

        assertEq(tokens.length, amounts.length, "CRITICAL: Array lengths must match");
        assertEq(amounts[0], uint256(amount0Max), "Amount0 should match");
        assertEq(amounts[1], uint256(amount1Max), "Amount1 should match");
    }

    /**
     * @notice Fuzz test: INCREASE_LIQUIDITY amounts
     */
    function testFuzzV4IncreaseLiquidityAmounts(uint256 tokenId, uint128 amount0Max, uint128 amount1Max) public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(v4Parser.INCREASE_LIQUIDITY());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(
            tokenId,           // tokenId
            uint256(1000e6),   // liquidity
            amount0Max,        // amount0Max
            amount1Max,        // amount1Max
            ""                 // hookData
        );

        bytes memory unlockData = abi.encode(actions, params);
        bytes memory data = abi.encodeWithSelector(
            v4Parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory tokens = v4Parser.extractInputTokens(address(mockV4PM), data);
        uint256[] memory amounts = v4Parser.extractInputAmounts(address(mockV4PM), data);

        assertEq(tokens.length, amounts.length, "CRITICAL: Array lengths must match");
        assertEq(amounts[0], uint256(amount0Max), "Amount0 should match");
        assertEq(amounts[1], uint256(amount1Max), "Amount1 should match");
    }

    /**
     * @notice Fuzz test: DECREASE_LIQUIDITY output tokens
     */
    function testFuzzV4DecreaseLiquidityOutputTokens(uint256 tokenId, uint128 liquidity) public view {
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(v4Parser.DECREASE_LIQUIDITY());

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), "");

        bytes memory unlockData = abi.encode(actions, params);
        bytes memory data = abi.encodeWithSelector(
            v4Parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory tokens = v4Parser.extractOutputTokens(address(mockV4PM), data);
        assertEq(tokens.length, 2, "Should have 2 output tokens");
        assertEq(tokens[0], USDC, "Token0 should be USDC");
        assertEq(tokens[1], WETH, "Token1 should be WETH");
    }

    // ============ UniswapV3Parser Fuzz Tests ============

    /**
     * @notice Fuzz test: V3 exactInputSingle amounts
     */
    function testFuzzV3ExactInputSingleAmount(uint256 amountIn, uint256 amountOutMin) public view {
        bytes memory data = abi.encodeWithSelector(
            v3Parser.EXACT_INPUT_SINGLE_SELECTOR(),
            USDC, WETH, uint24(3000), USER, block.timestamp, amountIn, amountOutMin, uint160(0)
        );

        address[] memory tokens = v3Parser.extractInputTokens(address(mockV3PM), data);
        uint256[] memory amounts = v3Parser.extractInputAmounts(address(mockV3PM), data);

        assertEq(tokens.length, amounts.length, "CRITICAL: Array lengths must match");
        assertEq(amounts[0], amountIn, "Amount should match");
    }

    /**
     * @notice Fuzz test: V3 MINT with various amounts
     */
    function testFuzzV3MintAmounts(uint256 amount0Desired, uint256 amount1Desired) public view {
        bytes memory data = abi.encodeWithSelector(
            v3Parser.MINT_SELECTOR(),
            USDC, WETH, uint24(3000), int24(-887220), int24(887220),
            amount0Desired, amount1Desired, uint256(0), uint256(0), USER, block.timestamp
        );

        address[] memory tokens = v3Parser.extractInputTokens(address(mockV3PM), data);
        uint256[] memory amounts = v3Parser.extractInputAmounts(address(mockV3PM), data);

        assertEq(tokens.length, amounts.length, "CRITICAL: Array lengths must match");
        assertEq(tokens.length, 2, "Should have 2 tokens");
        assertEq(amounts[0], amount0Desired, "Amount0 should match");
        assertEq(amounts[1], amount1Desired, "Amount1 should match");
    }

    /**
     * @notice Fuzz test: V3 INCREASE_LIQUIDITY amounts
     */
    function testFuzzV3IncreaseLiquidityAmounts(uint256 tokenId, uint256 amount0Desired, uint256 amount1Desired) public view {
        bytes memory data = abi.encodeWithSelector(
            v3Parser.INCREASE_LIQUIDITY_SELECTOR(),
            tokenId, amount0Desired, amount1Desired, uint256(0), uint256(0), block.timestamp
        );

        address[] memory tokens = v3Parser.extractInputTokens(address(mockV3PM), data);
        uint256[] memory amounts = v3Parser.extractInputAmounts(address(mockV3PM), data);

        assertEq(tokens.length, amounts.length, "CRITICAL: Array lengths must match");
        assertEq(amounts[0], amount0Desired, "Amount0 should match");
        assertEq(amounts[1], amount1Desired, "Amount1 should match");
    }

    /**
     * @notice Fuzz test: V3 DECREASE_LIQUIDITY returns 2 output tokens
     */
    function testFuzzV3DecreaseLiquidityOutputTokens(uint256 tokenId, uint128 liquidity) public view {
        bytes memory data = abi.encodeWithSelector(
            v3Parser.DECREASE_LIQUIDITY_SELECTOR(),
            tokenId, liquidity, uint256(0), uint256(0), block.timestamp
        );

        address[] memory tokens = v3Parser.extractOutputTokens(address(mockV3PM), data);
        assertEq(tokens.length, 2, "Should have 2 output tokens");
    }

    // ============ AaveV3Parser Fuzz Tests ============

    /**
     * @notice Fuzz test: Aave supply amounts
     */
    function testFuzzAaveSupplyAmount(uint256 amount) public view {
        bytes memory data = abi.encodeWithSelector(
            aaveParser.SUPPLY_SELECTOR(),
            USDC, amount, USER, uint16(0)
        );

        address[] memory tokens = aaveParser.extractInputTokens(address(0), data);
        uint256[] memory amounts = aaveParser.extractInputAmounts(address(0), data);

        assertEq(tokens.length, amounts.length, "CRITICAL: Array lengths must match");
        assertEq(amounts[0], amount, "Amount should match");
    }

    /**
     * @notice Fuzz test: Aave repay amounts
     */
    function testFuzzAaveRepayAmount(uint256 amount) public view {
        bytes memory data = abi.encodeWithSelector(
            aaveParser.REPAY_SELECTOR(),
            USDC, amount, uint256(2), USER
        );

        address[] memory tokens = aaveParser.extractInputTokens(address(0), data);
        uint256[] memory amounts = aaveParser.extractInputAmounts(address(0), data);

        assertEq(tokens.length, amounts.length, "CRITICAL: Array lengths must match");
        assertEq(amounts[0], amount, "Amount should match");
    }

    // ============ Universal Router Fuzz Tests ============

    /**
     * @notice Fuzz test: Universal Router V3 swap amounts
     */
    function testFuzzUniversalRouterV3SwapAmount(uint256 amountIn, uint256 amountOutMin) public view {
        // Build V3_SWAP_EXACT_IN command
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(universalParser.V3_SWAP_EXACT_IN());

        // V3 swap params: (address recipient, uint256 amountIn, uint256 amountOutMin, bytes path, bool payerIsUser)
        bytes memory path = abi.encodePacked(USDC, uint24(3000), WETH);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(USER, amountIn, amountOutMin, path, true);

        bytes memory data = abi.encodeWithSelector(
            universalParser.EXECUTE_SELECTOR(),
            commands,
            inputs,
            block.timestamp + 1
        );

        address[] memory tokens = universalParser.extractInputTokens(address(0), data);
        uint256[] memory amounts = universalParser.extractInputAmounts(address(0), data);

        assertEq(tokens.length, amounts.length, "CRITICAL: Array lengths must match");
        if (amounts.length > 0) {
            assertEq(amounts[0], amountIn, "Amount should match");
        }
    }

    // ============ Edge Case Tests ============

    /**
     * @notice Fuzz test: Zero amounts should not cause issues
     */
    function testFuzzZeroAmountsHandled() public view {
        // V4 SETTLE with 0
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(v4Parser.SETTLE());
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(USDC, uint256(0), true);

        bytes memory unlockData = abi.encode(actions, params);
        bytes memory data = abi.encodeWithSelector(
            v4Parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        uint256[] memory amounts = v4Parser.extractInputAmounts(address(mockV4PM), data);
        assertEq(amounts[0], 0, "Zero amount should be handled");
    }

    /**
     * @notice Fuzz test: Max uint256 amounts
     */
    function testFuzzMaxAmountsHandled() public view {
        // V4 SETTLE with max uint256
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(v4Parser.SETTLE());
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(USDC, type(uint256).max, true);

        bytes memory unlockData = abi.encode(actions, params);
        bytes memory data = abi.encodeWithSelector(
            v4Parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        uint256[] memory amounts = v4Parser.extractInputAmounts(address(mockV4PM), data);
        assertEq(amounts[0], type(uint256).max, "Max amount should be handled");
    }

    /**
     * @notice Fuzz test: Random token addresses
     */
    function testFuzzRandomTokenAddresses(address token0, address token1) public view {
        // V4 SETTLE_PAIR with random addresses
        bytes memory actions = new bytes(1);
        actions[0] = bytes1(v4Parser.SETTLE_PAIR());
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(token0, token1);

        bytes memory unlockData = abi.encode(actions, params);
        bytes memory data = abi.encodeWithSelector(
            v4Parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory tokens = v4Parser.extractInputTokens(address(mockV4PM), data);
        assertEq(tokens[0], token0, "Token0 should match");
        assertEq(tokens[1], token1, "Token1 should match");
    }

    // ============ Invariant: Array Lengths Always Match ============

    // ============ Aave Pool Query Tests ============

    /**
     * @notice Fuzz test: Aave supply output tokens (queries pool for aToken)
     */
    function testFuzzAaveSupplyOutputTokens(address asset, uint256 amount) public {
        MockAavePool mockPool = new MockAavePool();
        address aToken = makeAddr("aToken");
        mockPool.setAToken(aToken);

        bytes memory data = abi.encodeWithSelector(
            aaveParser.SUPPLY_SELECTOR(),
            asset, amount, USER, uint16(0)
        );

        address[] memory tokens = aaveParser.extractOutputTokens(address(mockPool), data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], aToken, "Output should be aToken from pool");
    }

    // ============ Stress Tests ============

    /**
     * @notice Stress test: Very large amounts near uint256 max
     */
    function testFuzzStressLargeAmounts(uint256 amount) public view {
        // Bound to large values
        amount = bound(amount, type(uint128).max, type(uint256).max);

        bytes memory data = abi.encodeWithSelector(
            aaveParser.SUPPLY_SELECTOR(),
            USDC, amount, USER, uint16(0)
        );

        uint256[] memory amounts = aaveParser.extractInputAmounts(address(0), data);
        assertEq(amounts[0], amount, "Large amount should be extracted correctly");
    }

    /**
     * @notice Stress test: Boundary values (0, 1, max-1, max)
     */
    function testFuzzBoundaryValues() public view {
        uint256[4] memory testValues = [uint256(0), uint256(1), type(uint256).max - 1, type(uint256).max];

        for (uint256 i = 0; i < testValues.length; i++) {
            bytes memory data = abi.encodeWithSelector(
                aaveParser.SUPPLY_SELECTOR(),
                USDC, testValues[i], USER, uint16(0)
            );

            uint256[] memory amounts = aaveParser.extractInputAmounts(address(0), data);
            assertEq(amounts[0], testValues[i], "Boundary value should be extracted correctly");
        }
    }

    /**
     * @notice Critical invariant: For any valid calldata, token and amount arrays must have same length
     * @dev This is critical for DeFiInteractorModule to not revert with index out of bounds
     */
    function testFuzzInvariantArrayLengthsMatch(uint8 actionType, uint256 amount0, uint256 amount1) public view {
        // Bound action type to valid V4 actions
        actionType = uint8(bound(actionType, 0, 5));

        bytes memory actions = new bytes(1);
        bytes[] memory params = new bytes[](1);

        if (actionType == 0) {
            // INCREASE_LIQUIDITY
            actions[0] = bytes1(v4Parser.INCREASE_LIQUIDITY());
            params[0] = abi.encode(uint256(1), uint256(1000e6), uint128(amount0), uint128(amount1), "");
        } else if (actionType == 1) {
            // MINT_POSITION
            actions[0] = bytes1(v4Parser.MINT_POSITION());
            params[0] = abi.encode(
                USDC, WETH, uint24(3000), int24(60), address(0),
                int24(-887220), int24(887220), uint128(1000e6),
                amount0, amount1, USER, ""
            );
        } else if (actionType == 2) {
            // SETTLE
            actions[0] = bytes1(v4Parser.SETTLE());
            params[0] = abi.encode(USDC, amount0, true);
        } else if (actionType == 3) {
            // SETTLE_PAIR
            actions[0] = bytes1(v4Parser.SETTLE_PAIR());
            params[0] = abi.encode(USDC, WETH);
        } else if (actionType == 4) {
            // DECREASE_LIQUIDITY (no inputs)
            actions[0] = bytes1(v4Parser.DECREASE_LIQUIDITY());
            params[0] = abi.encode(uint256(1), uint128(1000), uint128(0), uint128(0), "");
        } else {
            // TAKE (outputs only)
            actions[0] = bytes1(v4Parser.TAKE());
            params[0] = abi.encode(USDC, USER, amount0);
        }

        bytes memory unlockData = abi.encode(actions, params);
        bytes memory data = abi.encodeWithSelector(
            v4Parser.MODIFY_LIQUIDITIES_SELECTOR(),
            unlockData,
            block.timestamp + 1
        );

        address[] memory tokens = v4Parser.extractInputTokens(address(mockV4PM), data);
        uint256[] memory amounts = v4Parser.extractInputAmounts(address(mockV4PM), data);

        // CRITICAL INVARIANT
        assertEq(tokens.length, amounts.length, "INVARIANT VIOLATED: Array lengths must always match");
    }
}
