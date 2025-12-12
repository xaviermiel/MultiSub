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
    uint256 public exchangeRate; // assets per share (scaled by 1e18)

    constructor(address _asset) {
        asset = _asset;
        exchangeRate = 1e18; // 1:1 by default
    }

    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    /// @notice Preview how many assets are needed to mint `shares`
    function previewMint(uint256 shares) external view returns (uint256) {
        return (shares * exchangeRate) / 1e18;
    }

    /// @notice Preview how many shares are received for `assets`
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / exchangeRate;
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

        // With 1:1 exchange rate, assets = shares
        uint256 amount = parser.extractInputAmount(address(vault), data);
        assertEq(amount, 1000e18, "Input amount should be assets (converted from shares)");
    }

    function testMintExtractInputAmountWithExchangeRate() public {
        // Set exchange rate to 2:1 (2 assets per share)
        vault.setExchangeRate(2e18);

        bytes memory data = abi.encodeWithSelector(
            parser.MINT_SELECTOR(),
            1000e18, // shares
            USER
        );

        // With 2:1 exchange rate, 1000 shares = 2000 assets
        uint256 amount = parser.extractInputAmount(address(vault), data);
        assertEq(amount, 2000e18, "Input amount should be 2x shares with 2:1 rate");
    }

    // ============ Withdraw Tests ============

    function testWithdrawExtractOutputTokens() public view {
        // withdraw(uint256 assets, address receiver, address owner)
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_SELECTOR(),
            1000e6,
            USER,
            OWNER
        );

        address[] memory tokens = parser.extractOutputTokens(address(vault), data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], USDC, "Output token should be vault's underlying asset");
    }

    // ============ Redeem Tests ============

    function testRedeemExtractOutputTokens() public view {
        // redeem(uint256 shares, address receiver, address owner)
        bytes memory data = abi.encodeWithSelector(
            parser.REDEEM_SELECTOR(),
            1000e18, // shares
            USER,
            OWNER
        );

        address[] memory tokens = parser.extractOutputTokens(address(vault), data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], USDC, "Output token should be vault's underlying asset");
    }

    // ============ Operation Type Tests ============

    function testGetOperationType() public view {
        // Helper to create minimal calldata from selector
        bytes memory depositData = abi.encodeWithSelector(parser.DEPOSIT_SELECTOR());
        bytes memory mintData = abi.encodeWithSelector(parser.MINT_SELECTOR());
        bytes memory withdrawData = abi.encodeWithSelector(parser.WITHDRAW_SELECTOR());
        bytes memory redeemData = abi.encodeWithSelector(parser.REDEEM_SELECTOR());
        bytes memory unknownData = abi.encodeWithSelector(bytes4(0xdeadbeef));

        // DEPOSIT operations
        assertEq(parser.getOperationType(depositData), 2, "Deposit should be DEPOSIT (2)");
        assertEq(parser.getOperationType(mintData), 2, "Mint should be DEPOSIT (2)");

        // WITHDRAW operations
        assertEq(parser.getOperationType(withdrawData), 3, "Withdraw should be WITHDRAW (3)");
        assertEq(parser.getOperationType(redeemData), 3, "Redeem should be WITHDRAW (3)");

        // Unknown
        assertEq(parser.getOperationType(unknownData), 0, "Unknown should return 0");
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

    function testUnsupportedSelectorRevertsOnOutputTokens() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(MorphoParser.UnsupportedSelector.selector);
        parser.extractOutputTokens(address(vault), badData);
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

    function testDepositExtractOutputTokens() public view {
        // Deposit output is vault shares (the vault token itself)
        bytes memory data = abi.encodeWithSelector(
            parser.DEPOSIT_SELECTOR(),
            1000e6,
            USER
        );

        address[] memory tokens = parser.extractOutputTokens(address(vault), data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], address(vault), "Output token should be vault shares (vault address)");
    }

    function testMintExtractOutputTokens() public view {
        // Mint output is vault shares (the vault token itself)
        bytes memory data = abi.encodeWithSelector(
            parser.MINT_SELECTOR(),
            1000e18,
            USER
        );

        address[] memory tokens = parser.extractOutputTokens(address(vault), data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], address(vault), "Output token should be vault shares (vault address)");
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
        // Bound shares to avoid overflow in previewMint calculation (shares * exchangeRate / 1e18)
        // With 1e18 exchange rate (1:1), max safe shares is type(uint256).max
        // But with higher rates, need to bound. Max safe is ~type(uint256).max / 2e18
        shares = bound(shares, 0, type(uint128).max);

        bytes memory data = abi.encodeWithSelector(
            parser.MINT_SELECTOR(),
            shares,
            USER
        );

        // With 1:1 exchange rate, extracted amount equals shares
        uint256 extracted = parser.extractInputAmount(address(vault), data);
        assertEq(extracted, shares, "Should extract shares correctly with 1:1 rate");
    }
}
