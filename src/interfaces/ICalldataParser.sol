// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICalldataParser
 * @notice Interface for protocol-specific calldata parsers
 * @dev Each DeFi protocol needs a parser to extract token/amount from calldata
 */
interface ICalldataParser {
    /**
     * @notice Extract the input token from calldata
     * @param data The calldata to parse
     * @return token The input token address
     */
    function extractInputToken(bytes calldata data) external pure returns (address token);

    /**
     * @notice Extract the input amount from calldata
     * @param data The calldata to parse
     * @return amount The input amount
     */
    function extractInputAmount(bytes calldata data) external pure returns (uint256 amount);

    /**
     * @notice Extract the output token from calldata (for swaps/withdrawals)
     * @param data The calldata to parse
     * @return token The output token address
     */
    function extractOutputToken(bytes calldata data) external pure returns (address token);

    /**
     * @notice Extract the spender address from approve calldata
     * @param data The calldata to parse
     * @return spender The spender address
     */
    function extractApproveSpender(bytes calldata data) external pure returns (address spender);

    /**
     * @notice Check if this parser supports the given selector
     * @param selector The function selector
     * @return supported Whether the selector is supported
     */
    function supportsSelector(bytes4 selector) external pure returns (bool supported);
}
