// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerklParser} from "../src/parsers/MerklParser.sol";

/**
 * @title MerklParserTest
 * @notice Tests for the Merkl Distributor parser
 */
contract MerklParserTest is Test {
    MerklParser public parser;

    // Test addresses
    address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;
    address constant USER = address(0x1234);
    address constant TOKEN_A = address(0xAAAA);
    address constant TOKEN_B = address(0xBBBB);

    function setUp() public {
        parser = new MerklParser();
    }

    function testClaimSelector() public view {
        // Verify the claim selector matches
        bytes4 expectedSelector = bytes4(keccak256("claim(address[],address[],uint256[],bytes32[][])"));
        assertEq(parser.CLAIM_SELECTOR(), expectedSelector, "Claim selector mismatch");
        assertEq(parser.CLAIM_SELECTOR(), bytes4(0x71ee95c0), "Claim selector value mismatch");
    }

    function testSupportsSelector() public view {
        assertTrue(parser.supportsSelector(parser.CLAIM_SELECTOR()), "Should support claim selector");
        assertFalse(parser.supportsSelector(bytes4(0xdeadbeef)), "Should not support random selector");
    }

    function testExtractInputTokenReturnsZero() public view {
        // Build claim calldata
        bytes memory data = _buildClaimCalldata();

        // Claim operations have no input token
        address inputToken = parser.extractInputToken(MERKL_DISTRIBUTOR, data);
        assertEq(inputToken, address(0), "Input token should be zero for claims");
    }

    function testExtractInputAmountReturnsZero() public view {
        bytes memory data = _buildClaimCalldata();

        // Claim operations have no input amount (no spending)
        uint256 inputAmount = parser.extractInputAmount(MERKL_DISTRIBUTOR, data);
        assertEq(inputAmount, 0, "Input amount should be zero for claims");
    }

    function testExtractOutputTokenSingleToken() public view {
        bytes memory data = _buildClaimCalldata();

        // Should return the first token from the tokens array
        address outputToken = parser.extractOutputToken(MERKL_DISTRIBUTOR, data);
        assertEq(outputToken, TOKEN_A, "Output token should be first token in array");
    }

    function testExtractOutputTokenMultipleTokens() public view {
        // Build calldata with multiple tokens
        address[] memory users = new address[](2);
        users[0] = USER;
        users[1] = USER;

        address[] memory tokens = new address[](2);
        tokens[0] = TOKEN_A;
        tokens[1] = TOKEN_B;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = keccak256("proof1");
        proofs[1] = new bytes32[](1);
        proofs[1][0] = keccak256("proof2");

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_SELECTOR(),
            users,
            tokens,
            amounts,
            proofs
        );

        // extractOutputToken returns first token
        address outputToken = parser.extractOutputToken(MERKL_DISTRIBUTOR, data);
        assertEq(outputToken, TOKEN_A, "Should return first token");
    }

    function testExtractAllClaimTokens() public view {
        // Build calldata with multiple tokens
        address[] memory users = new address[](2);
        users[0] = USER;
        users[1] = USER;

        address[] memory tokens = new address[](2);
        tokens[0] = TOKEN_A;
        tokens[1] = TOKEN_B;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = keccak256("proof1");
        proofs[1] = new bytes32[](1);
        proofs[1][0] = keccak256("proof2");

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_SELECTOR(),
            users,
            tokens,
            amounts,
            proofs
        );

        // Should return all tokens
        address[] memory extractedTokens = parser.extractAllClaimTokens(data);
        assertEq(extractedTokens.length, 2, "Should have 2 tokens");
        assertEq(extractedTokens[0], TOKEN_A, "First token mismatch");
        assertEq(extractedTokens[1], TOKEN_B, "Second token mismatch");
    }

    function testExtractAllClaimAmounts() public view {
        // Build calldata with multiple amounts
        address[] memory users = new address[](2);
        users[0] = USER;
        users[1] = USER;

        address[] memory tokens = new address[](2);
        tokens[0] = TOKEN_A;
        tokens[1] = TOKEN_B;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = keccak256("proof1");
        proofs[1] = new bytes32[](1);
        proofs[1][0] = keccak256("proof2");

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_SELECTOR(),
            users,
            tokens,
            amounts,
            proofs
        );

        // Should return all amounts
        uint256[] memory extractedAmounts = parser.extractAllClaimAmounts(data);
        assertEq(extractedAmounts.length, 2, "Should have 2 amounts");
        assertEq(extractedAmounts[0], 100e18, "First amount mismatch");
        assertEq(extractedAmounts[1], 200e18, "Second amount mismatch");
    }

    function testGetOperationType() public view {
        assertEq(parser.getOperationType(parser.CLAIM_SELECTOR()), 4, "Claim should be operation type 4");
        assertEq(parser.getOperationType(bytes4(0xdeadbeef)), 0, "Unknown selector should return 0");
    }

    function testUnsupportedSelectorReverts() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(MerklParser.UnsupportedSelector.selector);
        parser.extractInputToken(MERKL_DISTRIBUTOR, badData);

        vm.expectRevert(MerklParser.UnsupportedSelector.selector);
        parser.extractInputAmount(MERKL_DISTRIBUTOR, badData);

        vm.expectRevert(MerklParser.UnsupportedSelector.selector);
        parser.extractOutputToken(MERKL_DISTRIBUTOR, badData);

        vm.expectRevert(MerklParser.UnsupportedSelector.selector);
        parser.extractAllClaimTokens(badData);

        vm.expectRevert(MerklParser.UnsupportedSelector.selector);
        parser.extractAllClaimAmounts(badData);
    }

    function testEmptyTokensArray() public view {
        address[] memory users = new address[](0);
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_SELECTOR(),
            users,
            tokens,
            amounts,
            proofs
        );

        // Should return address(0) for empty tokens array
        address outputToken = parser.extractOutputToken(MERKL_DISTRIBUTOR, data);
        assertEq(outputToken, address(0), "Should return zero address for empty array");
    }

    // Helper function to build standard claim calldata
    function _buildClaimCalldata() internal pure returns (bytes memory) {
        address[] memory users = new address[](1);
        users[0] = USER;

        address[] memory tokens = new address[](1);
        tokens[0] = TOKEN_A;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](2);
        proofs[0][0] = keccak256("leaf");
        proofs[0][1] = keccak256("sibling");

        return abi.encodeWithSelector(
            bytes4(0x71ee95c0), // CLAIM_SELECTOR
            users,
            tokens,
            amounts,
            proofs
        );
    }
}
