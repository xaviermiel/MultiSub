// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccount, PackedUserOperation, IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ISafe} from "./interfaces/ISafe.sol";

/**
 * @title SafeERC4337Account
 * @notice ERC-4337 Account Abstraction adapter for Safe (Gnosis Safe)
 * @dev Wraps a Safe multisig to make it compatible with ERC-4337 EntryPoint
 *
 * This contract allows a Safe to participate in the ERC-4337 ecosystem:
 * - Validates user operations signed by Safe owners
 * - Executes operations through the Safe
 * - Supports paymaster integration for gasless transactions
 *
 * The Safe must enable this contract as a module for it to execute transactions.
 */
contract SafeERC4337Account is IAccount {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @dev The canonical ERC-4337 EntryPoint v0.8.0
    IEntryPoint public immutable entryPoint;

    /// @dev The Safe this account wraps
    ISafe public immutable safe;

    /// @dev Unauthorized caller
    error OnlyEntryPoint();

    /// @dev Safe execution failed
    error SafeExecutionFailed();

    /// @dev Invalid signature
    error InvalidSignature();

    event SafeERC4337AccountInitialized(address indexed safe, address indexed entryPoint);
    event UserOperationExecuted(address indexed sender, uint256 nonce, bool success);

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert OnlyEntryPoint();
        _;
    }

    /**
     * @notice Initialize the Safe ERC4337 Account
     * @param _safe The Safe multisig address
     * @param _entryPoint The ERC-4337 EntryPoint address
     */
    constructor(address _safe, address _entryPoint) {
        safe = ISafe(_safe);
        entryPoint = IEntryPoint(_entryPoint);
        emit SafeERC4337AccountInitialized(_safe, _entryPoint);
    }

    /**
     * @notice Validates a user operation
     * @dev Must be called by the EntryPoint
     * @param userOp The user operation to validate
     * @param userOpHash The hash of the user operation
     * @param missingAccountFunds The funds needed to pay for the operation
     * @return validationData Packed validation data (authorizer, validUntil, validAfter)
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override onlyEntryPoint returns (uint256 validationData) {
        // Validate signature
        validationData = _validateSignature(userOp, userOpHash);

        // Pay prefund if needed
        if (missingAccountFunds > 0) {
            _payPrefund(missingAccountFunds);
        }
    }

    /**
     * @notice Execute a user operation from the EntryPoint
     * @dev Called by EntryPoint after validation
     * @param userOp The user operation to execute
     */
    function executeUserOp(
        PackedUserOperation calldata userOp
    ) external onlyEntryPoint {
        _executeUserOp(userOp.callData);
    }

    /**
     * @notice Execute a batch of calls through the Safe
     * @param dest Array of destination addresses
     * @param value Array of values to send
     * @param func Array of calldata for each call
     */
    function executeBatch(
        address[] calldata dest,
        uint256[] calldata value,
        bytes[] calldata func
    ) external onlyEntryPoint {
        require(dest.length == value.length && value.length == func.length, "Length mismatch");

        for (uint256 i = 0; i < dest.length; i++) {
            _call(dest[i], value[i], func[i]);
        }
    }

    /**
     * @notice Get the deposit of this account in the EntryPoint
     * @return The current deposit balance
     */
    function getDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /**
     * @notice Add deposit to the EntryPoint for this account
     */
    function addDeposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /**
     * @notice Withdraw deposit from EntryPoint
     * @param withdrawAddress Address to receive the withdrawn funds
     * @param amount Amount to withdraw
     */
    function withdrawDepositTo(
        address payable withdrawAddress,
        uint256 amount
    ) external {
        // Only Safe owners can withdraw
        require(_isSafeOwner(msg.sender), "Not Safe owner");
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    /**
     * @dev Validate the signature of a user operation
     * @param userOp The user operation
     * @param userOpHash The hash of the user operation
     * @return validationData Validation data (0 = success, 1 = failure)
     */
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal view returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address recovered = hash.recover(userOp.signature);

        // Check if recovered address is a Safe owner
        if (!_isSafeOwner(recovered)) {
            return ERC4337Utils.SIG_VALIDATION_FAILED;
        }

        return ERC4337Utils.SIG_VALIDATION_SUCCESS;
    }

    /**
     * @dev Execute the user operation's callData through the Safe
     * @param callData The calldata to execute
     */
    function _executeUserOp(bytes calldata callData) internal {
        if (callData.length >= 4) {
            bytes4 selector = bytes4(callData[0:4]);

            // Check if it's a batch execution
            if (selector == this.executeBatch.selector) {
                (bool success,) = address(this).call(callData);
                if (!success) revert SafeExecutionFailed();
                return;
            }
        }

        // Single call execution
        (address dest, uint256 value, bytes memory func) =
            abi.decode(callData, (address, uint256, bytes));
        _call(dest, value, func);
    }

    /**
     * @dev Execute a call through the Safe
     * @param target The target address
     * @param value The value to send
     * @param data The calldata
     */
    function _call(address target, uint256 value, bytes memory data) internal {
        bool success = safe.execTransactionFromModule(
            target,
            value,
            data,
            ISafe.Operation.Call
        );

        if (!success) revert SafeExecutionFailed();
        emit UserOperationExecuted(address(safe), 0, success);
    }

    /**
     * @dev Pay the required prefund to the EntryPoint
     * @param missingAccountFunds The amount to pay
     */
    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds > 0) {
            // Transfer ETH from Safe to this contract, then to EntryPoint
            bool success = safe.execTransactionFromModule(
                address(entryPoint),
                missingAccountFunds,
                "",
                ISafe.Operation.Call
            );
            if (!success) revert SafeExecutionFailed();
        }
    }

    /**
     * @dev Check if an address is a Safe owner
     * @param account The address to check
     * @return True if the address is a Safe owner
     */
    function _isSafeOwner(address account) internal view returns (bool) {
        address[] memory owners = safe.getOwners();
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == account) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Check if this contract is enabled as a Safe module
     * @return True if enabled as a module
     */
    function isModuleEnabled() external view returns (bool) {
        return safe.isModuleEnabled(address(this));
    }

    /**
     * @dev Allow receiving ETH
     */
    receive() external payable {}
}
