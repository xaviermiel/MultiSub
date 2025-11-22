// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IZodiacRoles} from "./interfaces/IZodiacRoles.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SmartWallet
 * @notice Core contract for managing delegated DeFi interactions through a Safe multisig
 * @dev This contract acts as the interactor between sub-accounts and the Safe+Zodiac system
 */
contract SmartWallet is ReentrancyGuard {
    /// @notice The Safe multisig that owns this wallet
    address public immutable safe;

    /// @notice The Zodiac Roles modifier for access control
    address public immutable rolesModifier;

    /// @notice Role ID for sub-account operations
    uint16 public constant SUB_ACCOUNT_ROLE = 100;

    /// @notice Mapping of sub-accounts to their enabled status
    mapping(address => bool) public subAccounts;

    /// @notice Mapping of whitelisted protocol addresses
    mapping(address => bool) public whitelistedProtocols;

    event SubAccountAdded(address indexed subAccount);
    event SubAccountRemoved(address indexed subAccount);
    event ProtocolWhitelisted(address indexed protocol);
    event ProtocolRemoved(address indexed protocol);
    event DelegatedTxExecuted(
        address indexed subAccount,
        address indexed target,
        bytes data,
        bool success,
        bytes returnData
    );

    error Unauthorized();
    error InvalidAddress();
    error ProtocolNotWhitelisted();
    error SubAccountNotEnabled();
    error TransactionFailed(bytes returnData);

    modifier onlySafe() {
        if (msg.sender != safe) revert Unauthorized();
        _;
    }

    modifier onlySubAccount() {
        if (!subAccounts[msg.sender]) revert SubAccountNotEnabled();
        _;
    }

    constructor(address _safe, address _rolesModifier) {
        if (_safe == address(0) || _rolesModifier == address(0)) revert InvalidAddress();
        safe = _safe;
        rolesModifier = _rolesModifier;
    }

    /**
     * @notice Add a sub-account that can execute delegated transactions
     * @param subAccount Address of the sub-account to add
     */
    function addSubAccount(address subAccount) external onlySafe {
        if (subAccount == address(0)) revert InvalidAddress();
        subAccounts[subAccount] = true;

        // Automatically grant the sub-account role in Zodiac Roles
        IZodiacRoles roles = IZodiacRoles(rolesModifier);
        uint16[] memory roleIds = new uint16[](1);
        roleIds[0] = SUB_ACCOUNT_ROLE;
        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;
        roles.assignRoles(subAccount, roleIds, memberOf);

        emit SubAccountAdded(subAccount);
    }

    /**
     * @notice Remove a sub-account
     * @param subAccount Address of the sub-account to remove
     */
    function removeSubAccount(address subAccount) external onlySafe {
        subAccounts[subAccount] = false;

        // Revoke the sub-account role in Zodiac Roles
        IZodiacRoles roles = IZodiacRoles(rolesModifier);
        uint16[] memory roleIds = new uint16[](1);
        roleIds[0] = SUB_ACCOUNT_ROLE;
        roles.revokeRoles(subAccount, roleIds);

        emit SubAccountRemoved(subAccount);
    }

    /**
     * @notice Whitelist a protocol for interactions
     * @param protocol Address of the protocol to whitelist
     */
    function whitelistProtocol(address protocol) external onlySafe {
        if (protocol == address(0)) revert InvalidAddress();
        whitelistedProtocols[protocol] = true;
        emit ProtocolWhitelisted(protocol);
    }

    /**
     * @notice Remove a protocol from whitelist
     * @param protocol Address of the protocol to remove
     */
    function removeProtocol(address protocol) external onlySafe {
        whitelistedProtocols[protocol] = false;
        emit ProtocolRemoved(protocol);
    }

    /**
     * @notice Execute a delegated transaction through the Safe via Zodiac Roles
     * @dev This function is called by sub-accounts to interact with whitelisted protocols
     * @param target The protocol contract to interact with
     * @param data The calldata for the interaction
     * @return success Whether the transaction succeeded
     * @return returnData The return data from the transaction
     */
    function executeDelegatedTx(
        address target,
        bytes calldata data
    ) external onlySubAccount nonReentrant returns (bool success, bytes memory returnData) {
        if (!whitelistedProtocols[target]) revert ProtocolNotWhitelisted();

        // Execute transaction through Zodiac Roles module
        // The Zodiac Roles module will verify the sub-account has the correct role
        // and then execute the transaction through the Safe
        IZodiacRoles roles = IZodiacRoles(rolesModifier);

        try roles.execTransactionWithRole(
            target,
            0, // no ETH value
            data,
            0, // Call operation (not delegatecall)
            SUB_ACCOUNT_ROLE,
            false // don't revert on failure, return false instead
        ) returns (bool _success) {
            success = _success;
            returnData = "";

            if (!success) {
                revert TransactionFailed(returnData);
            }

            emit DelegatedTxExecuted(msg.sender, target, data, success, returnData);
            return (success, returnData);
        } catch Error(string memory reason) {
            returnData = bytes(reason);
            emit DelegatedTxExecuted(msg.sender, target, data, false, returnData);
            revert TransactionFailed(returnData);
        } catch (bytes memory lowLevelData) {
            returnData = lowLevelData;
            emit DelegatedTxExecuted(msg.sender, target, data, false, returnData);
            revert TransactionFailed(returnData);
        }
    }

    /**
     * @notice Get sub-account status
     * @param account Address to check
     * @return bool Whether the account is an enabled sub-account
     */
    function isSubAccount(address account) external view returns (bool) {
        return subAccounts[account];
    }

    /**
     * @notice Get protocol whitelist status
     * @param protocol Address to check
     * @return bool Whether the protocol is whitelisted
     */
    function isWhitelisted(address protocol) external view returns (bool) {
        return whitelistedProtocols[protocol];
    }
}
