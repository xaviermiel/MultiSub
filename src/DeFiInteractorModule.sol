// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Module} from "./base/Module.sol";
import {IMorphoVault} from "./interfaces/IMorphoVault.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DeFiInteractorModule
 * @notice Custom Zodiac module for executing DeFi operations with role-based permissions
 * @dev This module handles roles, allowed addresses, and sub-account limits internally
 */
contract DeFiInteractorModule is Module, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Role ID for generic protocol execution
    uint16 public constant DEFI_EXECUTE_ROLE = 1;

    /// @notice Role ID for token transfers
    uint16 public constant DEFI_TRANSFER_ROLE = 2;

    // ============ Safe Value Storage ============

    /// @notice Struct to store Safe's USD value data
    struct SafeValue {
        uint256 totalValueUSD;  // Total USD value with 18 decimals (e.g., 1000.50 USD = 1000500000000000000000)
        uint256 lastUpdated;    // Timestamp of last update
        uint256 updateCount;    // Number of updates received
    }

    /// @notice Safe's current USD value (avatar address is the Safe)
    SafeValue public safeValue;

    /// @notice Authorized updater (Chainlink CRE proxy contract)
    address public authorizedUpdater;

    // /// @notice Price oracle for portfolio valuation
    // IPriceOracle public priceOracle;

    // /// @notice List of tracked tokens for portfolio valuation
    // address[] public trackedTokens;

    // /// @notice Mapping to check if protocol is tracked
    // mapping(address => bool) public isTrackedProtocol;

    /// @notice Default maximum percentage of portfolio value loss allowed per window (basis points)
    uint256 public constant DEFAULT_MAX_LOSS_BPS = 500; // 5%

    /// @notice Default maximum percentage of assets a sub-account can deposit (basis points)
    uint256 public constant DEFAULT_MAX_DEPOSIT_BPS = 1000; // 10%

    /// @notice Default maximum percentage of assets a sub-account can withdraw (basis points)
    uint256 public constant DEFAULT_MAX_WITHDRAW_BPS = 500; // 5%

    /// @notice Default time window for cumulative limit tracking (24 hours)
    uint256 public constant DEFAULT_LIMIT_WINDOW_DURATION = 1 days;

    /// @notice Configuration for sub-account limits
    struct SubAccountLimits {
        uint256 maxDepositBps;      // Maximum deposit percentage in basis points
        uint256 maxWithdrawBps;     // Maximum withdrawal percentage in basis points
        uint256 maxLossBps;         // Maximum portfolio value loss in basis points
        uint256 windowDuration;     // Time window duration in seconds
        bool isConfigured;          // Whether limits have been explicitly set
    }

    /// @notice Per-sub-account limit configuration
    mapping(address => SubAccountLimits) public subAccountLimits;

    // /// @notice Portfolio value at start of execution window: subAccount => value
    // mapping(address => uint256) public executionWindowPortfolioValue;

    // /// @notice Window start time for executions: subAccount => timestamp
    // mapping(address => uint256) public executionWindowStart;

    // /// @notice Cumulative value lost in current window: subAccount => amount
    // mapping(address => uint256) public valueLostInWindow;

    /// @notice Per-sub-account allowed addresses: subAccount => target address => allowed
    mapping(address => mapping(address => bool)) public allowedAddresses;

    /// @notice Sub-account roles: subAccount => role => has role
    mapping(address => mapping(uint16 => bool)) public subAccountRoles;

    /// @notice Cumulative transfers in current window: subAccount => token address => amount
    mapping(address => mapping(address => uint256)) public transferredInWindow;

    /// @notice Window start time for transfers: subAccount => token address => timestamp
    mapping(address => mapping(address => uint256)) public transferWindowStart;

    /// @notice Safe's balance at start of transfer window: subAccount => token address => balance
    mapping(address => mapping(address => uint256)) public transferWindowBalance;

    // ============ Events ============

    event RoleAssigned(address indexed member, uint16 indexed roleId, uint256 timestamp);
    event RoleRevoked(address indexed member, uint16 indexed roleId, uint256 timestamp);
    event SubAccountLimitsSet(
        address indexed subAccount,
        uint256 maxDepositBps,
        uint256 maxWithdrawBps,
        uint256 maxLossBps,
        uint256 windowDuration,
        uint256 timestamp
    );

    event ProtocolExecuted(
        address indexed subAccount,
        address indexed target,
        uint256 portfolioValueBefore,
        uint256 portfolioValueAfter,
        uint256 valueLost,
        uint256 cumulativeLossInWindow,
        uint256 timestamp
    );

    event ExecutionWindowReset(
        address indexed subAccount,
        uint256 newWindowStart,
        uint256 portfolioValue
    );

    event AllowedAddressesSet(
        address indexed subAccount,
        address[] targets,
        bool allowed,
        uint256 timestamp
    );

    event TransferExecuted(
        address indexed subAccount,
        address indexed token,
        address indexed recipient,
        uint256 amount,
        uint256 safeBalanceBefore,
        uint256 safeBalanceAfter,
        uint256 cumulativeInWindow,
        uint256 percentageOfBalance,
        uint256 timestamp
    );

    event TransferWindowReset(address indexed subAccount, address indexed token, uint256 newWindowStart);

    event EmergencyPaused(address indexed by, uint256 timestamp);
    event EmergencyUnpaused(address indexed by, uint256 timestamp);

    event UnusualActivity(
        address indexed subAccount,
        string activityType,
        uint256 value,
        uint256 threshold,
        uint256 timestamp
    );

    event ApprovalExecuted(
        address indexed subAccount,
        address indexed token,
        address indexed protocol,
        uint256 amount,
        uint256 timestamp
    );

    event SafeValueUpdated(
        uint256 totalValueUSD,
        uint256 timestamp,
        uint256 updateCount
    );

    event AuthorizedUpdaterChanged(
        address indexed oldUpdater,
        address indexed newUpdater
    );

    error TransactionFailed();
    error ApprovalFailed();
    error InvalidLimitConfiguration();
    error AddressNotAllowed();
    error ExceedsMaxLoss();
    error OracleNotSet();
    error NoTrackedTokens();
    error ApprovalNotAllowed();
    error ApprovalExceedsLimit();
    error ExceedsTransferLimit();
    error OnlyAuthorizedUpdater();
    error InvalidUpdaterAddress();

    /**
     * @notice Initialize the DeFi Interactor Module
     * @param _avatar The Safe address (avatar)
     * @param _owner The owner address (typically the Safe itself)
     * @param _authorizedUpdater The Chainlink CRE proxy address authorized to update Safe value
     */
    constructor(address _avatar, address _owner, address _authorizedUpdater)
        Module(_avatar, _avatar, _owner)
    {
        // Avatar and target are the same (the Safe)
        // Owner is typically the Safe for configuration functions
        if (_authorizedUpdater == address(0)) revert InvalidUpdaterAddress();
        authorizedUpdater = _authorizedUpdater;
    }

    // ============ Emergency Controls ============

    /**
     * @notice Pause all operations (only owner can call)
     */
    function pause() external onlyOwner {
        _pause();
        emit EmergencyPaused(msg.sender, block.timestamp);
    }

    /**
     * @notice Unpause all operations (only owner can call)
     */
    function unpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused(msg.sender, block.timestamp);
    }

    // ============ Role Management ============

    /**
     * @notice Grant a role to a sub-account (only owner can do this)
     * @param member The address to grant the role to
     * @param roleId The role ID to grant
     */
    function grantRole(address member, uint16 roleId) external onlyOwner {
        if (member == address(0)) revert InvalidAddress();
        subAccountRoles[member][roleId] = true;
        emit RoleAssigned(member, roleId, block.timestamp);
    }

    /**
     * @notice Revoke a role from a sub-account (only owner can do this)
     * @param member The address to revoke the role from
     * @param roleId The role ID to revoke
     */
    function revokeRole(address member, uint16 roleId) external onlyOwner {
        if (member == address(0)) revert InvalidAddress();
        subAccountRoles[member][roleId] = false;
        emit RoleRevoked(member, roleId, block.timestamp);
    }

    /**
     * @notice Check if an address has a specific role
     * @param member The address to check
     * @param roleId The role ID to check
     * @return bool Whether the address has the role
     */
    function hasRole(address member, uint16 roleId) public view returns (bool) {
        return subAccountRoles[member][roleId];
    }

    // ============ Sub-Account Configuration ============

    /**
     * @notice Set custom limits for a sub-account (only owner can call)
     * @param subAccount The sub-account address to configure
     * @param maxDepositBps Maximum deposit percentage in basis points (max 10000)
     * @param maxWithdrawBps Maximum withdrawal percentage in basis points (max 10000)
     * @param maxLossBps Maximum portfolio loss percentage in basis points (max 10000)
     * @param windowDuration Time window duration in seconds (min 1 hour)
     */
    function setSubAccountLimits(
        address subAccount,
        uint256 maxDepositBps,
        uint256 maxWithdrawBps,
        uint256 maxLossBps,
        uint256 windowDuration
    ) external onlyOwner {
        if (subAccount == address(0)) revert InvalidAddress();
        // Validate limits: BPS cannot exceed 100%, window must be at least 1 hour
        if (maxDepositBps > 10000 || maxWithdrawBps > 10000 || maxLossBps > 10000 || windowDuration < 1 hours) {
            revert InvalidLimitConfiguration();
        }

        subAccountLimits[subAccount] = SubAccountLimits({
            maxDepositBps: maxDepositBps,
            maxWithdrawBps: maxWithdrawBps,
            maxLossBps: maxLossBps,
            windowDuration: windowDuration,
            isConfigured: true
        });

        emit SubAccountLimitsSet(
            subAccount,
            maxDepositBps,
            maxWithdrawBps,
            maxLossBps,
            windowDuration,
            block.timestamp
        );
    }

    /**
     * @notice Get the effective limits for a sub-account
     * @param subAccount The sub-account address
     * @return maxDepositBps The maximum deposit percentage in basis points
     * @return maxWithdrawBps The maximum withdrawal percentage in basis points
     * @return maxLossBps The maximum portfolio loss percentage in basis points
     * @return windowDuration The time window duration in seconds
     */
    function getSubAccountLimits(address subAccount) public view returns (
        uint256 maxDepositBps,
        uint256 maxWithdrawBps,
        uint256 maxLossBps,
        uint256 windowDuration
    ) {
        SubAccountLimits memory limits = subAccountLimits[subAccount];
        if (limits.isConfigured) {
            return (limits.maxDepositBps, limits.maxWithdrawBps, limits.maxLossBps, limits.windowDuration);
        }
        // Return defaults if not configured
        return (DEFAULT_MAX_DEPOSIT_BPS, DEFAULT_MAX_WITHDRAW_BPS, DEFAULT_MAX_LOSS_BPS, DEFAULT_LIMIT_WINDOW_DURATION);
    }

    /**
     * @notice Set allowed addresses for a sub-account (only owner can call)
     * @param subAccount The sub-account address to configure
     * @param targets Array of target addresses to allow/disallow
     * @param allowed Whether to allow or disallow these addresses
     */
    function setAllowedAddresses(
        address subAccount,
        address[] calldata targets,
        bool allowed
    ) external onlyOwner {
        if (subAccount == address(0)) revert InvalidAddress();

        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(0)) revert InvalidAddress();
            allowedAddresses[subAccount][targets[i]] = allowed;
        }

        emit AllowedAddressesSet(subAccount, targets, allowed, block.timestamp);
    }

    // ============ Protocol Approval Management ============

    /**
     * @notice Approve a token for a whitelisted protocol
     * @param token The token to approve
     * @param target The protocol to approve for (must be whitelisted)
     * @param amount The amount to approve (must be within sub-account's maxLossBps limit)
     */
    function approveProtocol(
        address token,
        address target,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        // Check role permission
        if (!hasRole(msg.sender, DEFI_EXECUTE_ROLE)) revert Unauthorized();

        // This ensures only owner-approved protocols can receive token approvals
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        // Execute approval through the module to Safe
        bytes memory approveData = abi.encodeWithSelector(
            IERC20.approve.selector,
            target,
            amount
        );

        bool success = exec(token, 0, approveData, ISafe.Operation.Call);

        if (!success) revert ApprovalFailed();

        emit ApprovalExecuted(msg.sender, token, target, amount, block.timestamp);
    }

    // ============ Token Transfer ============

    /**
     * @notice Transfer tokens from Safe to a recipient with role-based restrictions
     * @param token The token address to transfer
     * @param recipient The recipient address
     * @param amount The amount to transfer
     * @return success Whether the transfer succeeded
     */
    function transferToken(
        address token,
        address recipient,
        uint256 amount
    ) external nonReentrant whenNotPaused returns (bool success) {
        // Check role permission
        if (!hasRole(msg.sender, DEFI_TRANSFER_ROLE)) revert Unauthorized();

        // Validate addresses
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();

        IERC20 tokenContract = IERC20(token);
        uint256 safeBalanceBefore = tokenContract.balanceOf(avatar);

        // Get sub-account specific limits (use maxWithdrawBps for transfers)
        (, uint256 maxTransferBps, , uint256 windowDuration) = getSubAccountLimits(msg.sender);

        // Reset window if expired or first time
        if (block.timestamp >= transferWindowStart[msg.sender][token] + windowDuration ||
            transferWindowStart[msg.sender][token] == 0) {
            transferredInWindow[msg.sender][token] = 0;
            transferWindowStart[msg.sender][token] = block.timestamp;
            transferWindowBalance[msg.sender][token] = safeBalanceBefore;
            emit TransferWindowReset(msg.sender, token, block.timestamp);
        }

        // Calculate cumulative limit based on balance at window start
        uint256 windowBalance = transferWindowBalance[msg.sender][token];
        uint256 cumulativeTransfer = transferredInWindow[msg.sender][token] + amount;
        uint256 maxTransfer = Math.mulDiv(windowBalance, maxTransferBps, 10000, Math.Rounding.Floor);

        if (cumulativeTransfer > maxTransfer) revert ExceedsTransferLimit();

        // Calculate percentage for monitoring
        uint256 percentageOfBalance = Math.mulDiv(amount, 10000, safeBalanceBefore, Math.Rounding.Floor);

        // Alert on unusual activity (>4% in single transaction)
        if (percentageOfBalance > 400) {
            emit UnusualActivity(
                msg.sender,
                "Large transfer percentage",
                percentageOfBalance,
                400,
                block.timestamp
            );
        }

        // Execute transfer through the module
        bytes memory transferData = abi.encodeWithSelector(
            IERC20.transfer.selector,
            recipient,
            amount
        );

        success = exec(token, 0, transferData, ISafe.Operation.Call);

        if (!success) revert TransactionFailed();

        // Verify transfer executed correctly
        uint256 safeBalanceAfter = tokenContract.balanceOf(avatar);
        uint256 actualTransferred = safeBalanceBefore - safeBalanceAfter;

        if (actualTransferred < amount) revert TransactionFailed();

        // Update cumulative tracking
        transferredInWindow[msg.sender][token] = cumulativeTransfer;

        // Emit comprehensive event
        emit TransferExecuted(
            msg.sender,
            token,
            recipient,
            amount,
            safeBalanceBefore,
            safeBalanceAfter,
            cumulativeTransfer,
            percentageOfBalance,
            block.timestamp
        );

        return success;
    }

    // ============ Generic Protocol Execution ============

    /**
     * @notice Execute arbitrary calldata on a whitelisted protocol with portfolio value tracking
     * @param target The protocol address to call
     * @param data The calldata to execute
     * @return result The return data from the call
     */
    function executeOnProtocol(
        address target,
        bytes calldata data
    ) external nonReentrant whenNotPaused returns (bytes memory result) {
        // Check role permission
        if (!hasRole(msg.sender, DEFI_EXECUTE_ROLE)) revert Unauthorized();

        // This ensures only owner-approved protocols can be executed
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        // // Get sub-account limits
        // (, , uint256 maxLossBps, uint256 windowDuration) = getSubAccountLimits(msg.sender);

        // Block raw approve/increaseAllowance calls in calldata - use approveProtocol() instead
        if (data.length >= 4) {
            bytes4 selector = bytes4(data[:4]);
            if (selector == IERC20.approve.selector || selector == bytes4(keccak256("increaseAllowance(address,uint256)"))) {
                revert ApprovalNotAllowed();
            }
        }

        // // Get portfolio value before execution
        // uint256 portfolioValueBefore = getPortfolioValue();

        // // Reset window if expired or first time
        // if (block.timestamp >= executionWindowStart[msg.sender] + windowDuration ||
        //     executionWindowStart[msg.sender] == 0) {
        //     valueLostInWindow[msg.sender] = 0;
        //     executionWindowStart[msg.sender] = block.timestamp;
        //     executionWindowPortfolioValue[msg.sender] = portfolioValueBefore;
        //     emit ExecutionWindowReset(msg.sender, block.timestamp, portfolioValueBefore);
        // }

        // Execute the call through the module
        bool success = exec(target, 0, data, ISafe.Operation.Call);

        if (!success) revert TransactionFailed();

        // // Get portfolio value after execution
        // uint256 portfolioValueAfter = getPortfolioValue();

        // // Calculate value lost (if any)
        // uint256 valueLost = 0;
        // if (portfolioValueAfter < portfolioValueBefore) {
        //     valueLost = portfolioValueBefore - portfolioValueAfter;
        // }

        // // Update cumulative loss tracking
        // uint256 cumulativeLoss = valueLostInWindow[msg.sender] + valueLost;

        // // Check against max loss limit
        // uint256 windowPortfolioValue = executionWindowPortfolioValue[msg.sender];
        // uint256 maxLoss = Math.mulDiv(windowPortfolioValue, maxLossBps, 10000, Math.Rounding.Floor);

        // if (cumulativeLoss > maxLoss) revert ExceedsMaxLoss();

        // // Update cumulative tracking
        // valueLostInWindow[msg.sender] = cumulativeLoss;

        // Emit event
        emit ProtocolExecuted(
            msg.sender,
            target,
            0,
            0,
            0,
            0,
            block.timestamp
        );

        // Note: Return data is not captured with execTransactionFromModule
        // This is a limitation of the Safe interface
        return "";
    }

    // ============ Safe Value Storage Functions ============

    /**
     * @notice Update the USD value for the Safe
     * @dev Only callable by the authorized updater (Chainlink CRE proxy)
     * @param totalValueUSD The total USD value with 18 decimals
     */
    function updateSafeValue(uint256 totalValueUSD) external {
        if (msg.sender != authorizedUpdater) revert OnlyAuthorizedUpdater();

        safeValue.totalValueUSD = totalValueUSD;
        safeValue.lastUpdated = block.timestamp;
        safeValue.updateCount += 1;

        emit SafeValueUpdated(
            totalValueUSD,
            block.timestamp,
            safeValue.updateCount
        );
    }

    /**
     * @notice Get the current USD value of the Safe
     * @return totalValueUSD The total USD value with 18 decimals
     * @return lastUpdated Timestamp of last update
     * @return updateCount Number of updates
     */
    function getSafeValue()
        external
        view
        returns (
            uint256 totalValueUSD,
            uint256 lastUpdated,
            uint256 updateCount
        )
    {
        return (
            safeValue.totalValueUSD,
            safeValue.lastUpdated,
            safeValue.updateCount
        );
    }

    /**
     * @notice Check if the Safe value is stale (not updated in specified time)
     * @param maxAge Maximum age in seconds before considered stale
     * @return isStale True if the data is stale
     */
    function isValueStale(uint256 maxAge)
        external
        view
        returns (bool isStale)
    {
        if (safeValue.lastUpdated == 0) return true; // Never updated
        return (block.timestamp - safeValue.lastUpdated) > maxAge;
    }

    /**
     * @notice Set the authorized updater address
     * @dev Only callable by the owner (Safe)
     * @param newUpdater The new authorized updater address
     */
    function setAuthorizedUpdater(address newUpdater) external onlyOwner {
        if (newUpdater == address(0)) revert InvalidUpdaterAddress();
        address oldUpdater = authorizedUpdater;
        authorizedUpdater = newUpdater;
        emit AuthorizedUpdaterChanged(oldUpdater, newUpdater);
    }
}
