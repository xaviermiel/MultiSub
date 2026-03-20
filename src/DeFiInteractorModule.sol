// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Module} from "./base/Module.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {ICalldataParser} from "./interfaces/ICalldataParser.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title DeFiInteractorModule
 * @notice Custom Zodiac module for executing DeFi operations with spending limits
 * @dev Implements the Acquired Balance Model for flexible spending control
 *      - Original tokens (in Safe at window start) cost spending to use
 *      - Acquired tokens (from operations) are free to use
 *      - Spending is one-way: consumed by deposits/swaps, never recovered
 */
contract DeFiInteractorModule is Module, ReentrancyGuard, Pausable {
    // ============ Constants ============

    /// @notice Role ID for generic protocol execution
    uint16 public constant DEFI_EXECUTE_ROLE = 1;

    /// @notice Role ID for token transfers
    uint16 public constant DEFI_TRANSFER_ROLE = 2;

    /// @notice Role ID for debt repayment (no spending check)
    uint16 public constant DEFI_REPAY_ROLE = 3;

    /// @notice Default maximum spending percentage per window (basis points)
    uint256 public constant DEFAULT_MAX_SPENDING_BPS = 500; // 5%

    /// @notice Default time window for spending limits (24 hours)
    uint256 public constant DEFAULT_WINDOW_DURATION = 1 days;

    // ============ Operation Type Classification ============

    /// @notice Operation types for selector-based classification
    enum OperationType {
        UNKNOWN, // Must revert - unregistered selector
        SWAP, // Costs spending (from original), output is acquired
        DEPOSIT, // Costs spending (from original), tracked for withdrawal matching
        WITHDRAW, // FREE, output becomes acquired if matched to deposit
        CLAIM, // FREE, output becomes acquired if matched to deposit (same as WITHDRAW)
        APPROVE, // FREE but capped, enables future operations
        REPAY // Requires DEFI_REPAY_ROLE, no spending check
    }

    /// @notice Registered operation type for each function selector
    mapping(bytes4 => OperationType) public selectorType;

    /// @notice Parser contract for each protocol
    mapping(address => ICalldataParser) public protocolParsers;

    // ============ Oracle-Managed State ============

    /// @notice Spending allowance per sub-account (set by oracle, USD with 18 decimals)
    mapping(address => uint256) public spendingAllowance;

    /// @notice Acquired (free-to-use) balance per sub-account per token
    mapping(address => mapping(address => uint256)) public acquiredBalance;

    /// @notice Authorized oracle address (Chainlink CRE)
    address public authorizedOracle;

    /// @notice Last oracle update timestamp per sub-account
    mapping(address => uint256) public lastOracleUpdate;

    /// @notice Maximum age for oracle data before operations are blocked
    uint256 public maxOracleAge = 60 minutes;

    // ============ Safe Value Storage ============

    /// @notice Struct to store Safe's USD value data
    struct SafeValue {
        uint256 totalValueUSD; // Total USD value with 18 decimals
        uint256 lastUpdated; // Timestamp of last update
        uint256 updateCount; // Number of updates received
    }

    /// @notice Safe's current USD value
    SafeValue public safeValue;

    /// @notice Maximum age for Safe value before considered stale
    uint256 public maxSafeValueAge = 60 minutes;

    /// @notice Absolute maximum spending percentage (safety backstop, oracle cannot exceed)
    /// @dev Default 20% (2000 basis points). Even if oracle is compromised, cannot exceed this.
    uint256 public absoluteMaxSpendingBps = 2000;

    // ============ Sub-Account Configuration ============

    /// @notice Configuration for sub-account limits (dual-mode: BPS or fixed USD)
    /// @dev Exactly one of maxSpendingBps or maxSpendingUSD must be non-zero
    struct SubAccountLimits {
        uint256 maxSpendingBps; // Maximum spending in basis points (% of Safe value)
        uint256 maxSpendingUSD; // Maximum spending in USD (18 decimals, fixed amount)
        uint256 windowDuration; // Time window duration in seconds
        bool isConfigured; // Whether limits have been explicitly set
    }

    /// @notice Per-sub-account limit configuration
    mapping(address => SubAccountLimits) public subAccountLimits;

    // ============ On-Chain Cumulative Spending Tracker ============

    /// @notice Start of the current spending window per sub-account
    mapping(address => uint256) public windowStart;

    /// @notice Safe value snapshot at window start per sub-account
    mapping(address => uint256) public windowSafeValue;

    /// @notice Cumulative spending in current window per sub-account (USD with 18 decimals)
    mapping(address => uint256) public cumulativeSpent;

    // ============ Oracle Acquired Budget ============

    /// @notice Start of oracle acquired grant window per sub-account
    mapping(address => uint256) public acquiredGrantWindowStart;

    /// @notice Cumulative USD value of oracle-granted acquired increases per window
    mapping(address => uint256) public cumulativeOracleGrantedUSD;

    /// @notice Maximum percentage of safe value the oracle can grant as acquired per window (basis points)
    /// @dev Default 20% (2000 bps). Limits oracle's ability to inflate acquired balances.
    uint256 public maxOracleAcquiredBps = 2000;

    /// @notice Per-sub-account allowed addresses: subAccount => target => allowed
    mapping(address => mapping(address => bool)) public allowedAddresses;

    /// @notice Sub-account roles: subAccount => role => has role
    mapping(address => mapping(uint16 => bool)) public subAccountRoles;

    /// @notice Role members: role => subAccount[]
    mapping(uint16 => address[]) public subaccounts;

    // ============ Price Feeds ============

    /// @notice Chainlink price feed per token
    mapping(address => AggregatorV3Interface) public tokenPriceFeeds;

    /// @notice Maximum age for Chainlink price feed data
    uint256 public maxPriceFeedAge = 24 hours;

    // ============ Events ============

    event RoleAssigned(address indexed member, uint16 indexed roleId);
    event RoleRevoked(address indexed member, uint16 indexed roleId);

    event SubAccountLimitsSet(
        address indexed subAccount, uint256 maxSpendingBps, uint256 maxSpendingUSD, uint256 windowDuration
    );

    event AllowedAddressesSet(address indexed subAccount, address[] targets, bool allowed);

    /// @notice Emitted on every protocol interaction (for oracle consumption)
    event ProtocolExecution(
        address indexed subAccount,
        address indexed target,
        OperationType opType,
        address[] tokensIn,
        uint256[] amountsIn,
        address[] tokensOut,
        uint256[] amountsOut,
        uint256 spendingCost
    );

    event TransferExecuted(
        address indexed subAccount,
        address indexed token,
        address indexed recipient,
        uint256 amount,
        uint256 spendingCost
    );

    event SafeValueUpdated(uint256 totalValueUSD, uint256 updateCount);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    event SpendingAllowanceUpdated(address indexed subAccount, uint256 newAllowance);

    event AcquiredBalanceUpdated(address indexed subAccount, address indexed token, uint256 newBalance);

    event SelectorRegistered(bytes4 indexed selector, OperationType opType);
    event SelectorUnregistered(bytes4 indexed selector);
    event ParserRegistered(address indexed protocol, address parser);

    event CumulativeSpendingReset(address indexed subAccount, uint256 windowSafeValue);
    event OracleAcquiredBudgetReset(address indexed subAccount);

    event EmergencyPaused(address indexed by);
    event EmergencyUnpaused(address indexed by);

    // ============ Errors ============

    error UnknownSelector(bytes4 selector);
    error TransactionFailed();
    error ApprovalFailed();
    error InvalidLimitConfiguration();
    error AddressNotAllowed();
    error ExceedsSpendingLimit();
    error OnlyAuthorizedOracle();
    error InvalidOracleAddress();
    error StaleOracleData();
    error StalePortfolioValue();
    error InvalidPriceFeed();
    error StalePriceFeed();
    error InvalidPrice();
    error NoPriceFeedSet();
    error ApprovalExceedsLimit();
    error SpenderNotAllowed();
    error NoParserRegistered(address target);
    error ExceedsAbsoluteMaxSpending(uint256 requested, uint256 maximum);
    error CannotRegisterUnknown();
    error LengthMismatch();
    error ExceedsMaxBps();
    error InvalidRecipient(address recipient, address expected);
    error CannotBeSubaccount(address account);
    error CannotBeOracle(address account);
    error CannotWhitelistCoreAddress(address account);
    error CannotRegisterParserForCoreAddress(address account);
    error BothLimitModesSet();
    error NeitherLimitModeSet();
    error ExceedsCumulativeSpendingLimit(uint256 cumulative, uint256 maximum);
    error ExceedsOracleAcquiredBudget(uint256 cumulative, uint256 maximum);

    // ============ Modifiers ============

    modifier onlyOracle() {
        if (msg.sender != authorizedOracle) revert OnlyAuthorizedOracle();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initialize the DeFi Interactor Module
     * @param _avatar The Safe address (avatar)
     * @param _owner The owner address (typically the Safe itself)
     * @param _authorizedOracle The Chainlink CRE address authorized to update state
     */
    constructor(address _avatar, address _owner, address _authorizedOracle) Module(_avatar, _avatar, _owner) {
        if (_authorizedOracle == address(0)) revert InvalidOracleAddress();
        authorizedOracle = _authorizedOracle;
    }

    // ============ Emergency Controls ============

    function pause() external onlyOwner {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    // ============ Role Management ============

    function grantRole(address member, uint16 roleId) external onlyOwner {
        if (member == address(0)) revert InvalidAddress();
        // Prevent Safe, Module, and Oracle from being subaccounts
        if (member == avatar || member == address(this)) {
            revert CannotBeSubaccount(member);
        }
        if (member == authorizedOracle) revert CannotBeSubaccount(member);
        if (!subAccountRoles[member][roleId]) {
            subAccountRoles[member][roleId] = true;
            subaccounts[roleId].push(member);
            emit RoleAssigned(member, roleId);
        }
    }

    function revokeRole(address member, uint16 roleId) external onlyOwner {
        if (member == address(0)) revert InvalidAddress();
        if (subAccountRoles[member][roleId]) {
            subAccountRoles[member][roleId] = false;
            _removeFromSubaccountArray(roleId, member);
            emit RoleRevoked(member, roleId);
        }
    }

    function _removeFromSubaccountArray(uint16 roleId, address member) internal {
        address[] storage accounts = subaccounts[roleId];
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length; i++) {
            if (accounts[i] == member) {
                accounts[i] = accounts[length - 1];
                accounts.pop();
                break;
            }
        }
    }

    function hasRole(address member, uint16 roleId) public view returns (bool) {
        return subAccountRoles[member][roleId];
    }

    function getSubaccountsByRole(uint16 roleId) external view returns (address[] memory) {
        return subaccounts[roleId];
    }

    function getSubaccountCount(uint16 roleId) external view returns (uint256) {
        return subaccounts[roleId].length;
    }

    // ============ Selector Registry ============

    /**
     * @notice Register a function selector with its operation type
     * @param selector The function selector (first 4 bytes of calldata)
     * @param opType The operation type classification
     */
    function registerSelector(bytes4 selector, OperationType opType) external onlyOwner {
        if (opType == OperationType.UNKNOWN) revert CannotRegisterUnknown();
        selectorType[selector] = opType;
        emit SelectorRegistered(selector, opType);
    }

    /**
     * @notice Unregister a function selector
     * @param selector The function selector to unregister
     */
    function unregisterSelector(bytes4 selector) external onlyOwner {
        delete selectorType[selector];
        emit SelectorUnregistered(selector);
    }

    /**
     * @notice Register a parser for a protocol
     * @param protocol The protocol address
     * @param parser The parser contract address
     */
    function registerParser(address protocol, address parser) external onlyOwner {
        // Prevent registering parser for Safe or Module (could enable self-calls)
        if (protocol == avatar || protocol == address(this)) {
            revert CannotRegisterParserForCoreAddress(protocol);
        }
        protocolParsers[protocol] = ICalldataParser(parser);
        emit ParserRegistered(protocol, parser);
    }

    // ============ Sub-Account Configuration ============

    /// @notice Set spending limits for a sub-account (dual-mode: BPS or fixed USD)
    /// @dev Exactly one of maxSpendingBps or maxSpendingUSD must be non-zero.
    ///      BPS mode: limit = percentage of Safe value. USD mode: limit = fixed dollar amount.
    /// @param subAccount The sub-account address
    /// @param maxSpendingBps Maximum spending in basis points (0 to use USD mode)
    /// @param maxSpendingUSD Maximum spending in USD with 18 decimals (0 to use BPS mode)
    /// @param windowDuration Time window duration in seconds (minimum 1 hour)
    function setSubAccountLimits(
        address subAccount,
        uint256 maxSpendingBps,
        uint256 maxSpendingUSD,
        uint256 windowDuration
    ) external onlyOwner {
        if (subAccount == address(0)) revert InvalidAddress();
        if (subAccount == avatar || subAccount == address(this)) {
            revert CannotBeSubaccount(subAccount);
        }
        if (maxSpendingBps > 0 && maxSpendingUSD > 0) {
            revert BothLimitModesSet();
        }
        if (maxSpendingBps == 0 && maxSpendingUSD == 0) {
            revert NeitherLimitModeSet();
        }
        if (maxSpendingBps > 10000 || windowDuration < 1 hours) {
            revert InvalidLimitConfiguration();
        }

        subAccountLimits[subAccount] = SubAccountLimits({
            maxSpendingBps: maxSpendingBps,
            maxSpendingUSD: maxSpendingUSD,
            windowDuration: windowDuration,
            isConfigured: true
        });

        // Cap spending allowance to new maximum if it exceeds it
        // Only cap if Safe value is fresh (stale value could be dangerously outdated)
        if (
            safeValue.totalValueUSD > 0 && safeValue.lastUpdated > 0
                && block.timestamp - safeValue.lastUpdated <= maxSafeValueAge
        ) {
            uint256 newMaxAllowance;
            if (maxSpendingUSD > 0) {
                newMaxAllowance = maxSpendingUSD;
            } else {
                newMaxAllowance = (safeValue.totalValueUSD * maxSpendingBps) / 10000;
            }
            if (spendingAllowance[subAccount] > newMaxAllowance) {
                spendingAllowance[subAccount] = newMaxAllowance;
                emit SpendingAllowanceUpdated(subAccount, newMaxAllowance);
            }
        }

        emit SubAccountLimitsSet(subAccount, maxSpendingBps, maxSpendingUSD, windowDuration);
    }

    /// @notice Get the spending limits for a sub-account
    /// @return maxSpendingBps Basis points limit (0 if in USD mode)
    /// @return maxSpendingUSD Fixed USD limit with 18 decimals (0 if in BPS mode)
    /// @return windowDuration Time window in seconds
    function getSubAccountLimits(address subAccount)
        public
        view
        returns (uint256 maxSpendingBps, uint256 maxSpendingUSD, uint256 windowDuration)
    {
        SubAccountLimits memory limits = subAccountLimits[subAccount];
        if (limits.isConfigured) {
            return (limits.maxSpendingBps, limits.maxSpendingUSD, limits.windowDuration);
        }
        return (DEFAULT_MAX_SPENDING_BPS, 0, DEFAULT_WINDOW_DURATION);
    }

    function setAllowedAddresses(address subAccount, address[] calldata targets, bool allowed) external onlyOwner {
        if (subAccount == address(0)) revert InvalidAddress();
        for (uint256 i = 0; i < targets.length; i++) {
            // Prevent whitelisting Safe or Module as targets
            if (targets[i] == avatar || targets[i] == address(this)) {
                revert CannotWhitelistCoreAddress(targets[i]);
            }
            if (targets[i] == address(0)) revert InvalidAddress();
            allowedAddresses[subAccount][targets[i]] = allowed;
        }
        emit AllowedAddressesSet(subAccount, targets, allowed);
    }

    // ============ Main Entry Point ============

    /**
     * @notice Execute a protocol interaction with automatic operation classification
     * @param target The protocol address to call
     * @param data The calldata to execute
     * @dev Token and amount are extracted from calldata via registered parsers
     */
    function executeOnProtocol(address target, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        returns (bytes memory)
    {
        // 1. Classify operation first (needed to determine which role to check)
        OperationType opType = _classifyOperation(target, data);

        // 2. Validate permissions based on operation type
        if (opType == OperationType.REPAY) {
            // REPAY uses its own role — does not require DEFI_EXECUTE_ROLE
            if (!hasRole(msg.sender, DEFI_REPAY_ROLE)) revert Unauthorized();
            _requireFreshOracle(msg.sender);
            if (!allowedAddresses[msg.sender][target]) {
                revert AddressNotAllowed();
            }
            return _executeRepay(msg.sender, target, data);
        }

        // All other operations require DEFI_EXECUTE_ROLE
        if (!hasRole(msg.sender, DEFI_EXECUTE_ROLE)) revert Unauthorized();
        _requireFreshOracle(msg.sender);

        // 3. Route based on type
        // Note: APPROVE skips allowedAddresses check on target (the token) since
        // _executeApproveWithCap validates the spender is whitelisted
        if (opType == OperationType.UNKNOWN) {
            revert UnknownSelector(bytes4(data[:4]));
        } else if (opType == OperationType.APPROVE) {
            return _executeApproveWithCap(msg.sender, target, data);
        }

        // All other operations require target to be whitelisted
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        if (opType == OperationType.WITHDRAW || opType == OperationType.CLAIM) {
            return _executeNoSpendingCheck(msg.sender, target, data, opType, 0);
        } else if (opType == OperationType.DEPOSIT || opType == OperationType.SWAP) {
            return _executeWithSpendingCheck(msg.sender, target, data, opType, 0);
        }

        revert UnknownSelector(bytes4(data[:4]));
    }

    /**
     * @notice Execute a protocol interaction with ETH value
     * @param target The protocol address to call
     * @param data The calldata to execute
     * @param value The ETH value the Safe should send with the call
     * @dev The value parameter instructs the Safe to send ETH from its own balance.
     *      This function is NOT payable — do not send ETH to the module.
     */
    function executeOnProtocolWithValue(address target, bytes calldata data, uint256 value)
        external
        nonReentrant
        whenNotPaused
        returns (bytes memory)
    {
        // 1. Classify operation first (needed to determine which role to check)
        OperationType opType = _classifyOperation(target, data);

        // 2. Validate permissions based on operation type
        if (opType == OperationType.REPAY) {
            if (!hasRole(msg.sender, DEFI_REPAY_ROLE)) revert Unauthorized();
            _requireFreshOracle(msg.sender);
            if (!allowedAddresses[msg.sender][target]) {
                revert AddressNotAllowed();
            }
            return _executeRepay(msg.sender, target, data);
        }

        // All other operations require DEFI_EXECUTE_ROLE
        if (!hasRole(msg.sender, DEFI_EXECUTE_ROLE)) revert Unauthorized();
        _requireFreshOracle(msg.sender);

        // 3. Route based on type
        if (opType == OperationType.UNKNOWN) {
            revert UnknownSelector(bytes4(data[:4]));
        } else if (opType == OperationType.APPROVE) {
            return _executeApproveWithCap(msg.sender, target, data);
        }

        // All other operations require target to be whitelisted
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        if (opType == OperationType.WITHDRAW || opType == OperationType.CLAIM) {
            return _executeNoSpendingCheck(msg.sender, target, data, opType, value);
        } else if (opType == OperationType.DEPOSIT || opType == OperationType.SWAP) {
            return _executeWithSpendingCheck(msg.sender, target, data, opType, value);
        }

        revert UnknownSelector(bytes4(data[:4]));
    }

    // ============ Operation Classification ============

    /**
     * @notice Classify the operation type from calldata
     * @param target The protocol address being called
     * @param data The calldata to analyze
     * @return opType The operation type
     * @dev Prefers parser-based classification for protocols with dynamic operations (e.g., Uniswap V4).
     *      Falls back to selector-based classification if no parser is registered.
     */
    function _classifyOperation(address target, bytes calldata data) internal view returns (OperationType) {
        ICalldataParser parser = protocolParsers[target];

        // If parser exists, use it for classification (handles dynamic operations like V4)
        if (address(parser) != address(0)) {
            uint8 parserOpType = parser.getOperationType(data);
            if (parserOpType > 0 && parserOpType <= uint8(OperationType.REPAY)) {
                return OperationType(parserOpType);
            }
        }

        // Fallback to selector-based classification
        bytes4 selector = bytes4(data[:4]);
        return selectorType[selector];
    }

    // ============ Spending Check Logic ============

    function _executeWithSpendingCheck(
        address subAccount,
        address target,
        bytes calldata data,
        OperationType opType,
        uint256 value
    ) internal returns (bytes memory) {
        // 1. Parser is REQUIRED to extract token/amount from calldata
        ICalldataParser parser = protocolParsers[target];
        if (address(parser) == address(0)) {
            revert NoParserRegistered(target);
        }

        // 2. Validate recipient is the Safe to prevent fund theft
        address recipient = parser.extractRecipient(target, data, avatar);
        if (recipient != avatar) {
            revert InvalidRecipient(recipient, avatar);
        }

        // 3. Extract tokens and amounts from calldata via parser (arrays for multi-token operations)
        address[] memory tokensIn = parser.extractInputTokens(target, data);
        uint256[] memory amountsIn = parser.extractInputAmounts(target, data);

        // 4. Validate array lengths match
        if (tokensIn.length != amountsIn.length) revert LengthMismatch();

        // 5. For ETH swaps, override native ETH amount with actual value
        if (value > 0) {
            for (uint256 i = 0; i < tokensIn.length; i++) {
                if (tokensIn[i] == address(0)) {
                    amountsIn[i] = value;
                }
            }
        }

        // 6. Calculate spending cost and deduct acquired balance in one pass
        //    (prevents double-counting when same token appears multiple times)
        uint256 spendingCost = 0;
        for (uint256 i = 0; i < tokensIn.length; i++) {
            uint256 acquired = acquiredBalance[subAccount][tokensIn[i]];
            uint256 usedFromAcquired = amountsIn[i] > acquired ? acquired : amountsIn[i];
            uint256 fromOriginal = amountsIn[i] - usedFromAcquired;
            spendingCost += _estimateTokenValueUSD(tokensIn[i], fromOriginal);
            acquiredBalance[subAccount][tokensIn[i]] -= usedFromAcquired;
        }

        // 7. Check spending allowance (reverts restore all state changes including acquired balance)
        if (spendingCost > spendingAllowance[subAccount]) {
            revert ExceedsSpendingLimit();
        }

        // 8. Deduct spending allowance and track cumulative spending
        spendingAllowance[subAccount] -= spendingCost;
        _trackCumulativeSpending(subAccount, spendingCost);

        // 9. Capture balances before for output tracking (multiple tokens)
        address[] memory tokensOut = _getOutputTokens(target, data, parser);
        uint256[] memory balancesBefore = new uint256[](tokensOut.length);
        for (uint256 i = 0; i < tokensOut.length; i++) {
            balancesBefore[i] = tokensOut[i] != address(0) ? IERC20(tokensOut[i]).balanceOf(avatar) : avatar.balance;
        }

        // 10. Execute
        bool success = exec(target, value, data, ISafe.Operation.Call);
        if (!success) revert TransactionFailed();

        // 11. Calculate output amounts for all tokens
        // NOTE: Fee-on-transfer tokens are NOT supported — if balanceAfter < balancesBefore
        // due to transfer fees, this will revert with arithmetic underflow.
        uint256[] memory amountsOut = new uint256[](tokensOut.length);
        for (uint256 i = 0; i < tokensOut.length; i++) {
            uint256 balanceAfter = tokensOut[i] != address(0) ? IERC20(tokensOut[i]).balanceOf(avatar) : avatar.balance;
            amountsOut[i] = balanceAfter - balancesBefore[i];
        }

        // 12. Mark swap outputs as acquired on-chain
        if (opType == OperationType.SWAP) {
            for (uint256 i = 0; i < tokensOut.length; i++) {
                if (amountsOut[i] > 0) {
                    acquiredBalance[subAccount][tokensOut[i]] += amountsOut[i];
                }
            }
        }

        // 13. Emit event for oracle
        emit ProtocolExecution(subAccount, target, opType, tokensIn, amountsIn, tokensOut, amountsOut, spendingCost);

        return "";
    }

    // ============ No Spending Check Logic ============

    function _executeNoSpendingCheck(
        address subAccount,
        address target,
        bytes calldata data,
        OperationType opType,
        uint256 value
    ) internal returns (bytes memory) {
        // 1. Parser is required for WITHDRAW/CLAIM to track output tokens for acquired balance
        ICalldataParser parser = protocolParsers[target];
        if (address(parser) == address(0)) {
            revert NoParserRegistered(target);
        }

        // 2. Validate recipient is the Safe to prevent fund theft
        address recipient = parser.extractRecipient(target, data, avatar);
        if (recipient != avatar) {
            revert InvalidRecipient(recipient, avatar);
        }

        // 3. Get output tokens from parser (parser may query vault for ERC4626)
        address[] memory tokensOut = parser.extractOutputTokens(target, data);
        uint256[] memory balancesBefore = new uint256[](tokensOut.length);
        for (uint256 i = 0; i < tokensOut.length; i++) {
            balancesBefore[i] = tokensOut[i] != address(0) ? IERC20(tokensOut[i]).balanceOf(avatar) : avatar.balance;
        }

        // 4. Execute (NO spending check - withdrawals and claims are free)
        bool success = exec(target, value, data, ISafe.Operation.Call);
        if (!success) revert TransactionFailed();

        // 5. Calculate received amounts for all tokens
        uint256[] memory amountsOut = new uint256[](tokensOut.length);
        for (uint256 i = 0; i < tokensOut.length; i++) {
            uint256 balanceAfter = tokensOut[i] != address(0) ? IERC20(tokensOut[i]).balanceOf(avatar) : avatar.balance;
            amountsOut[i] = balanceAfter - balancesBefore[i];
        }

        // 6. Emit event for oracle to:
        //    - Mark received as acquired if matched to deposit (both WITHDRAW and CLAIM)
        emit ProtocolExecution(
            subAccount,
            target,
            opType,
            new address[](0), // no tokensIn for withdraw/claim
            new uint256[](0), // no amountsIn
            tokensOut,
            amountsOut,
            0 // no spending cost
        );

        return "";
    }

    // ============ Repay Logic ============

    /**
     * @notice Execute a debt repayment operation (no spending check, requires repayAllowed permission)
     * @dev REPAY consumes Safe tokens to reduce protocol debt. Unlike WITHDRAW/CLAIM,
     *      it has input tokens (the tokens being repaid). We track these in the event
     *      for oracle accounting but do not enforce spending limits.
     */
    function _executeRepay(address subAccount, address target, bytes calldata data) internal returns (bytes memory) {
        // 1. Parser is REQUIRED to extract token/amount from calldata
        ICalldataParser parser = protocolParsers[target];
        if (address(parser) == address(0)) {
            revert NoParserRegistered(target);
        }

        // 2. Validate recipient is the Safe (onBehalfOf for repay must be the Safe)
        address recipient = parser.extractRecipient(target, data, avatar);
        if (recipient != avatar) {
            revert InvalidRecipient(recipient, avatar);
        }

        // 3. Extract tokens and amounts for event tracking (no spending enforcement)
        address[] memory tokensIn = parser.extractInputTokens(target, data);
        uint256[] memory amountsIn = parser.extractInputAmounts(target, data);
        if (tokensIn.length != amountsIn.length) revert LengthMismatch();

        // 4. Execute (NO spending check - repay is permitted by setRepayAllowed)
        bool success = exec(target, 0, data, ISafe.Operation.Call);
        if (!success) revert TransactionFailed();

        // 5. Emit event for oracle tracking
        emit ProtocolExecution(
            subAccount,
            target,
            OperationType.REPAY,
            tokensIn,
            amountsIn,
            new address[](0), // repay has no output tokens
            new uint256[](0),
            0 // no spending cost
        );

        return "";
    }

    // ============ Approve Logic ============

    function _executeApproveWithCap(
        address subAccount,
        address target, // The token contract being approved
        bytes calldata data
    )
        internal
        returns (bytes memory)
    {
        // 1. Extract spender and amount from calldata
        // approve(address spender, uint256 amount) - spender is first arg, amount is second
        address spender;
        uint256 amount;
        assembly {
            // Skip selector (4 bytes), load first 32 bytes of args (spender)
            spender := calldataload(add(data.offset, 4))
            // Load second 32 bytes of args (amount)
            amount := calldataload(add(data.offset, 36))
        }

        // 2. Verify spender is whitelisted
        if (!allowedAddresses[subAccount][spender]) {
            revert SpenderNotAllowed();
        }

        // 3. Check cap: acquired tokens unlimited, original capped by spending allowance
        // For approve, target IS the token being approved
        address tokenIn = target;
        uint256 acquired = acquiredBalance[subAccount][tokenIn];

        if (amount > acquired) {
            // Portion from original tokens - must fit in spending allowance
            uint256 originalPortion = amount - acquired;
            uint256 originalValueUSD = _estimateTokenValueUSD(tokenIn, originalPortion);
            if (originalValueUSD > spendingAllowance[subAccount]) {
                revert ApprovalExceedsLimit();
            }
        }

        // 4. Execute approve - does NOT deduct spending (deducted at swap/deposit)
        bool success = exec(target, 0, data, ISafe.Operation.Call);
        if (!success) revert ApprovalFailed();

        // 5. Create arrays for event (APPROVE has single input, no outputs)
        address[] memory tokensIn = new address[](1);
        tokensIn[0] = tokenIn;
        uint256[] memory amountsIn = new uint256[](1);
        amountsIn[0] = amount;

        // 6. Emit event (APPROVE has no output tokens)
        emit ProtocolExecution(
            subAccount,
            target,
            OperationType.APPROVE,
            tokensIn,
            amountsIn,
            new address[](0),
            new uint256[](0),
            0 // No spending cost for approve
        );

        return "";
    }

    // ============ Transfer Function ============

    /**
     * @notice Transfer tokens from Safe - acquired tokens are free, non-acquired cost spending
     */
    function transferToken(address token, address recipient, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        if (!hasRole(msg.sender, DEFI_TRANSFER_ROLE)) revert Unauthorized();
        if (token == address(0) || recipient == address(0)) {
            revert InvalidAddress();
        }
        _requireFreshOracle(msg.sender);

        // Calculate spending cost only for non-acquired tokens
        uint256 acquired = acquiredBalance[msg.sender][token];
        uint256 usedFromAcquired = amount > acquired ? acquired : amount;
        uint256 fromOriginal = amount - usedFromAcquired;
        uint256 spendingCost = _estimateTokenValueUSD(token, fromOriginal);

        if (spendingCost > spendingAllowance[msg.sender]) {
            revert ExceedsSpendingLimit();
        }

        // Deduct spending allowance, track cumulative, and deduct acquired balance
        spendingAllowance[msg.sender] -= spendingCost;
        _trackCumulativeSpending(msg.sender, spendingCost);
        acquiredBalance[msg.sender][token] -= usedFromAcquired;

        // Execute transfer
        bytes memory transferData = abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount);

        bool success = exec(token, 0, transferData, ISafe.Operation.Call);
        if (!success) revert TransactionFailed();

        emit TransferExecuted(msg.sender, token, recipient, amount, spendingCost);

        return true;
    }

    // ============ Oracle Functions ============

    function updateSafeValue(uint256 totalValueUSD) external onlyOracle {
        safeValue.totalValueUSD = totalValueUSD;
        safeValue.lastUpdated = block.timestamp;
        safeValue.updateCount += 1;

        emit SafeValueUpdated(totalValueUSD, safeValue.updateCount);
    }

    function updateSpendingAllowance(address subAccount, uint256 newAllowance) external onlyOracle {
        _enforceAllowanceCap(subAccount, newAllowance);
        spendingAllowance[subAccount] = newAllowance;
        lastOracleUpdate[subAccount] = block.timestamp;
        emit SpendingAllowanceUpdated(subAccount, newAllowance);
    }

    function updateAcquiredBalance(address subAccount, address token, uint256 newBalance) external onlyOracle {
        // Cap acquired balance to Safe's actual token balance
        newBalance = _capToSafeBalance(token, newBalance);
        // Track oracle-granted acquired increases
        _trackOracleAcquiredGrant(subAccount, token, acquiredBalance[subAccount][token], newBalance);
        acquiredBalance[subAccount][token] = newBalance;
        lastOracleUpdate[subAccount] = block.timestamp;

        emit AcquiredBalanceUpdated(subAccount, token, newBalance);
    }

    /**
     * @notice Batch update for efficiency
     */
    function batchUpdate(
        address subAccount,
        uint256 newAllowance,
        address[] calldata tokens,
        uint256[] calldata balances
    ) external onlyOracle {
        if (tokens.length != balances.length) revert LengthMismatch();
        _enforceAllowanceCap(subAccount, newAllowance);

        spendingAllowance[subAccount] = newAllowance;
        lastOracleUpdate[subAccount] = block.timestamp;

        for (uint256 i = 0; i < tokens.length; i++) {
            // Cap acquired balance to Safe's actual token balance
            uint256 cappedBalance = _capToSafeBalance(tokens[i], balances[i]);
            // Track oracle-granted acquired increases
            _trackOracleAcquiredGrant(subAccount, tokens[i], acquiredBalance[subAccount][tokens[i]], cappedBalance);
            acquiredBalance[subAccount][tokens[i]] = cappedBalance;
            emit AcquiredBalanceUpdated(subAccount, tokens[i], cappedBalance);
        }

        emit SpendingAllowanceUpdated(subAccount, newAllowance);
    }

    function setAuthorizedOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert InvalidOracleAddress();
        // Prevent Safe or Module from being oracle
        if (newOracle == avatar || newOracle == address(this)) {
            revert CannotBeOracle(newOracle);
        }
        // Prevent subaccounts from being oracle (check all roles)
        if (
            subAccountRoles[newOracle][DEFI_EXECUTE_ROLE] || subAccountRoles[newOracle][DEFI_TRANSFER_ROLE]
                || subAccountRoles[newOracle][DEFI_REPAY_ROLE]
        ) {
            revert CannotBeOracle(newOracle);
        }
        address oldOracle = authorizedOracle;
        authorizedOracle = newOracle;
        emit OracleUpdated(oldOracle, newOracle);
    }

    /**
     * @notice Set the absolute maximum spending percentage (safety backstop)
     * @param newMaxBps New maximum in basis points (e.g., 2000 = 20%)
     */
    function setAbsoluteMaxSpendingBps(uint256 newMaxBps) external onlyOwner {
        if (newMaxBps > 10000) revert ExceedsMaxBps();
        absoluteMaxSpendingBps = newMaxBps;
    }

    /// @notice Set the maximum oracle acquired budget percentage
    /// @param newMaxBps New maximum in basis points (e.g., 5000 = 50%)
    function setMaxOracleAcquiredBps(uint256 newMaxBps) external onlyOwner {
        if (newMaxBps > 10000) revert ExceedsMaxBps();
        maxOracleAcquiredBps = newMaxBps;
    }

    // ============ Price Feed Functions ============

    function setTokenPriceFeed(address token, address priceFeed) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        if (priceFeed == address(0)) revert InvalidPriceFeed();
        tokenPriceFeeds[token] = AggregatorV3Interface(priceFeed);
    }

    function setTokenPriceFeeds(address[] calldata tokens, address[] calldata priceFeeds) external onlyOwner {
        if (tokens.length != priceFeeds.length) revert LengthMismatch();
        for (uint256 i = 0; i < tokens.length; i++) {
            // Note: address(0) is valid as it represents native ETH for swaps
            if (priceFeeds[i] == address(0)) revert InvalidPriceFeed();
            tokenPriceFeeds[tokens[i]] = AggregatorV3Interface(priceFeeds[i]);
        }
    }

    // ============ Internal Helpers ============

    function _requireFreshOracle(address subAccount) internal view {
        if (lastOracleUpdate[subAccount] == 0) revert StaleOracleData();
        if (block.timestamp - lastOracleUpdate[subAccount] > maxOracleAge) {
            revert StaleOracleData();
        }
    }

    function _requireFreshSafeValue() internal view {
        if (safeValue.lastUpdated == 0) revert StalePortfolioValue();
        if (block.timestamp - safeValue.lastUpdated > maxSafeValueAge) {
            revert StalePortfolioValue();
        }
    }

    /**
     * @notice Cap a value to the Safe's actual token balance
     * @dev Returns 0 for non-contract addresses and tokens that don't implement balanceOf,
     *      since the Safe provably holds 0 of a non-existent token.
     */
    function _capToSafeBalance(address token, uint256 value) internal view returns (uint256) {
        if (token == address(0)) {
            uint256 safeBalance = avatar.balance;
            return value > safeBalance ? safeBalance : value;
        }
        // Check if token is a contract before calling balanceOf
        // Non-contract addresses cannot hold tokens — Safe balance is 0
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(token)
        }
        if (codeSize == 0) return 0;
        try IERC20(token).balanceOf(avatar) returns (uint256 safeBalance) {
            return value > safeBalance ? safeBalance : value;
        } catch {
            return 0; // If balanceOf reverts (non-ERC20), Safe holds 0
        }
    }

    /// @notice Enforce allowance cap: minimum of global absolute cap and per-account USD cap
    function _enforceAllowanceCap(address subAccount, uint256 newAllowance) internal view {
        _requireFreshSafeValue();
        uint256 maxAllowance = (safeValue.totalValueUSD * absoluteMaxSpendingBps) / 10000;

        // In USD mode, also enforce per-account cap (take the stricter limit)
        SubAccountLimits storage limits = subAccountLimits[subAccount];
        if (limits.isConfigured && limits.maxSpendingUSD > 0 && limits.maxSpendingUSD < maxAllowance) {
            maxAllowance = limits.maxSpendingUSD;
        }

        if (newAllowance > maxAllowance) {
            revert ExceedsAbsoluteMaxSpending(newAllowance, maxAllowance);
        }
    }

    /// @notice Track cumulative spending per window
    /// @param subAccount The sub-account that is spending
    /// @param spendingCost The USD cost of this operation (18 decimals)
    function _trackCumulativeSpending(address subAccount, uint256 spendingCost) internal {
        if (spendingCost == 0) return;

        (uint256 maxSpendingBps, uint256 maxSpendingUSD, uint256 windowDuration) = getSubAccountLimits(subAccount);

        // Check if window is uninitialized or expired — start a new one
        if (windowStart[subAccount] == 0 || block.timestamp > windowStart[subAccount] + windowDuration) {
            _requireFreshSafeValue();
            windowStart[subAccount] = block.timestamp;
            windowSafeValue[subAccount] = safeValue.totalValueUSD;
            cumulativeSpent[subAccount] = 0;
            emit CumulativeSpendingReset(subAccount, safeValue.totalValueUSD);
        }

        // Increment cumulative spending
        cumulativeSpent[subAccount] += spendingCost;

        // Compute maximum spending for this window (dual-mode)
        uint256 maxSpending;
        if (maxSpendingUSD > 0) {
            maxSpending = maxSpendingUSD;
        } else {
            maxSpending = (windowSafeValue[subAccount] * maxSpendingBps) / 10000;
        }

        // Also cap by absolute maximum (safety backstop)
        uint256 absoluteMax = (windowSafeValue[subAccount] * absoluteMaxSpendingBps) / 10000;
        if (absoluteMax < maxSpending) {
            maxSpending = absoluteMax;
        }

        if (cumulativeSpent[subAccount] > maxSpending) {
            revert ExceedsCumulativeSpendingLimit(cumulativeSpent[subAccount], maxSpending);
        }
    }

    /// @notice Track oracle-granted acquired balance increases
    /// @param subAccount The sub-account receiving acquired balance
    /// @param token The token being marked as acquired
    /// @param oldBalance The previous acquired balance
    /// @param newBalance The new acquired balance being set
    function _trackOracleAcquiredGrant(address subAccount, address token, uint256 oldBalance, uint256 newBalance)
        internal
    {
        // Only track increases (decreases are fine — oracle is reducing exposure)
        if (newBalance <= oldBalance) return;

        // Calculate USD value of the increase
        uint256 increaseValueUSD = _estimateTokenValueUSD(token, newBalance - oldBalance);
        if (increaseValueUSD == 0) return;

        // Get window duration from sub-account limits
        (,, uint256 windowDuration) = getSubAccountLimits(subAccount);

        // Check if grant window is uninitialized or expired
        if (
            acquiredGrantWindowStart[subAccount] == 0
                || block.timestamp > acquiredGrantWindowStart[subAccount] + windowDuration
        ) {
            acquiredGrantWindowStart[subAccount] = block.timestamp;
            cumulativeOracleGrantedUSD[subAccount] = 0;
            emit OracleAcquiredBudgetReset(subAccount);
        }

        // Increment cumulative granted amount
        cumulativeOracleGrantedUSD[subAccount] += increaseValueUSD;

        // Compute maximum grant budget using snapshotted safe value (if available)
        uint256 refValue = windowSafeValue[subAccount] > 0 ? windowSafeValue[subAccount] : safeValue.totalValueUSD;
        uint256 maxGrant = (refValue * maxOracleAcquiredBps) / 10000;

        if (cumulativeOracleGrantedUSD[subAccount] > maxGrant) {
            revert ExceedsOracleAcquiredBudget(cumulativeOracleGrantedUSD[subAccount], maxGrant);
        }
    }

    function _estimateTokenValueUSD(address token, uint256 amount) internal view returns (uint256 valueUSD) {
        if (amount == 0) return 0;

        AggregatorV3Interface priceFeed = tokenPriceFeeds[token];
        if (address(priceFeed) == address(0)) revert NoPriceFeedSet();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();

        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert StalePriceFeed();
        if (answeredInRound < roundId) revert StalePriceFeed();
        if (block.timestamp - updatedAt > maxPriceFeedAge) {
            revert StalePriceFeed();
        }

        uint8 priceDecimals = priceFeed.decimals();
        uint256 price = uint256(answer);

        // Native ETH has 18 decimals, otherwise query the token
        uint8 tokenDecimals = token == address(0) ? 18 : IERC20Metadata(token).decimals();

        // Calculate USD value with 18 decimals
        // Use mulDiv to avoid amount * price overflow
        valueUSD =
            Math.mulDiv(amount, price * (10 ** 18), 10 ** uint256(tokenDecimals + priceDecimals), Math.Rounding.Ceil);
    }

    function _getOutputTokens(address target, bytes calldata data, ICalldataParser parser)
        internal
        view
        returns (address[] memory)
    {
        if (address(parser) != address(0)) {
            try parser.extractOutputTokens(target, data) returns (address[] memory tokens) {
                return tokens;
            } catch {
                return new address[](0);
            }
        }
        return new address[](0);
    }

    // ============ View Functions ============

    function getSafeValue() external view returns (uint256 totalValueUSD, uint256 lastUpdated, uint256 updateCount) {
        return (safeValue.totalValueUSD, safeValue.lastUpdated, safeValue.updateCount);
    }

    function getAcquiredBalance(address subAccount, address token) external view returns (uint256) {
        return acquiredBalance[subAccount][token];
    }

    function getSpendingAllowance(address subAccount) external view returns (uint256) {
        return spendingAllowance[subAccount];
    }

    function getTokenBalances(address[] calldata tokens) external view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balances[i] = tokens[i] == address(0) ? avatar.balance : IERC20(tokens[i]).balanceOf(avatar);
        }
    }
}
