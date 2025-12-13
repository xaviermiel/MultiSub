// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MorphoBlueParser} from "../src/parsers/MorphoBlueParser.sol";
import {IMorphoBlue} from "../src/interfaces/IMorphoBlue.sol";

/**
 * @title MorphoBlueParserTest
 * @notice Tests for the Morpho Blue parser
 */
contract MorphoBlueParserTest is Test {
    MorphoBlueParser public parser;

    // Test addresses
    address constant MORPHO_BLUE = 0xd011EE229E7459ba1ddd22631eF7bF528d424A14;
    address constant LOAN_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address constant COLLATERAL_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address constant ORACLE = address(0x1111);
    address constant IRM = address(0x2222);
    uint256 constant LLTV = 860000000000000000; // 86%
    address constant USER = address(0x1234);
    address constant RECEIVER = address(0x5678);

    // MarketParams for testing
    IMorphoBlue.MarketParams marketParams;

    function setUp() public {
        parser = new MorphoBlueParser();
        marketParams = IMorphoBlue.MarketParams({
            loanToken: LOAN_TOKEN,
            collateralToken: COLLATERAL_TOKEN,
            oracle: ORACLE,
            irm: IRM,
            lltv: LLTV
        });
    }

    // ============ Selector Tests ============

    function testSelectors() public view {
        assertEq(parser.SUPPLY_SELECTOR(), bytes4(0xa99aad89), "Supply selector mismatch");
        assertEq(parser.WITHDRAW_SELECTOR(), bytes4(0x5c2bea49), "Withdraw selector mismatch");
        assertEq(parser.BORROW_SELECTOR(), bytes4(0x50d8cd4b), "Borrow selector mismatch");
        assertEq(parser.REPAY_SELECTOR(), bytes4(0x20b76e81), "Repay selector mismatch");
        assertEq(parser.SUPPLY_COLLATERAL_SELECTOR(), bytes4(0x238d6579), "SupplyCollateral selector mismatch");
        assertEq(parser.WITHDRAW_COLLATERAL_SELECTOR(), bytes4(0x8720316d), "WithdrawCollateral selector mismatch");
    }

    function testSupportsSelector() public view {
        assertTrue(parser.supportsSelector(parser.SUPPLY_SELECTOR()), "Should support supply");
        assertTrue(parser.supportsSelector(parser.WITHDRAW_SELECTOR()), "Should support withdraw");
        assertFalse(parser.supportsSelector(parser.BORROW_SELECTOR()), "Should NOT support borrow");
        assertTrue(parser.supportsSelector(parser.REPAY_SELECTOR()), "Should support repay");
        assertTrue(parser.supportsSelector(parser.SUPPLY_COLLATERAL_SELECTOR()), "Should support supplyCollateral");
        assertTrue(parser.supportsSelector(parser.WITHDRAW_COLLATERAL_SELECTOR()), "Should support withdrawCollateral");
        assertFalse(parser.supportsSelector(bytes4(0xdeadbeef)), "Should not support unknown");
    }

    // ============ Supply Tests ============

    function testSupplyExtractInputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            marketParams,
            1000e6,  // assets
            0,       // shares
            USER,    // onBehalf
            ""       // data
        );

        address[] memory tokens = parser.extractInputTokens(MORPHO_BLUE, data);
        assertEq(tokens.length, 1, "Should have 1 input token");
        assertEq(tokens[0], LOAN_TOKEN, "Input token should be loanToken");
    }

    function testSupplyExtractInputAmounts() public view {
        uint256 supplyAmount = 1000e6;
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            marketParams,
            supplyAmount,
            0,
            USER,
            ""
        );

        uint256[] memory amounts = parser.extractInputAmounts(MORPHO_BLUE, data);
        assertEq(amounts.length, 1, "Should have 1 input amount");
        assertEq(amounts[0], supplyAmount, "Input amount should match");
    }

    function testSupplyExtractOutputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            marketParams,
            1000e6,
            0,
            USER,
            ""
        );

        address[] memory tokens = parser.extractOutputTokens(MORPHO_BLUE, data);
        assertEq(tokens.length, 0, "Supply should have no output tokens");
    }

    function testSupplyExtractRecipient() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            marketParams,
            1000e6,
            0,
            USER,
            ""
        );

        address recipient = parser.extractRecipient(MORPHO_BLUE, data, address(0));
        assertEq(recipient, USER, "Recipient should be onBehalf");
    }

    function testSupplyOperationType() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            marketParams,
            1000e6,
            0,
            USER,
            ""
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 2, "Supply should be DEPOSIT (2)");
    }

    // ============ Withdraw Tests ============

    function testWithdrawExtractInputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_SELECTOR(),
            marketParams,
            1000e6,  // assets
            0,       // shares
            USER,    // onBehalf
            RECEIVER // receiver
        );

        address[] memory tokens = parser.extractInputTokens(MORPHO_BLUE, data);
        assertEq(tokens.length, 0, "Withdraw should have no input tokens");
    }

    function testWithdrawExtractOutputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_SELECTOR(),
            marketParams,
            1000e6,
            0,
            USER,
            RECEIVER
        );

        address[] memory tokens = parser.extractOutputTokens(MORPHO_BLUE, data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], LOAN_TOKEN, "Output token should be loanToken");
    }

    function testWithdrawExtractRecipient() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_SELECTOR(),
            marketParams,
            1000e6,
            0,
            USER,
            RECEIVER
        );

        address recipient = parser.extractRecipient(MORPHO_BLUE, data, address(0));
        assertEq(recipient, RECEIVER, "Recipient should be receiver");
    }

    function testWithdrawOperationType() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_SELECTOR(),
            marketParams,
            1000e6,
            0,
            USER,
            RECEIVER
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 3, "Withdraw should be WITHDRAW (3)");
    }

    // ============ Borrow Tests (Intentionally Not Supported) ============

    function testBorrowRevertsExtractInputTokens() public {
        bytes memory data = abi.encodeWithSelector(
            parser.BORROW_SELECTOR(),
            marketParams,
            500e6,
            0,
            USER,
            RECEIVER
        );

        vm.expectRevert(MorphoBlueParser.UnsupportedSelector.selector);
        parser.extractInputTokens(MORPHO_BLUE, data);
    }

    function testBorrowRevertsExtractInputAmounts() public {
        bytes memory data = abi.encodeWithSelector(
            parser.BORROW_SELECTOR(),
            marketParams,
            500e6,
            0,
            USER,
            RECEIVER
        );

        vm.expectRevert(MorphoBlueParser.UnsupportedSelector.selector);
        parser.extractInputAmounts(MORPHO_BLUE, data);
    }

    function testBorrowRevertsExtractOutputTokens() public {
        bytes memory data = abi.encodeWithSelector(
            parser.BORROW_SELECTOR(),
            marketParams,
            500e6,
            0,
            USER,
            RECEIVER
        );

        vm.expectRevert(MorphoBlueParser.UnsupportedSelector.selector);
        parser.extractOutputTokens(MORPHO_BLUE, data);
    }

    function testBorrowRevertsExtractRecipient() public {
        bytes memory data = abi.encodeWithSelector(
            parser.BORROW_SELECTOR(),
            marketParams,
            500e6,
            0,
            USER,
            RECEIVER
        );

        vm.expectRevert(MorphoBlueParser.UnsupportedSelector.selector);
        parser.extractRecipient(MORPHO_BLUE, data, address(0));
    }

    function testBorrowOperationTypeReturnsUnknown() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.BORROW_SELECTOR(),
            marketParams,
            500e6,
            0,
            USER,
            RECEIVER
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 0, "Borrow should return UNKNOWN (0) as it's not supported");
    }

    // ============ Repay Tests ============

    function testRepayExtractInputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.REPAY_SELECTOR(),
            marketParams,
            500e6,
            0,
            USER,
            ""
        );

        address[] memory tokens = parser.extractInputTokens(MORPHO_BLUE, data);
        assertEq(tokens.length, 1, "Should have 1 input token");
        assertEq(tokens[0], LOAN_TOKEN, "Input token should be loanToken");
    }

    function testRepayExtractInputAmounts() public view {
        uint256 repayAmount = 500e6;
        bytes memory data = abi.encodeWithSelector(
            parser.REPAY_SELECTOR(),
            marketParams,
            repayAmount,
            0,
            USER,
            ""
        );

        uint256[] memory amounts = parser.extractInputAmounts(MORPHO_BLUE, data);
        assertEq(amounts.length, 1, "Should have 1 input amount");
        assertEq(amounts[0], repayAmount, "Input amount should match");
    }

    function testRepayExtractOutputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.REPAY_SELECTOR(),
            marketParams,
            500e6,
            0,
            USER,
            ""
        );

        address[] memory tokens = parser.extractOutputTokens(MORPHO_BLUE, data);
        assertEq(tokens.length, 0, "Repay should have no output tokens");
    }

    function testRepayOperationType() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.REPAY_SELECTOR(),
            marketParams,
            500e6,
            0,
            USER,
            ""
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 2, "Repay should be DEPOSIT (2)");
    }

    // ============ SupplyCollateral Tests ============

    function testSupplyCollateralExtractInputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_COLLATERAL_SELECTOR(),
            marketParams,
            1e18,   // assets (1 WETH)
            USER,   // onBehalf
            ""      // data
        );

        address[] memory tokens = parser.extractInputTokens(MORPHO_BLUE, data);
        assertEq(tokens.length, 1, "Should have 1 input token");
        assertEq(tokens[0], COLLATERAL_TOKEN, "Input token should be collateralToken");
    }

    function testSupplyCollateralExtractInputAmounts() public view {
        uint256 collateralAmount = 1e18;
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_COLLATERAL_SELECTOR(),
            marketParams,
            collateralAmount,
            USER,
            ""
        );

        uint256[] memory amounts = parser.extractInputAmounts(MORPHO_BLUE, data);
        assertEq(amounts.length, 1, "Should have 1 input amount");
        assertEq(amounts[0], collateralAmount, "Input amount should match");
    }

    function testSupplyCollateralExtractRecipient() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_COLLATERAL_SELECTOR(),
            marketParams,
            1e18,
            USER,
            ""
        );

        address recipient = parser.extractRecipient(MORPHO_BLUE, data, address(0));
        assertEq(recipient, USER, "Recipient should be onBehalf");
    }

    function testSupplyCollateralOperationType() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_COLLATERAL_SELECTOR(),
            marketParams,
            1e18,
            USER,
            ""
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 2, "SupplyCollateral should be DEPOSIT (2)");
    }

    // ============ WithdrawCollateral Tests ============

    function testWithdrawCollateralExtractInputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_COLLATERAL_SELECTOR(),
            marketParams,
            1e18,
            USER,
            RECEIVER
        );

        address[] memory tokens = parser.extractInputTokens(MORPHO_BLUE, data);
        assertEq(tokens.length, 0, "WithdrawCollateral should have no input tokens");
    }

    function testWithdrawCollateralExtractOutputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_COLLATERAL_SELECTOR(),
            marketParams,
            1e18,
            USER,
            RECEIVER
        );

        address[] memory tokens = parser.extractOutputTokens(MORPHO_BLUE, data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], COLLATERAL_TOKEN, "Output token should be collateralToken");
    }

    function testWithdrawCollateralExtractRecipient() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_COLLATERAL_SELECTOR(),
            marketParams,
            1e18,
            USER,
            RECEIVER
        );

        address recipient = parser.extractRecipient(MORPHO_BLUE, data, address(0));
        assertEq(recipient, RECEIVER, "Recipient should be receiver");
    }

    function testWithdrawCollateralOperationType() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_COLLATERAL_SELECTOR(),
            marketParams,
            1e18,
            USER,
            RECEIVER
        );

        uint8 opType = parser.getOperationType(data);
        assertEq(opType, 3, "WithdrawCollateral should be WITHDRAW (3)");
    }

    // ============ Edge Cases ============

    function testUnsupportedSelector() public {
        bytes memory data = abi.encodeWithSelector(bytes4(0xdeadbeef));

        vm.expectRevert(MorphoBlueParser.UnsupportedSelector.selector);
        parser.extractInputTokens(MORPHO_BLUE, data);
    }

    function testDefaultRecipientWhenZero() public view {
        // Create data where recipient would be address(0)
        IMorphoBlue.MarketParams memory params = IMorphoBlue.MarketParams({
            loanToken: LOAN_TOKEN,
            collateralToken: COLLATERAL_TOKEN,
            oracle: ORACLE,
            irm: IRM,
            lltv: LLTV
        });

        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            params,
            1000e6,
            0,
            address(0), // zero onBehalf
            ""
        );

        address defaultAddr = address(0x9999);
        address recipient = parser.extractRecipient(MORPHO_BLUE, data, defaultAddr);
        assertEq(recipient, defaultAddr, "Should use default when recipient is zero");
    }

    // ============ Fuzz Tests ============

    function testFuzzSupply(uint256 assets, address onBehalf) public view {
        vm.assume(onBehalf != address(0));
        vm.assume(assets > 0 && assets < type(uint128).max);

        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            marketParams,
            assets,
            0,
            onBehalf,
            ""
        );

        address[] memory tokens = parser.extractInputTokens(MORPHO_BLUE, data);
        uint256[] memory amounts = parser.extractInputAmounts(MORPHO_BLUE, data);
        address recipient = parser.extractRecipient(MORPHO_BLUE, data, address(0));

        assertEq(tokens[0], LOAN_TOKEN);
        assertEq(amounts[0], assets);
        assertEq(recipient, onBehalf);
    }

    function testFuzzWithdraw(uint256 assets, address receiver) public view {
        vm.assume(receiver != address(0));
        vm.assume(assets > 0 && assets < type(uint128).max);

        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_SELECTOR(),
            marketParams,
            assets,
            0,
            USER,
            receiver
        );

        address[] memory tokens = parser.extractOutputTokens(MORPHO_BLUE, data);
        address recipient = parser.extractRecipient(MORPHO_BLUE, data, address(0));

        assertEq(tokens[0], LOAN_TOKEN);
        assertEq(recipient, receiver);
    }

    function testFuzzSupplyCollateral(uint256 assets, address onBehalf) public view {
        vm.assume(onBehalf != address(0));
        vm.assume(assets > 0 && assets < type(uint128).max);

        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_COLLATERAL_SELECTOR(),
            marketParams,
            assets,
            onBehalf,
            ""
        );

        address[] memory tokens = parser.extractInputTokens(MORPHO_BLUE, data);
        uint256[] memory amounts = parser.extractInputAmounts(MORPHO_BLUE, data);
        address recipient = parser.extractRecipient(MORPHO_BLUE, data, address(0));

        assertEq(tokens[0], COLLATERAL_TOKEN);
        assertEq(amounts[0], assets);
        assertEq(recipient, onBehalf);
    }
}
