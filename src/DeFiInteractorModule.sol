// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Module} from "./base/Module.sol";
import {IMorphoVault} from "./interfaces/IMorphoVault.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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

    /// @notice Default maximum percentage of portfolio value loss allowed per window (basis points)
    uint256 public constant DEFAULT_MAX_LOSS_BPS = 500; // 5%

    /// @notice Default maximum percentage of assets a sub-account can transfer (basis points)
    uint256 public constant DEFAULT_MAX_TRANSFER_BPS = 1000; // 1%

    /// @notice Default time window for cumulative limit tracking (24 hours)
    uint256 public constant DEFAULT_LIMIT_WINDOW_DURATION = 1 days;

    /// @notice Configuration for sub-account limits
    struct SubAccountLimits {
        uint256 maxLossBps;         // Maximum portfolio value loss in basis points
        uint256 maxTransferBps;     // Maximum portfolio value transfer in basis points        
        uint256 windowDuration;     // Time window duration in seconds
        bool isConfigured;          // Whether limits have been explicitly set
    }

    /// @notice Per-sub-account limit configuration
    mapping(address => SubAccountLimits) public subAccountLimits;

    /// @notice Portfolio value at start of execution window: subAccount => value
    mapping(address => uint256) public executionWindowPortfolioValue;

    /// @notice Window start time for executions: subAccount => timestamp
    mapping(address => uint256) public executionWindowStart;

    /// @notice Cumulative USD value approved in current window: subAccount => amount (18 decimals)
    mapping(address => uint256) public valueApprovedInWindow;

    /// @notice Cumulative USD value transferred in current window: subAccount => amount (18 decimals)
    mapping(address => uint256) public valueTransferredInWindow;

    /// @notice Maximum age for SafeValue before it's considered stale (default: 15 minutes)
    uint256 public maxSafeValueAge = 15 minutes;

    /// @notice Maximum age for Chainlink price feed data (default: 24 hours)
    uint256 public maxPriceFeedAge = 24 hours;

    /// @notice Mapping of token address to Chainlink price feed
    mapping(address => AggregatorV3Interface) public tokenPriceFeeds;

    /// @notice Per-sub-account allowed addresses: subAccount => target address => allowed
    mapping(address => mapping(address => bool)) public allowedAddresses;

    /// @notice roles => subAccount[]
    mapping(uint16 => address[]) public subaccount;

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
        uint256 maxLossBps,
        uint256 maxTransferBps,
        uint256 windowDuration,
        uint256 timestamp
    );

    event ProtocolExecuted(
        address indexed subAccount,
        address indexed target,
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

    event PortfolioWindowReset(
        address indexed subAccount,
        uint256 newWindowStart,
        uint256 portfolioValueUSD,
        uint256 timestamp
    );

    event ApprovalValueChecked(
        address indexed subAccount,
        address indexed token,
        uint256 approvalAmountUSD,
        uint256 cumulativeApprovedUSD,
        uint256 portfolioValueUSD,
        uint256 limitBps
    );

    event TransferValueChecked(
        address indexed subAccount,
        address indexed token,
        uint256 transferAmountUSD,
        uint256 cumulativeTransferredUSD,
        uint256 portfolioValueUSD,
        uint256 limitBps
    );

    event MaxSafeValueAgeUpdated(
        uint256 oldAge,
        uint256 newAge
    );

    event MaxPriceFeedAgeUpdated(
        uint256 oldAge,
        uint256 newAge
    );

    event TokenPriceFeedSet(
        address indexed token,
        address indexed priceFeed
    );

    event TokenPriceFeedRemoved(
        address indexed token
    );

    event SubaccountAllowancesUpdated(
        address indexed subAccount,
        uint256 balanceChange,
        uint256 newApprovedAllowance,
        uint256 timestamp
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
    error StalePortfolioValue();
    error ExceedsApprovalLimit();
    error ExceedsPortfolioLimit();
    error InvalidPriceFeed();
    error StalePriceFeed();
    error InvalidPrice();
    error NoPriceFeedSet();

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

        // Only add to array if member doesn't already have this role
        if (!subAccountRoles[member][roleId]) {
            subAccountRoles[member][roleId] = true;
            subaccount[roleId].push(member);
            emit RoleAssigned(member, roleId, block.timestamp);
        }
    }

    /**
     * @notice Revoke a role from a sub-account (only owner can do this)
     * @param member The address to revoke the role from
     * @param roleId The role ID to revoke
     */
    function revokeRole(address member, uint16 roleId) external onlyOwner {
        if (member == address(0)) revert InvalidAddress();

        // Only remove if member currently has this role
        if (subAccountRoles[member][roleId]) {
            subAccountRoles[member][roleId] = false;
            _removeFromSubaccountArray(roleId, member);
            emit RoleRevoked(member, roleId, block.timestamp);
        }
    }

    /**
     * @notice Internal function to remove an address from the subaccount array
     * @param roleId The role ID
     * @param member The address to remove
     */
    function _removeFromSubaccountArray(uint16 roleId, address member) internal {
        address[] storage accounts = subaccount[roleId];
        uint256 length = accounts.length;

        for (uint256 i = 0; i < length; i++) {
            if (accounts[i] == member) {
                // Move last element to this position and pop
                accounts[i] = accounts[length - 1];
                accounts.pop();
                break;
            }
        }
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

    /**
     * @notice Get all sub-accounts for a specific role
     * @param roleId The role ID to query
     * @return address[] Array of addresses that have this role
     */
    function getSubaccountsByRole(uint16 roleId) external view returns (address[] memory) {
        return subaccount[roleId];
    }

    /**
     * @notice Get the count of sub-accounts for a specific role
     * @param roleId The role ID to query
     * @return uint256 Number of addresses that have this role
     */
    function getSubaccountCount(uint16 roleId) external view returns (uint256) {
        return subaccount[roleId].length;
    }

    // ============ Sub-Account Configuration ============

    /**
     * @notice Set custom limits for a sub-account (only owner can call)
     * @param subAccount The sub-account address to configure
     * @param maxLossBps Maximum portfolio loss percentage in basis points (max 10000)
     * @param maxTransferBps Maximum transfer percentage in basis points (max 10000)
     * @param windowDuration Time window duration in seconds (min 1 hour)
     */
    function setSubAccountLimits(
        address subAccount,
        uint256 maxLossBps,
        uint256 maxTransferBps,
        uint256 windowDuration
    ) external onlyOwner {
        if (subAccount == address(0)) revert InvalidAddress();
        // Validate limits: BPS cannot exceed 100%, window must be at least 1 hour
        if (maxLossBps > 10000 || maxTransferBps > 10000 || windowDuration < 1 hours) {
            revert InvalidLimitConfiguration();
        }

        subAccountLimits[subAccount] = SubAccountLimits({
            maxLossBps: maxLossBps,
            maxTransferBps: maxTransferBps,
            windowDuration: windowDuration,
            isConfigured: true
        });

        emit SubAccountLimitsSet(
            subAccount,
            maxLossBps,
            maxTransferBps,
            windowDuration,
            block.timestamp
        );
    }

    /**
     * @notice Get the effective limits for a sub-account
     * @param subAccount The sub-account address
     * @return maxLossBps The maximum portfolio loss percentage in basis points
     * @return maxTransferBps The maximum transfer percentage in basis points
     * @return windowDuration The time window duration in seconds
     */
    function getSubAccountLimits(address subAccount) public view returns (
        uint256 maxLossBps,
        uint256 maxTransferBps,
        uint256 windowDuration
    ) {
        SubAccountLimits memory limits = subAccountLimits[subAccount];
        if (limits.isConfigured) {
            return (limits.maxLossBps, limits.maxTransferBps, limits.windowDuration);
        }
        // Return defaults if not configured
        return (DEFAULT_MAX_LOSS_BPS, DEFAULT_MAX_TRANSFER_BPS, DEFAULT_LIMIT_WINDOW_DURATION);
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

        // Reset portfolio window if needed
        _resetPortfolioWindowIfNeeded(msg.sender);

        // Estimate USD value of the approval amount
        uint256 approvalValueUSD = _estimateTokenValueUSD(token, amount);

        // Get sub-account limits
        (uint256 maxLossBps, , ) = getSubAccountLimits(msg.sender);

        // Get current portfolio value and calculate limit
        uint256 portfolioValue = executionWindowPortfolioValue[msg.sender];
        uint256 maxApprovalValue = Math.mulDiv(portfolioValue, maxLossBps, 10000, Math.Rounding.Floor);

        // Update cumulative approved value
        uint256 newCumulativeApproved = valueApprovedInWindow[msg.sender] + approvalValueUSD;

        // Check if approval exceeds limit
        if (newCumulativeApproved > maxApprovalValue) revert ExceedsApprovalLimit();

        // Update tracking
        valueApprovedInWindow[msg.sender] = newCumulativeApproved;

        // Emit tracking event
        emit ApprovalValueChecked(
            msg.sender,
            token,
            approvalValueUSD,
            newCumulativeApproved,
            portfolioValue,
            maxLossBps
        );

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

        // Get sub-account specific limits (use maxTransferBps for transfers)
        (, uint256 maxTransferBps, uint256 windowDuration) = getSubAccountLimits(msg.sender);

        // Reset portfolio window if needed
        _resetPortfolioWindowIfNeeded(msg.sender);

        // Estimate USD value of the transfer amount
        uint256 transferValueUSD = _estimateTokenValueUSD(token, amount);

        // Get current portfolio value and calculate USD limit
        uint256 portfolioValue = executionWindowPortfolioValue[msg.sender];
        uint256 maxTransferValueUSD = Math.mulDiv(portfolioValue, maxTransferBps, 10000, Math.Rounding.Floor);

        // Update cumulative transferred value (USD)
        uint256 newCumulativeTransferredUSD = valueTransferredInWindow[msg.sender] + transferValueUSD;

        // Check if transfer exceeds USD limit
        if (newCumulativeTransferredUSD > maxTransferValueUSD) revert ExceedsPortfolioLimit();

        // Update tracking
        valueTransferredInWindow[msg.sender] = newCumulativeTransferredUSD;

        // Emit tracking event
        emit TransferValueChecked(
            msg.sender,
            token,
            transferValueUSD,
            newCumulativeTransferredUSD,
            portfolioValue,
            maxTransferBps
        );

        // Reset token-specific window if expired or first time (for per-token tracking)
        if (block.timestamp >= transferWindowStart[msg.sender][token] + windowDuration ||
            transferWindowStart[msg.sender][token] == 0) {
            transferredInWindow[msg.sender][token] = 0;
            transferWindowStart[msg.sender][token] = block.timestamp;
            transferWindowBalance[msg.sender][token] = safeBalanceBefore;
            emit TransferWindowReset(msg.sender, token, block.timestamp);
        }

        // Calculate cumulative limit based on balance at window start (per-token check)
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

        // Block raw approve/increaseAllowance calls in calldata - use approveProtocol() instead
        if (data.length >= 4) {
            bytes4 selector = bytes4(data[:4]);
            if (selector == IERC20.approve.selector || selector == bytes4(keccak256("increaseAllowance(address,uint256)"))) {
                revert ApprovalNotAllowed();
            }
        }

        // Execute the call through the module
        bool success = exec(target, 0, data, ISafe.Operation.Call);

        if (!success) revert TransactionFailed();

        // Emit event
        emit ProtocolExecuted(
            msg.sender,
            target,
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

    /**
     * @notice Set the maximum age for Safe value before considered stale
     * @dev Only callable by the owner (Safe)
     * @param newMaxAge The new maximum age in seconds
     */
    function setMaxSafeValueAge(uint256 newMaxAge) external onlyOwner {
        uint256 oldAge = maxSafeValueAge;
        maxSafeValueAge = newMaxAge;
        emit MaxSafeValueAgeUpdated(oldAge, newMaxAge);
    }

    /**
     * @notice Set the maximum age for Chainlink price feed data
     * @dev Only callable by the owner (Safe)
     * @param newMaxAge The new maximum age in seconds
     */
    function setMaxPriceFeedAge(uint256 newMaxAge) external onlyOwner {
        uint256 oldAge = maxPriceFeedAge;
        maxPriceFeedAge = newMaxAge;
        emit MaxPriceFeedAgeUpdated(oldAge, newMaxAge);
    }

    /**
     * @notice Set the Chainlink price feed for a token
     * @dev Only callable by the owner (Safe)
     * @param token The token address
     * @param priceFeed The Chainlink price feed address
     */
    function setTokenPriceFeed(address token, address priceFeed) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        if (priceFeed == address(0)) revert InvalidPriceFeed();
        tokenPriceFeeds[token] = AggregatorV3Interface(priceFeed);
        emit TokenPriceFeedSet(token, priceFeed);
    }

    /**
     * @notice Set multiple token price feeds at once
     * @dev Only callable by the owner (Safe)
     * @param tokens Array of token addresses
     * @param priceFeeds Array of Chainlink price feed addresses
     */
    function setTokenPriceFeeds(address[] calldata tokens, address[] calldata priceFeeds) external onlyOwner {
        if (tokens.length != priceFeeds.length) revert InvalidLimitConfiguration();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) revert InvalidAddress();
            if (priceFeeds[i] == address(0)) revert InvalidPriceFeed();
            tokenPriceFeeds[tokens[i]] = AggregatorV3Interface(priceFeeds[i]);
            emit TokenPriceFeedSet(tokens[i], priceFeeds[i]);
        }
    }

    /**
     * @notice Remove the price feed for a token
     * @dev Only callable by the owner (Safe)
     * @param token The token address
     */
    function removeTokenPriceFeed(address token) external onlyOwner {
        delete tokenPriceFeeds[token];
        emit TokenPriceFeedRemoved(token);
    }

    // ============ Portfolio Value Tracking ============

    /**
     * @notice Get current portfolio value and ensure it's not stale
     * @return portfolioValueUSD Current portfolio value in USD with 18 decimals
     */
    function _getPortfolioValue() internal view returns (uint256 portfolioValueUSD) {
        if (safeValue.lastUpdated == 0) revert StalePortfolioValue();
        if (block.timestamp - safeValue.lastUpdated > maxSafeValueAge) {
            revert StalePortfolioValue();
        }
        return safeValue.totalValueUSD;
    }

    /**
     * @notice Reset portfolio tracking window for a sub-account if expired
     * @param subAccount The sub-account address
     */
    function _resetPortfolioWindowIfNeeded(address subAccount) internal {
        (, , uint256 windowDuration) = getSubAccountLimits(subAccount);

        if (block.timestamp >= executionWindowStart[subAccount] + windowDuration ||
            executionWindowStart[subAccount] == 0) {

            uint256 currentPortfolioValue = _getPortfolioValue();

            executionWindowStart[subAccount] = block.timestamp;
            executionWindowPortfolioValue[subAccount] = currentPortfolioValue;
            valueApprovedInWindow[subAccount] = 0;
            valueTransferredInWindow[subAccount] = 0;

            emit PortfolioWindowReset(
                subAccount,
                block.timestamp,
                currentPortfolioValue,
                block.timestamp
            );
        }
    }

    /**
     * @notice Calculate USD value of a token amount using Chainlink price feeds
     * @dev Requires price feed to be set for the token
     * @param token The token address
     * @param amount The token amount (in token's native decimals)
     * @return valueUSD The USD value with 18 decimals
     */
    function _estimateTokenValueUSD(address token, uint256 amount) internal view returns (uint256 valueUSD) {
        if (amount == 0) return 0;

        // Get price feed for token
        AggregatorV3Interface priceFeed = tokenPriceFeeds[token];
        if (address(priceFeed) == address(0)) revert NoPriceFeedSet();

        // Get latest price data
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // Validate price data
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert StalePriceFeed();
        if (answeredInRound < roundId) revert StalePriceFeed();
        if (block.timestamp - updatedAt > maxPriceFeedAge) revert StalePriceFeed();

        // Get price feed decimals (usually 8 for USD feeds)
        uint8 priceDecimals = priceFeed.decimals();
        uint256 price = uint256(answer);

        // Get token decimals
        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        // Calculate USD value with 18 decimals
        // Formula: (amount * price * 10^18) / (10^tokenDecimals * 10^priceDecimals)
        valueUSD = Math.mulDiv(
            amount * price,
            10 ** 18,
            10 ** uint256(tokenDecimals + priceDecimals),
            Math.Rounding.Ceil  // Round up for conservative estimates
        );
    }

    /**
     * @notice Get the Safe's balance for multiple tokens
     * @dev Returns the balance of the Safe (avatar) for each token in the array
     * @param tokens Array of token addresses to query
     * @return balances Array of balances corresponding to each token
     */
    function getTokenBalances(address[] calldata tokens)
        external
        view
        returns (uint256[] memory balances)
    {
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balances[i] = IERC20(tokens[i]).balanceOf(avatar);
        }
        return balances;
    }

    /**
     * @notice Update subaccount allowances after a Safe Inflow
     * @dev Only callable by the authorized updater (oracle)
     * @param subAccount The subaccount address to update
     * @param balanceChange The inflow in dollars
     */
    function updateSubaccountAllowances(
        address subAccount,
        uint256 balanceChange
    ) external {
        if (msg.sender != authorizedUpdater) revert OnlyAuthorizedUpdater();
        if (subAccount == address(0)) revert InvalidAddress();

        // Only update if the subaccount has an active execution window
        if (executionWindowStart[subAccount] == 0) return;

        // Get the subaccount's limits
        (uint256 maxLossBps, , ) = getSubAccountLimits(subAccount);

        // Get current window portfolio value
        uint256 windowPortfolioValue = executionWindowPortfolioValue[subAccount];

        // Calculate total allowances based on window portfolio value
        uint256 totalApprovalAllowance = Math.mulDiv(windowPortfolioValue, maxLossBps, 10000, Math.Rounding.Floor);

        // Calculate current remaining allowances
        uint256 remainingApprovalAllowance = totalApprovalAllowance > valueApprovedInWindow[subAccount]
            ? totalApprovalAllowance - valueApprovedInWindow[subAccount]
            : 0;

        // Calculate new remaining allowances after balance change
        // If balance increased (positive change), add to remaining allowance
        // If balance decreased (negative change), subtract from remaining allowance
        uint256 newRemainingApprovalAllowance;

        if (balanceChange == 0) return;

        // Balance increased - add the change to remaining allowances
        newRemainingApprovalAllowance = remainingApprovalAllowance + uint256(balanceChange);

        // Cap the new remaining allowance at the total allowance
        newRemainingApprovalAllowance = Math.min(newRemainingApprovalAllowance, totalApprovalAllowance);

        // Calculate the new used amounts by subtracting new remaining from total
        uint256 newApprovedInWindow = totalApprovalAllowance - newRemainingApprovalAllowance;

        // Update the state
        valueApprovedInWindow[subAccount] = newApprovedInWindow;

        emit SubaccountAllowancesUpdated(
            subAccount,
            balanceChange,
            newApprovedInWindow,
            block.timestamp
        );
    }
}
