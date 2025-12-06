// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockParser
 * @notice Mock calldata parser for testing
 * @dev Parses deposit(uint256,address) and withdraw(uint256,address) calldata
 */
contract MockParser {
    bytes4 constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(uint256,address)"));
    bytes4 constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(uint256,address)"));

    address public tokenAddress;

    constructor(address _token) {
        tokenAddress = _token;
    }

    function extractInputToken(address, bytes calldata) external view returns (address) {
        return tokenAddress;
    }

    function extractInputAmount(address, bytes calldata data) external pure returns (uint256 amount) {
        (amount,) = abi.decode(data[4:], (uint256, address));
    }

    function extractOutputToken(address, bytes calldata) external view returns (address) {
        return tokenAddress;
    }

    function supportsSelector(bytes4 selector) external pure returns (bool) {
        return selector == DEPOSIT_SELECTOR || selector == WITHDRAW_SELECTOR;
    }
}
