// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MorphoParser} from "../src/parsers/MorphoParser.sol";

/**
 * @title MockMorphoVault
 * @notice Mock ERC4626 vault for testing
 */
contract MockMorphoVault {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }
}

/**
 * @title MorphoParserTest
 * @notice Tests for the Morpho Vault (ERC4626) parser
 */
contract MorphoParserTest is Test {
    MorphoParser public parser;
    MockMorphoVault public vault;

    // Test addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USER = address(0x1234);
    address constant OWNER = address(0x5678);

    function setUp() public {
        parser = new MorphoParser();
        vault = new MockMorphoVault(USDC);
    }

    // ============ Selector Tests ============

    function testSelectors() public view {
        assertEq(parser.DEPOSIT_SELECTOR(), bytes4(0x6e553f65), "Deposit selector mismatch");
        assertEq(parser.MINT_SELECTOR(), bytes4(0x94bf804d), "Mint selector mismatch");
        assertEq(parser.WITHDRAW_SELECTOR(), bytes4(0xb460af94), "Withdraw selector mismatch");
        assertEq(parser.REDEEM_SELECTOR(), bytes4(0xba087652), "Redeem selector mismatch");
    }

    function testSupportsSelector() public view {
        assertTrue(parser.supportsSelector(parser.DEPOSIT_SELECTOR()), "Should support deposit");
        assertTrue(parser.supportsSelector(parser.MINT_SELECTOR()), "Should support mint");
        assertTrue(parser.supportsSelector(parser.WITHDRAW_SELECTOR()), "Should support withdraw");
        assertTrue(parser.supportsSelector(parser.REDEEM_SELECTOR()), "Should support redeem");
        assertFalse(parser.supportsSelector(bytes4(0xdeadbeef)), "Should not support unknown");
    }

    // ============ Deposit Tests ============

    function testDepositExtractInputToken() public view {
        // deposit(uint256 assets, address receiver)
        bytes memory data = abi.encodeWithSelector(
            parser.DEPOSIT_SELECTOR(),
            1000e6,
            USER
        );

        address token = parser.extractInputToken(address(vault), data);
        assertEq(token, USDC, "Input token should be vault's underlying asset");
    }

    function testDepositExtractInputAmount() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.DEPOSIT_SELECTOR(),
            1000e6,
            USER
        );

        uint256 amount = parser.extractInputAmount(address(vault), data);
        assertEq(amount, 1000e6, "Input amount should be 1000e6");
    }

    // ============ Mint Tests ============

    function testMintExtractInputToken() public view {
        // mint(uint256 shares, address receiver)
        bytes memory data = abi.encodeWithSelector(
            parser.MINT_SELECTOR(),
            1000e18, // shares
            USER
        );

        address token = parser.extractInputToken(address(vault), data);
        assertEq(token, USDC, "Input token should be vault's underlying asset");
    }

    function testMintExtractInputAmount() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.MINT_SELECTOR(),
            1000e18, // shares
            USER
        );

        uint256 amount = parser.extractInputAmount(address(vault), data);
        assertEq(amount, 1000e18, "Input amount should be shares amount");
    }

    // ============ Withdraw Tests ============

    function testWithdrawExtractOutputToken() public view {
        // withdraw(uint256 assets, address receiver, address owner)
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_SELECTOR(),
            1000e6,
            USER,
            OWNER
        );

        address token = parser.extractOutputToken(address(vault), data);
        assertEq(token, USDC, "Output token should be vault's underlying asset");
    }

    // ============ Redeem Tests ============

    function testRedeemExtractOutputToken() public view {
        // redeem(uint256 shares, address receiver, address owner)
        bytes memory data = abi.encodeWithSelector(
            parser.REDEEM_SELECTOR(),
            1000e18, // shares
            USER,
            OWNER
        );

        address token = parser.extractOutputToken(address(vault), data);
        assertEq(token, USDC, "Output token should be vault's underlying asset");
    }

    // ============ Operation Type Tests ============

    function testGetOperationType() public view {
        // DEPOSIT operations
        assertEq(parser.getOperationType(parser.DEPOSIT_SELECTOR()), 2, "Deposit should be DEPOSIT (2)");
        assertEq(parser.getOperationType(parser.MINT_SELECTOR()), 2, "Mint should be DEPOSIT (2)");

        // WITHDRAW operations
        assertEq(parser.getOperationType(parser.WITHDRAW_SELECTOR()), 3, "Withdraw should be WITHDRAW (3)");
        assertEq(parser.getOperationType(parser.REDEEM_SELECTOR()), 3, "Redeem should be WITHDRAW (3)");

        // Unknown
        assertEq(parser.getOperationType(bytes4(0xdeadbeef)), 0, "Unknown should return 0");
    }

    // ============ Revert Tests ============

    function testUnsupportedSelectorRevertsOnInputToken() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(MorphoParser.UnsupportedSelector.selector);
        parser.extractInputToken(address(vault), badData);
    }

    function testUnsupportedSelectorRevertsOnInputAmount() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(MorphoParser.UnsupportedSelector.selector);
        parser.extractInputAmount(address(vault), badData);
    }

    function testUnsupportedSelectorRevertsOnOutputToken() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(MorphoParser.UnsupportedSelector.selector);
        parser.extractOutputToken(address(vault), badData);
    }

    function testWithdrawRevertsOnInputToken() public {
        // Withdraw is not a valid input operation
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_SELECTOR(),
            1000e6,
            USER,
            OWNER
        );

        vm.expectRevert(MorphoParser.UnsupportedSelector.selector);
        parser.extractInputToken(address(vault), data);
    }

    function testDepositRevertsOnOutputToken() public {
        // Deposit is not a valid output operation
        bytes memory data = abi.encodeWithSelector(
            parser.DEPOSIT_SELECTOR(),
            1000e6,
            USER
        );

        vm.expectRevert(MorphoParser.UnsupportedSelector.selector);
        parser.extractOutputToken(address(vault), data);
    }

    // ============ Different Asset Tests ============

    function testDifferentVaultAsset() public {
        address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        MockMorphoVault wethVault = new MockMorphoVault(WETH);

        bytes memory data = abi.encodeWithSelector(
            parser.DEPOSIT_SELECTOR(),
            1e18,
            USER
        );

        address token = parser.extractInputToken(address(wethVault), data);
        assertEq(token, WETH, "Should return WETH as underlying asset");
    }

    // ============ Fuzz Tests ============

    function testFuzzDepositAmount(uint256 amount) public view {
        bytes memory data = abi.encodeWithSelector(
            parser.DEPOSIT_SELECTOR(),
            amount,
            USER
        );

        uint256 extracted = parser.extractInputAmount(address(vault), data);
        assertEq(extracted, amount, "Should extract any amount correctly");
    }

    function testFuzzMintShares(uint256 shares) public view {
        bytes memory data = abi.encodeWithSelector(
            parser.MINT_SELECTOR(),
            shares,
            USER
        );

        uint256 extracted = parser.extractInputAmount(address(vault), data);
        assertEq(extracted, shares, "Should extract any shares amount correctly");
    }
}
