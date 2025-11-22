// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISafe
 * @notice Minimal interface for Safe (Gnosis) multisig interactions
 */
interface ISafe {
    enum Operation {
        Call,
        DelegateCall
    }

    /**
     * @notice Execute a transaction from the Safe
     */
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    /**
     * @notice Execute a transaction from an enabled module
     */
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation
    ) external returns (bool success);

    /**
     * @notice Enable a module on the Safe
     */
    function enableModule(address module) external;

    /**
     * @notice Disable a module on the Safe
     */
    function disableModule(address prevModule, address module) external;

    /**
     * @notice Check if an address is an enabled module
     */
    function isModuleEnabled(address module) external view returns (bool);

    /**
     * @notice Get list of owners
     */
    function getOwners() external view returns (address[] memory);

    /**
     * @notice Get threshold for multisig
     */
    function getThreshold() external view returns (uint256);
}
