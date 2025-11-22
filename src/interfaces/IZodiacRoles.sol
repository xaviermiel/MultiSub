// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IZodiacRoles
 * @notice Minimal interface for Zodiac Roles Modifier
 */
interface IZodiacRoles {
    enum Clearance {
        None,
        Target,
        Function
    }

    enum ParameterType {
        Static,
        Dynamic,
        Dynamic32
    }

    struct ConditionFlat {
        ParameterType paramType;
        uint8 operator;
        bytes compValue;
    }

    /**
     * @notice Assign roles to a member
     */
    function assignRoles(
        address member,
        uint16[] calldata roleIds,
        bool[] calldata memberOf
    ) external;

    /**
     * @notice Scope a target address for a role
     */
    function scopeTarget(uint16 role, address target) external;

    /**
     * @notice Scope a function on a target for a role
     */
    function scopeFunction(
        uint16 role,
        address target,
        bytes4 functionSig,
        bool[] calldata isScoped,
        ParameterType[] calldata paramType,
        Clearance clearance
    ) external;

    /**
     * @notice Revoke a role from a member
     */
    function revokeRoles(
        address member,
        uint16[] calldata roleIds
    ) external;

    /**
     * @notice Check if member has a role
     */
    function hasRole(address member, uint16 role) external view returns (bool);

    /**
     * @notice Execute a transaction as a role member
     */
    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint16 roleId,
        bool shouldRevert
    ) external returns (bool success);
}
