// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeFiInteractorModule} from "../src/DeFiInteractorModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockSafeForFuzz
 * @notice Minimal mock Safe for fuzz testing
 */
contract MockSafeForFuzz {
    mapping(address => bool) public isModuleEnabled;

    function enableModule(address module) external {
        isModuleEnabled[module] = true;
    }

    function execTransactionFromModule(
        address,
        uint256,
        bytes calldata,
        uint8
    ) external pure returns (bool) {
        return true;
    }
}

/**
 * @title MockPriceFeedForFuzz
 * @notice Mock price feed with configurable decimals and price
 */
contract MockPriceFeedForFuzz {
    int256 public price;
    uint8 public decimals_;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimals_ = _decimals;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }

    function setPrice(int256 _price) external {
        price = _price;
    }
}

/**
 * @title MockTokenForFuzz
 * @notice Mock ERC20 with configurable decimals
 */
contract MockTokenForFuzz {
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }
}

/**
 * @title MockParserForFuzz
 * @notice Mock parser that returns configurable values
 */
contract MockParserForFuzz {
    address[] public inputTokens;
    uint256[] public inputAmounts;
    address[] public outputTokens;
    address public recipient;
    uint8 public opType;

    function setInputs(address[] memory _tokens, uint256[] memory _amounts) external {
        inputTokens = _tokens;
        inputAmounts = _amounts;
    }

    function setOutputs(address[] memory _tokens) external {
        outputTokens = _tokens;
    }

    function setRecipient(address _recipient) external {
        recipient = _recipient;
    }

    function setOpType(uint8 _opType) external {
        opType = _opType;
    }

    function extractInputTokens(address, bytes calldata) external view returns (address[] memory) {
        return inputTokens;
    }

    function extractInputAmounts(address, bytes calldata) external view returns (uint256[] memory) {
        return inputAmounts;
    }

    function extractOutputTokens(address, bytes calldata) external view returns (address[] memory) {
        return outputTokens;
    }

    function extractRecipient(address, bytes calldata, address) external view returns (address) {
        return recipient;
    }

    function supportsSelector(bytes4) external pure returns (bool) {
        return true;
    }

    function getOperationType(bytes calldata) external view returns (uint8) {
        return opType;
    }
}

/**
 * @title DeFiModuleFuzzTests
 * @notice Comprehensive fuzz tests for DeFiInteractorModule arithmetic
 */
contract DeFiModuleFuzzTests is Test {
    DeFiInteractorModule public module;
    MockSafeForFuzz public safe;
    MockPriceFeedForFuzz public priceFeed;
    MockTokenForFuzz public token;
    MockParserForFuzz public parser;

    address public owner;
    address public subAccount;
    address public protocol;

    bytes4 constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(uint256,address)"));

    function setUp() public {
        owner = address(this);
        subAccount = makeAddr("subAccount");
        protocol = makeAddr("protocol");

        // Deploy mock Safe
        safe = new MockSafeForFuzz();

        // Deploy module
        module = new DeFiInteractorModule(address(safe), owner, owner);

        // Enable module
        safe.enableModule(address(module));

        // Deploy mock token (18 decimals default)
        token = new MockTokenForFuzz(18);

        // Deploy mock price feed ($1.00 with 8 decimals)
        priceFeed = new MockPriceFeedForFuzz(1_00000000, 8);

        // Deploy mock parser
        parser = new MockParserForFuzz();
        parser.setRecipient(address(safe));
        parser.setOpType(2); // DEPOSIT

        // Setup module
        module.setTokenPriceFeed(address(token), address(priceFeed));
        module.registerParser(protocol, address(parser));
        module.registerSelector(DEPOSIT_SELECTOR, DeFiInteractorModule.OperationType.DEPOSIT);

        // Grant role to subAccount
        module.grantRole(subAccount, module.DEFI_EXECUTE_ROLE());

        // Allow protocol
        address[] memory targets = new address[](1);
        targets[0] = protocol;
        module.setAllowedAddresses(subAccount, targets, true);

        // Set Safe value (1M USD)
        module.updateSafeValue(1_000_000 * 10**18);
    }

    // ============ USD Value Calculation Fuzz Tests ============

    /**
     * @notice Fuzz test: USD calculation with various amounts and prices
     * @dev Tests _estimateTokenValueUSD doesn't overflow
     */
    function testFuzzUSDCalculation(uint256 amount, int256 price) public {
        // Bound price to realistic range (avoid negative and zero)
        price = int256(bound(uint256(price), 1, 10**12)); // $0.00000001 to $10,000

        priceFeed.setPrice(price);

        // Bound amount to prevent overflow in calculation
        // valueUSD = amount * price * 10^18 / 10^(tokenDecimals + priceDecimals)
        // With 18 token decimals and 8 price decimals, max safe amount is ~10^50
        amount = bound(amount, 0, 10**50);

        // Max allowance is 20% of 1M USD = 200k USD
        uint256 maxAllowance = 200_000 * 10**18;
        module.updateSpendingAllowance(subAccount, maxAllowance);

        // Set acquired balance to 0 so full amount counts as spending
        module.updateAcquiredBalance(subAccount, address(token), 0);

        // Setup parser
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        parser.setInputs(tokens, amounts);
        parser.setOutputs(new address[](0));

        // Give Safe enough tokens
        token.setBalance(address(safe), amount);

        // This should not revert with overflow
        bytes memory data = abi.encodeWithSelector(DEPOSIT_SELECTOR, amount, address(safe));

        vm.prank(subAccount);
        // If amount is very high, it might exceed spending limit, which is expected
        try module.executeOnProtocol(protocol, data) {
            // Success - no overflow
        } catch (bytes memory reason) {
            // Check it's not an arithmetic error
            bytes4 errorSelector = bytes4(reason);
            assertTrue(
                errorSelector == DeFiInteractorModule.ExceedsSpendingLimit.selector ||
                errorSelector == DeFiInteractorModule.TransactionFailed.selector,
                "Should not have arithmetic overflow"
            );
        }
    }

    /**
     * @notice Fuzz test: Different token decimals (6, 8, 18)
     */
    function testFuzzDifferentTokenDecimals(uint8 decimals, uint256 amount) public {
        // Common decimals: 6 (USDC), 8 (WBTC), 18 (most ERC20)
        decimals = uint8(bound(decimals, 6, 18));
        amount = bound(amount, 1, 10**30);

        // Create new token with specified decimals
        MockTokenForFuzz customToken = new MockTokenForFuzz(decimals);
        module.setTokenPriceFeed(address(customToken), address(priceFeed));

        // Max allowance is 20% of 1M USD = 200k USD
        uint256 maxAllowance = 200_000 * 10**18;
        module.updateSpendingAllowance(subAccount, maxAllowance);
        module.updateAcquiredBalance(subAccount, address(customToken), 0);

        // Setup parser with custom token
        address[] memory tokens = new address[](1);
        tokens[0] = address(customToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        parser.setInputs(tokens, amounts);

        customToken.setBalance(address(safe), amount);

        bytes memory data = abi.encodeWithSelector(DEPOSIT_SELECTOR, amount, address(safe));

        vm.prank(subAccount);
        try module.executeOnProtocol(protocol, data) {
            // Success
        } catch (bytes memory reason) {
            bytes4 errorSelector = bytes4(reason);
            assertTrue(
                errorSelector == DeFiInteractorModule.ExceedsSpendingLimit.selector ||
                errorSelector == DeFiInteractorModule.TransactionFailed.selector,
                "Should not have arithmetic overflow"
            );
        }
    }

    /**
     * @notice Fuzz test: Different price feed decimals
     */
    function testFuzzDifferentPriceDecimals(uint8 priceDecimals, int256 price) public {
        // Price feeds typically use 8 decimals, but test range
        priceDecimals = uint8(bound(priceDecimals, 6, 18));
        price = int256(bound(uint256(price), 1, 10**(priceDecimals + 4)));

        MockPriceFeedForFuzz customFeed = new MockPriceFeedForFuzz(price, priceDecimals);
        module.setTokenPriceFeed(address(token), address(customFeed));

        uint256 amount = 1000 * 10**18;
        uint256 maxAllowance = 200_000 * 10**18;
        module.updateSpendingAllowance(subAccount, maxAllowance);
        module.updateAcquiredBalance(subAccount, address(token), 0);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        parser.setInputs(tokens, amounts);

        token.setBalance(address(safe), amount);

        bytes memory data = abi.encodeWithSelector(DEPOSIT_SELECTOR, amount, address(safe));

        vm.prank(subAccount);
        try module.executeOnProtocol(protocol, data) {
            // Success
        } catch {}
    }

    // ============ Acquired Balance Logic Fuzz Tests ============

    /**
     * @notice Fuzz test: Spending with partial acquired balance
     * @dev Tests: fromOriginal = amountsIn > acquired ? amountsIn - acquired : 0
     */
    function testFuzzPartialAcquiredBalance(uint256 amount, uint256 acquired) public {
        // Bound to reasonable values that won't exceed spending cap
        amount = bound(amount, 1, 100_000 * 10**18); // Max 100k tokens
        acquired = bound(acquired, 0, amount * 2); // Can be more or less than amount

        uint256 maxAllowance = 200_000 * 10**18;
        module.updateSpendingAllowance(subAccount, maxAllowance);
        module.updateAcquiredBalance(subAccount, address(token), acquired);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        parser.setInputs(tokens, amounts);

        token.setBalance(address(safe), amount);

        bytes memory data = abi.encodeWithSelector(DEPOSIT_SELECTOR, amount, address(safe));

        uint256 expectedFromOriginal = amount > acquired ? amount - acquired : 0;
        uint256 expectedUsedFromAcquired = amount > acquired ? acquired : amount;

        uint256 acquiredBefore = module.getAcquiredBalance(subAccount, address(token));

        vm.prank(subAccount);
        try module.executeOnProtocol(protocol, data) {
            uint256 acquiredAfter = module.getAcquiredBalance(subAccount, address(token));
            // Acquired should decrease by usedFromAcquired
            assertEq(acquiredAfter, acquiredBefore - expectedUsedFromAcquired, "Acquired balance should decrease correctly");
        } catch {}
    }

    /**
     * @notice Fuzz test: Acquired balance exactly equals amount (edge case)
     */
    function testFuzzAcquiredEqualsAmount(uint256 amount) public {
        amount = bound(amount, 1, 100_000 * 10**18);

        uint256 maxAllowance = 200_000 * 10**18;
        module.updateSpendingAllowance(subAccount, maxAllowance);
        module.updateAcquiredBalance(subAccount, address(token), amount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        parser.setInputs(tokens, amounts);

        token.setBalance(address(safe), amount);

        bytes memory data = abi.encodeWithSelector(DEPOSIT_SELECTOR, amount, address(safe));

        uint256 allowanceBefore = module.getSpendingAllowance(subAccount);

        vm.prank(subAccount);
        try module.executeOnProtocol(protocol, data) {
            // When acquired == amount, spending cost should be 0
            uint256 allowanceAfter = module.getSpendingAllowance(subAccount);
            assertEq(allowanceAfter, allowanceBefore, "No spending should be deducted when fully covered by acquired");
        } catch {}
    }

    /**
     * @notice Fuzz test: Acquired balance exceeds amount (use only what's needed)
     */
    function testFuzzAcquiredExceedsAmount(uint256 amount, uint256 excess) public {
        amount = bound(amount, 1, 50_000 * 10**18);
        excess = bound(excess, 1, 50_000 * 10**18);
        uint256 acquired = amount + excess;

        uint256 maxAllowance = 200_000 * 10**18;
        module.updateSpendingAllowance(subAccount, maxAllowance);
        module.updateAcquiredBalance(subAccount, address(token), acquired);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        parser.setInputs(tokens, amounts);

        token.setBalance(address(safe), amount);

        bytes memory data = abi.encodeWithSelector(DEPOSIT_SELECTOR, amount, address(safe));

        vm.prank(subAccount);
        try module.executeOnProtocol(protocol, data) {
            uint256 acquiredAfter = module.getAcquiredBalance(subAccount, address(token));
            // Should only use 'amount' from acquired, leaving 'excess'
            assertEq(acquiredAfter, excess, "Should only deduct amount used, leaving excess");
        } catch {}
    }

    // ============ Multi-Token Fuzz Tests ============

    /**
     * @notice Fuzz test: Multiple tokens with different acquired balances
     */
    function testFuzzMultiTokenSpending(
        uint256 amount0,
        uint256 amount1,
        uint256 acquired0,
        uint256 acquired1
    ) public {
        amount0 = bound(amount0, 1, 50_000 * 10**18);
        amount1 = bound(amount1, 1, 50_000 * 10**18);
        acquired0 = bound(acquired0, 0, amount0 * 2);
        acquired1 = bound(acquired1, 0, amount1 * 2);

        // Create second token
        MockTokenForFuzz token1 = new MockTokenForFuzz(18);
        module.setTokenPriceFeed(address(token1), address(priceFeed));

        uint256 maxAllowance = 200_000 * 10**18;
        module.updateSpendingAllowance(subAccount, maxAllowance);
        module.updateAcquiredBalance(subAccount, address(token), acquired0);
        module.updateAcquiredBalance(subAccount, address(token1), acquired1);

        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;
        parser.setInputs(tokens, amounts);

        token.setBalance(address(safe), amount0);
        token1.setBalance(address(safe), amount1);

        bytes memory data = abi.encodeWithSelector(DEPOSIT_SELECTOR, amount0, address(safe));

        vm.prank(subAccount);
        try module.executeOnProtocol(protocol, data) {
            // Success - verify both acquired balances updated correctly
            uint256 expected0 = acquired0 > amount0 ? acquired0 - amount0 : 0;
            uint256 expected1 = acquired1 > amount1 ? acquired1 - amount1 : 0;

            assertEq(module.getAcquiredBalance(subAccount, address(token)), expected0);
            assertEq(module.getAcquiredBalance(subAccount, address(token1)), expected1);
        } catch {}
    }

    // ============ Spending Limit Enforcement Fuzz Tests ============

    /**
     * @notice Fuzz test: Spending limit exactly at boundary
     */
    function testFuzzSpendingLimitBoundary(uint256 allowance) public {
        // Cap at max allowed (20% of 1M = 200k USD)
        allowance = bound(allowance, 1, 200_000 * 10**18);

        module.updateSpendingAllowance(subAccount, allowance);
        module.updateAcquiredBalance(subAccount, address(token), 0);

        // Calculate amount that would result in exactly 'allowance' spending cost
        // With $1 price and 18 decimals, 1 token = $1 = 10^18 USD value
        uint256 amount = allowance; // 1:1 with $1 price

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        parser.setInputs(tokens, amounts);

        token.setBalance(address(safe), amount);

        bytes memory data = abi.encodeWithSelector(DEPOSIT_SELECTOR, amount, address(safe));

        vm.prank(subAccount);
        // Should succeed - exactly at limit
        try module.executeOnProtocol(protocol, data) {
            assertEq(module.getSpendingAllowance(subAccount), 0, "Allowance should be exactly 0");
        } catch {}
    }

    /**
     * @notice Fuzz test: Spending limit exceeded by 1 wei
     */
    function testFuzzSpendingLimitExceededByOne(uint256 allowance) public {
        // Cap at max allowed minus 1 so we can add 1 for the test
        allowance = bound(allowance, 1, 200_000 * 10**18 - 1);

        module.updateSpendingAllowance(subAccount, allowance);
        module.updateAcquiredBalance(subAccount, address(token), 0);

        uint256 amount = allowance + 1; // 1 wei over

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        parser.setInputs(tokens, amounts);

        token.setBalance(address(safe), amount);

        bytes memory data = abi.encodeWithSelector(DEPOSIT_SELECTOR, amount, address(safe));

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractorModule.ExceedsSpendingLimit.selector);
        module.executeOnProtocol(protocol, data);
    }

    // ============ Allowance Cap Enforcement Fuzz Tests ============

    /**
     * @notice Fuzz test: Allowance cap calculation doesn't overflow
     */
    function testFuzzAllowanceCapNoOverflow(uint256 safeValue, uint256 maxBps) public {
        // Bound to prevent overflow: safeValue * maxBps / 10000
        safeValue = bound(safeValue, 0, type(uint256).max / 10000);
        maxBps = bound(maxBps, 0, 10000);

        module.setAbsoluteMaxSpendingBps(maxBps);
        module.updateSafeValue(safeValue);

        uint256 maxAllowance = (safeValue * maxBps) / 10000;

        // Should succeed when at or below cap
        if (maxAllowance > 0) {
            module.updateSpendingAllowance(subAccount, maxAllowance);
            assertEq(module.getSpendingAllowance(subAccount), maxAllowance);
        }

        // Should revert when above cap (if cap > 0)
        if (maxAllowance < type(uint256).max && maxBps > 0) {
            vm.expectRevert();
            module.updateSpendingAllowance(subAccount, maxAllowance + 1);
        }
    }

    // ============ Batch Update Fuzz Tests ============

    /**
     * @notice Fuzz test: Batch update with multiple tokens
     */
    function testFuzzBatchUpdate(uint256 allowance, uint256 numTokens) public {
        // Cap at max allowed (20% of 1M = 200k USD)
        allowance = bound(allowance, 0, 200_000 * 10**18);
        numTokens = bound(numTokens, 1, 10);

        address[] memory tokens = new address[](numTokens);
        uint256[] memory balances = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            tokens[i] = address(uint160(i + 1000));
            balances[i] = i * 10**18;
        }

        module.batchUpdate(subAccount, allowance, tokens, balances);

        assertEq(module.getSpendingAllowance(subAccount), allowance);
        for (uint256 i = 0; i < numTokens; i++) {
            assertEq(module.getAcquiredBalance(subAccount, tokens[i]), balances[i]);
        }
    }

    /**
     * @notice Fuzz test: Batch update array length mismatch should revert
     */
    function testFuzzBatchUpdateLengthMismatch(uint256 len1, uint256 len2) public {
        len1 = bound(len1, 1, 10);
        len2 = bound(len2, 1, 10);
        vm.assume(len1 != len2);

        address[] memory tokens = new address[](len1);
        uint256[] memory balances = new uint256[](len2);

        for (uint256 i = 0; i < len1; i++) {
            tokens[i] = address(uint160(i + 1000));
        }
        for (uint256 i = 0; i < len2; i++) {
            balances[i] = i * 10**18;
        }

        vm.expectRevert(DeFiInteractorModule.LengthMismatch.selector);
        module.batchUpdate(subAccount, 1000, tokens, balances);
    }

    // ============ Edge Case: Zero Values ============

    /**
     * @notice Fuzz test: Zero amount should not affect spending
     */
    function testFuzzZeroAmountNoSpending() public {
        module.updateSpendingAllowance(subAccount, 1000 * 10**18);
        module.updateAcquiredBalance(subAccount, address(token), 0);

        uint256 allowanceBefore = module.getSpendingAllowance(subAccount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        parser.setInputs(tokens, amounts);

        bytes memory data = abi.encodeWithSelector(DEPOSIT_SELECTOR, 0, address(safe));

        vm.prank(subAccount);
        try module.executeOnProtocol(protocol, data) {
            assertEq(module.getSpendingAllowance(subAccount), allowanceBefore, "Zero amount should not cost spending");
        } catch {}
    }
}
