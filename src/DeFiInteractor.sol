// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMorphoVault} from "./interfaces/IMorphoVault.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {IZodiacRoles} from "./interfaces/IZodiacRoles.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DeFiInteractor
 * @notice Contract for executing DeFi operations through Safe+Zodiac with restrictions
 * @dev Sub-accounts interact with this contract which enforces role-based permissions
 */
contract DeFiInteractor is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice The Safe multisig that owns the assets
    ISafe public immutable safe;

    /// @notice The Zodiac Roles modifier for access control
    IZodiacRoles public immutable rolesModifier;

    /// @notice Role ID for basic DeFi operations (deposits)
    uint16 public constant DEFI_DEPOSIT_ROLE = 1;

    /// @notice Role ID for withdrawal operations (more restricted)
    uint16 public constant DEFI_WITHDRAW_ROLE = 2;

    /// @notice Per-sub-account allowed addresses: subAccount => target address => allowed
    mapping(address => mapping(address => bool)) public allowedAddresses;

    // ============ Events ============

    event RoleAssigned(address indexed member, uint16 indexed roleId, uint256 timestamp);
    event RoleRevoked(address indexed member, uint16 indexed roleId, uint256 timestamp);

    error Unauthorized();
    error InvalidAddress();
    error TransactionFailed();
    error AddressNotAllowed();

    modifier onlySafe() {
        if (msg.sender != address(safe)) revert Unauthorized();
        _;
    }

    constructor(address _safe, address _rolesModifier) {
        if (_safe == address(0) || _rolesModifier == address(0)) revert InvalidAddress();
        safe = ISafe(_safe);
        rolesModifier = IZodiacRoles(_rolesModifier);
    }

    // ============ Emergency Controls ============

    /**
     * @notice Pause all operations (only Safe can call)
     */
    function pause() external onlySafe {
        _pause();
        emit EmergencyPaused(msg.sender, block.timestamp);
    }

    /**
     * @notice Unpause all operations (only Safe can call)
     */
    function unpause() external onlySafe {
        _unpause();
        emit EmergencyUnpaused(msg.sender, block.timestamp);
    }


    // ============ Core Functions with Enhanced Security ============

    /**
     * @notice Deposit assets into a SC with role-based restrictions
     * @param target The target address
     * @param assets Amount of assets to deposit
     * @param receiver Address that will receive the shares
     * @param minShares Minimum shares to receive
     * @return actualShares Amount of shares actually received
     */
    function depositTo(
        address target,
        uint256 assets,
        address receiver,
        uint256 minShares
    ) external nonReentrant whenNotPaused returns (uint256 actualShares) {
        // Check role permission
        if (!rolesModifier.hasRole(msg.sender, DEFI_DEPOSIT_ROLE)) revert Unauthorized();

        // Check if address is allowed for this sub-account
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        IMorphoVault morphoVault = IMorphoVault(target);
        address asset = morphoVault.asset();
        IERC20 token = IERC20(asset);

        uint256 safeBalanceBefore = token.balanceOf(address(safe));

        // Get sub-account specific limits
        (uint256 maxDepositBps, , , uint256 windowDuration) = getSubAccountLimits(msg.sender);

        // Reset window if expired or first time
        if (block.timestamp >= depositWindowStart[msg.sender][target] + windowDuration ||
            depositWindowStart[msg.sender][target] == 0) {
            depositedInWindow[msg.sender][target] = 0;
            depositWindowStart[msg.sender][target] = block.timestamp;
            depositWindowBalance[msg.sender][target] = safeBalanceBefore;
            emit DepositWindowReset(msg.sender, target, block.timestamp);
        }

        // Calculate cumulative limit based on balance at window start
        uint256 windowBalance = depositWindowBalance[msg.sender][target];
        uint256 cumulativeDeposit = depositedInWindow[msg.sender][target] + assets;
        uint256 maxDeposit = Math.mulDiv(windowBalance, maxDepositBps, 10000, Math.Rounding.Floor);

        if (cumulativeDeposit > maxDeposit) revert ExceedsDepositLimit();

        // Calculate percentage for monitoring
        uint256 percentageOfBalance = Math.mulDiv(assets, 10000, safeBalanceBefore, Math.Rounding.Floor);

        // Alert on unusual activity (>8% in single transaction)
        if (percentageOfBalance > 800) {
            emit UnusualActivity(
                msg.sender,
                "Large deposit percentage",
                percentageOfBalance,
                800,
                block.timestamp
            );
        }

        uint256 sharesBefore = morphoVault.balanceOf(receiver);

        bytes memory approveData = abi.encodeWithSelector(
            IERC20.approve.selector,
            target,
            assets
        );

        uint256 allowanceBefore = token.allowance(address(safe), target);

        // Execute approval through Zodiac Roles -> Safe
        bool approveSuccess = rolesModifier.execTransactionWithRole(
            asset,
            0,
            approveData,
            0,
            DEFI_DEPOSIT_ROLE,
            true
        );

        if (!approveSuccess) revert TransactionFailed();

        uint256 allowanceAfter = token.allowance(address(safe), target);
        if (allowanceAfter < allowanceBefore + assets) revert ApprovalFailed();

        // Execute deposit
        bytes memory depositData = abi.encodeWithSelector(
            IMorphoVault.deposit.selector,
            assets,
            receiver
        );

        // Execute deposit through Zodiac Roles -> Safe
        bool depositSuccess = rolesModifier.execTransactionWithRole(
            target,
            0,
            depositData,
            0,
            DEFI_DEPOSIT_ROLE,
            true
        );

        if (!depositSuccess) revert TransactionFailed();

        // Verify actual shares received
        uint256 sharesAfter = morphoVault.balanceOf(receiver);
        actualShares = sharesAfter - sharesBefore;

        if (actualShares < minShares) revert InsufficientSharesReceived();

        // Update cumulative tracking
        depositedInWindow[msg.sender][target] = cumulativeDeposit;

        // Get balance after for monitoring
        uint256 safeBalanceAfter = token.balanceOf(address(safe));

        // Comprehensive monitoring event
        emit DepositExecuted(
            msg.sender,
            target,
            assets,
            actualShares,
            safeBalanceBefore,
            safeBalanceAfter,
            cumulativeDeposit,
            percentageOfBalance,
            block.timestamp
        );

        return actualShares;
    }

    /**
     * @notice Withdraw assets from a sc with role-based restrictions
     * @param target The target address
     * @param assets Amount of assets to withdraw
     * @param receiver Address that will receive the assets
     * @param owner Address of the share owner
     * @param maxShares Maximum shares to burn
     * @return actualShares Amount of shares actually burned
     */
    function withdrawFrom(
        address target,
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxShares
    ) external nonReentrant whenNotPaused returns (uint256 actualShares) {
        // Check role permission
        if (!rolesModifier.hasRole(msg.sender, DEFI_WITHDRAW_ROLE)) revert Unauthorized();

        // Check if address is allowed for this sub-account
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        IMorphoVault morphoVault = IMorphoVault(target);
        uint256 safeSharesBefore = morphoVault.balanceOf(address(safe));
        uint256 safeAssetValue = morphoVault.convertToAssets(safeSharesBefore);

        // Get sub-account specific limits
        (, uint256 maxWithdrawBps, , uint256 windowDuration) = getSubAccountLimits(msg.sender);

        // Reset window if expired or first time
        if (block.timestamp >= withdrawWindowStart[msg.sender][target] + windowDuration ||
            withdrawWindowStart[msg.sender][target] == 0) {
            withdrawnInWindow[msg.sender][target] = 0;
            withdrawWindowStart[msg.sender][target] = block.timestamp;
            withdrawWindowShares[msg.sender][target] = safeAssetValue;
            emit WithdrawWindowReset(msg.sender, target, block.timestamp);
        }

        // Calculate cumulative limit based on shares at window start
        uint256 windowAssetValue = withdrawWindowShares[msg.sender][target];
        uint256 cumulativeWithdraw = withdrawnInWindow[msg.sender][target] + assets;
        uint256 maxWithdraw = Math.mulDiv(windowAssetValue, maxWithdrawBps, 10000, Math.Rounding.Floor);

        if (cumulativeWithdraw > maxWithdraw) revert ExceedsWithdrawLimit();

        // Calculate percentage for monitoring
        uint256 percentageOfPosition = Math.mulDiv(assets, 10000, safeAssetValue, Math.Rounding.Floor);

        // Alert on unusual activity (>4% in single transaction)
        if (percentageOfPosition > 400) {
            emit UnusualActivity(
                msg.sender,
                "Large withdrawal percentage",
                percentageOfPosition,
                400,
                block.timestamp
            );
        }

        address asset = morphoVault.asset();
        IERC20 token = IERC20(asset);
        uint256 assetsBefore = token.balanceOf(receiver);
        uint256 sharesBefore = morphoVault.balanceOf(owner);

        // Execute withdrawal
        bytes memory data = abi.encodeWithSelector(
            IMorphoVault.withdraw.selector,
            assets,
            receiver,
            owner
        );

        bool success = rolesModifier.execTransactionWithRole(
            target,
            0,
            data,
            0,
            DEFI_WITHDRAW_ROLE,
            true
        );

        if (!success) revert TransactionFailed();

        return 0;
    }

    // ============ Role Management ============

    /**
     * @notice Grant a role to a sub-account (only Safe can do this)
     * @param member The address to grant the role to
     * @param roleId The role ID to grant
     */
    function grantRole(address member, uint16 roleId) external onlySafe {
        if (member == address(0)) revert InvalidAddress();

        uint16[] memory roleIds = new uint16[](1);
        roleIds[0] = roleId;

        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;

        rolesModifier.assignRoles(member, roleIds, memberOf);

        emit RoleAssigned(member, roleId, block.timestamp);
    }

    /**
     * @notice Revoke a role from a sub-account (only Safe can do this)
     * @param member The address to revoke the role from
     * @param roleId The role ID to revoke
     */
    function revokeRole(address member, uint16 roleId) external onlySafe {
        if (member == address(0)) revert InvalidAddress();

        uint16[] memory roleIds = new uint16[](1);
        roleIds[0] = roleId;

        rolesModifier.revokeRoles(member, roleIds);

        emit RoleRevoked(member, roleId, block.timestamp);
    }

    /**
     * @notice Check if an address has a specific role
     * @param member The address to check
     * @param roleId The role ID to check
     * @return bool Whether the address has the role
     */
    function hasRole(address member, uint16 roleId) external view returns (bool) {
        return rolesModifier.hasRole(member, roleId);
    }
}
