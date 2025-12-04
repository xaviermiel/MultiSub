// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICalldataParser
 * @notice Interface for protocol-specific calldata parsers
 * @dev Each DeFi protocol needs a parser to extract token/amount from calldata
 *      Parsers receive the target address to query on-chain state when needed (e.g., ERC4626 vaults)
 */
interface ICalldataParser {
    /**
     * @notice Extract the input token from calldata
     * @param target The protocol/vault address being called
     * @param data The calldata to parse
     * @return token The input token address
     */
    function extractInputToken(address target, bytes calldata data) external view returns (address token);

    /**
     * @notice Extract the input amount from calldata
     * @param target The protocol/vault address being called
     * @param data The calldata to parse
     * @return amount The input amount
     */
    function extractInputAmount(address target, bytes calldata data) external view returns (uint256 amount);

    /**
     * @notice Extract the output token from calldata (for swaps/withdrawals)
     * @param target The protocol/vault address being called
     * @param data The calldata to parse
     * @return token The output token address
     */
    function extractOutputToken(address target, bytes calldata data) external view returns (address token);

    /**
     * @notice Check if this parser supports the given selector
     * @param selector The function selector
     * @return supported Whether the selector is supported
     */
    function supportsSelector(bytes4 selector) external pure returns (bool supported);
}
