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
     * @notice Extract the output tokens from calldata (for swaps/withdrawals)
     * @param target The protocol/vault address being called
     * @param data The calldata to parse
     * @return tokens Array of output token addresses (empty array if no output tokens)
     * @dev For single-token outputs, returns array with 1 element.
     *      For multi-token outputs (e.g., LP positions), returns all output tokens.
     *      For operations with no output tokens, returns empty array.
     */
    function extractOutputTokens(address target, bytes calldata data) external view returns (address[] memory tokens);

    /**
     * @notice Extract the recipient address from calldata
     * @param target The protocol/vault address being called
     * @param data The calldata to parse
     * @param defaultRecipient The default recipient (Safe address) to use when recipient is not explicit in calldata
     * @return recipient The recipient address where output tokens will be sent
     * @dev For protocols with explicit recipients in calldata, extract and return it.
     *      For protocols where recipient is implicit (e.g., msg.sender), return defaultRecipient.
     *      The module will validate that recipient == Safe address to prevent fund theft.
     */
    function extractRecipient(address target, bytes calldata data, address defaultRecipient) external view returns (address recipient);

    /**
     * @notice Check if this parser supports the given selector
     * @param selector The function selector
     * @return supported Whether the selector is supported
     */
    function supportsSelector(bytes4 selector) external pure returns (bool supported);

    /**
     * @notice Get the operation type for the given calldata
     * @param data The calldata to analyze
     * @return opType The operation type: 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     * @dev This allows parsers to determine operation type from calldata content,
     *      which is essential for protocols with single entry points (e.g., Uniswap V4's modifyLiquidities)
     */
    function getOperationType(bytes calldata data) external pure returns (uint8 opType);
}
