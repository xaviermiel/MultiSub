// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title MerklParser
 * @notice Calldata parser for Merkl Distributor reward claims
 * @dev Extracts token information from Merkl claim function calldata
 *      Merkl Distributor address: 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae (most chains)
 */
contract MerklParser is ICalldataParser {
    error UnsupportedSelector();

    // Merkl Distributor function selector
    // claim(address[] users, address[] tokens, uint256[] amounts, bytes32[][] proofs)
    bytes4 public constant CLAIM_SELECTOR = 0x71ee95c0;

    /// @inheritdoc ICalldataParser
    function extractInputToken(address, bytes calldata data) external pure override returns (address) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == CLAIM_SELECTOR) {
            // CLAIM operations don't have input tokens (no spending)
            return address(0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmount(address, bytes calldata data) external pure override returns (uint256) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == CLAIM_SELECTOR) {
            // CLAIM operations don't have input amounts (no spending)
            return 0;
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractOutputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == CLAIM_SELECTOR) {
            // claim(address[] users, address[] tokens, uint256[] amounts, bytes32[][] proofs)
            // Extract first token from tokens array as the output token
            (, address[] memory tokens,,) = abi.decode(data[4:], (address[], address[], uint256[], bytes32[][]));

            if (tokens.length > 0) {
                return tokens[0];
            }
            return address(0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address) external pure override returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == CLAIM_SELECTOR) {
            // claim(address[] users, address[] tokens, uint256[] amounts, bytes32[][] proofs)
            // In Merkl, the 'users' array contains the recipients of the rewards
            // Return the first user as the recipient
            (address[] memory users,,,) = abi.decode(data[4:], (address[], address[], uint256[], bytes32[][]));

            if (users.length > 0) {
                return users[0];
            }
            revert UnsupportedSelector();
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == CLAIM_SELECTOR;
    }

    /**
     * @notice Get the operation type for a given selector
     * @param selector The function selector
     * @return opType 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     */
    function getOperationType(bytes4 selector) external pure returns (uint8 opType) {
        if (selector == CLAIM_SELECTOR) {
            return 4; // CLAIM
        }
        return 0; // UNKNOWN
    }

    /**
     * @notice Extract all tokens being claimed
     * @param data The calldata to parse
     * @return tokens Array of token addresses being claimed
     */
    function extractAllClaimTokens(bytes calldata data) external pure returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == CLAIM_SELECTOR) {
            (, tokens,,) = abi.decode(data[4:], (address[], address[], uint256[], bytes32[][]));
            return tokens;
        }
        revert UnsupportedSelector();
    }

    /**
     * @notice Extract all amounts being claimed
     * @param data The calldata to parse
     * @return amounts Array of cumulative amounts being claimed
     */
    function extractAllClaimAmounts(bytes calldata data) external pure returns (uint256[] memory amounts) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == CLAIM_SELECTOR) {
            (,, amounts,) = abi.decode(data[4:], (address[], address[], uint256[], bytes32[][]));
            return amounts;
        }
        revert UnsupportedSelector();
    }
}
