// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockProtocol
 * @notice Mock DeFi protocol for testing
 */
contract MockProtocol {
    event ProtocolCalled(address indexed caller, uint256 amount);

    function deposit(uint256 amount, address) external {
        emit ProtocolCalled(msg.sender, amount);
    }

    function withdraw(uint256 amount, address) external {
        emit ProtocolCalled(msg.sender, amount);
    }
}
