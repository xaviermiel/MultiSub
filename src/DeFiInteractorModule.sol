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

    /// @notice Default maximum spending percentage per window (basis points)
    uint256 public constant DEFAULT_MAX_SPENDING_BPS = 500; // 5%

    /// @notice Default time window for spending limits (24 hours)
    uint256 public constant DEFAULT_WINDOW_DURATION = 1 days;

    // ============ Operation Type Classification ============

    /// @notice Operation types for selector-based classification
    enum OperationType {
        UNKNOWN,    // Must revert - unregistered selector
        SWAP,       // Costs spending (from original), output is acquired
        DEPOSIT,    // Costs spending (from original), tracked for withdrawal matching
        WITHDRAW,   // FREE, output becomes acquired if matched to deposit
        CLAIM,      // FREE, output becomes acquired if matched to deposit (same as WITHDRAW)
        APPROVE     // FREE but capped, enables future operations
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
        uint256 totalValueUSD;  // Total USD value with 18 decimals
        uint256 lastUpdated;    // Timestamp of last update
        uint256 updateCount;    // Number of updates received
    }

    /// @notice Safe's current USD value
    SafeValue public safeValue;

    /// @notice Maximum age for Safe value before considered stale
    uint256 public maxSafeValueAge = 60 minutes;

    /// @notice Absolute maximum spending percentage (safety backstop, oracle cannot exceed)
    /// @dev Default 20% (2000 basis points). Even if oracle is compromised, cannot exceed this.
    uint256 public absoluteMaxSpendingBps = 2000;

    // ============ Sub-Account Configuration ============

    /// @notice Configuration for sub-account limits
    struct SubAccountLimits {
        uint256 maxSpendingBps;     // Maximum spending in basis points
        uint256 windowDuration;     // Time window duration in seconds
        bool isConfigured;          // Whether limits have been explicitly set
    }

    /// @notice Per-sub-account limit configuration
    mapping(address => SubAccountLimits) public subAccountLimits;

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
        address indexed subAccount,
        uint256 maxSpendingBps,
        uint256 windowDuration
    );

    event AllowedAddressesSet(
        address indexed subAccount,
        address[] targets,
        bool allowed
    );

    /// @notice Emitted on every protocol interaction (for oracle consumption)
    event ProtocolExecution(
        address indexed subAccount,
        address indexed target,
        OperationType opType,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
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

    event SpendingAllowanceUpdated(
        address indexed subAccount,
        uint256 newAllowance
    );

    event AcquiredBalanceUpdated(
        address indexed subAccount,
        address indexed token,
        uint256 newBalance
    );

    event SelectorRegistered(bytes4 indexed selector, OperationType opType);
    event SelectorUnregistered(bytes4 indexed selector);
    event ParserRegistered(address indexed protocol, address parser);

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
    constructor(address _avatar, address _owner, address _authorizedOracle)
        Module(_avatar, _avatar, _owner)
    {
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
        protocolParsers[protocol] = ICalldataParser(parser);
        emit ParserRegistered(protocol, parser);
    }

    // ============ Sub-Account Configuration ============

    function setSubAccountLimits(
        address subAccount,
        uint256 maxSpendingBps,
        uint256 windowDuration
    ) external onlyOwner {
        if (subAccount == address(0)) revert InvalidAddress();
        if (maxSpendingBps > 10000 || windowDuration < 1 hours) {
            revert InvalidLimitConfiguration();
        }

        subAccountLimits[subAccount] = SubAccountLimits({
            maxSpendingBps: maxSpendingBps,
            windowDuration: windowDuration,
            isConfigured: true
        });

        emit SubAccountLimitsSet(subAccount, maxSpendingBps, windowDuration);
    }

    function getSubAccountLimits(address subAccount) public view returns (
        uint256 maxSpendingBps,
        uint256 windowDuration
    ) {
        SubAccountLimits memory limits = subAccountLimits[subAccount];
        if (limits.isConfigured) {
            return (limits.maxSpendingBps, limits.windowDuration);
        }
        return (DEFAULT_MAX_SPENDING_BPS, DEFAULT_WINDOW_DURATION);
    }

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
        emit AllowedAddressesSet(subAccount, targets, allowed);
    }

    // ============ Main Entry Point ============

    /**
     * @notice Execute a protocol interaction with automatic operation classification
     * @param target The protocol address to call
     * @param data The calldata to execute
     * @dev Token and amount are extracted from calldata via registered parsers
     */
    function executeOnProtocol(
        address target,
        bytes calldata data
    ) external nonReentrant whenNotPaused returns (bytes memory) {
        // 1. Validate permissions
        if (!hasRole(msg.sender, DEFI_EXECUTE_ROLE)) revert Unauthorized();
        _requireFreshOracle(msg.sender);

        // 2. Classify operation from selector
        bytes4 selector = bytes4(data[:4]);
        OperationType opType = selectorType[selector];

        // 3. Route based on type
        // Note: APPROVE skips allowedAddresses check on target (the token) since
        // _executeApproveWithCap validates the spender is whitelisted
        if (opType == OperationType.UNKNOWN) {
            revert UnknownSelector(selector);
        } else if (opType == OperationType.APPROVE) {
            return _executeApproveWithCap(msg.sender, target, data);
        }

        // All other operations require target to be whitelisted
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        if (opType == OperationType.WITHDRAW || opType == OperationType.CLAIM) {
            return _executeNoSpendingCheck(msg.sender, target, data, opType);
        } else if (opType == OperationType.DEPOSIT || opType == OperationType.SWAP) {
            return _executeWithSpendingCheck(msg.sender, target, data, opType);
        }

        revert UnknownSelector(selector);
    }

    // ============ Spending Check Logic ============

    function _executeWithSpendingCheck(
        address subAccount,
        address target,
        bytes calldata data,
        OperationType opType
    ) internal returns (bytes memory) {
        // 1. Parser is REQUIRED to extract token/amount from calldata
        ICalldataParser parser = protocolParsers[target];
        if (address(parser) == address(0)) {
            revert NoParserRegistered(target);
        }

        // 2. Extract token and amount from calldata via parser
        address tokenIn = parser.extractInputToken(target, data);
        uint256 amountIn = parser.extractInputAmount(target, data);

        // 3. Calculate spending cost (acquired balance is free)
        uint256 acquired = acquiredBalance[subAccount][tokenIn];
        uint256 fromOriginal = amountIn > acquired ? amountIn - acquired : 0;
        uint256 spendingCost = _estimateTokenValueUSD(tokenIn, fromOriginal);

        // 4. Check spending allowance
        if (spendingCost > spendingAllowance[subAccount]) {
            revert ExceedsSpendingLimit();
        }

        // 5. Deduct spending and acquired balance
        spendingAllowance[subAccount] -= spendingCost;
        uint256 usedFromAcquired = amountIn > acquired ? acquired : amountIn;
        acquiredBalance[subAccount][tokenIn] -= usedFromAcquired;

        // 6. Capture balance before for output tracking
        address tokenOut = _getOutputToken(target, data, parser);
        uint256 balanceBefore = tokenOut != address(0) ? IERC20(tokenOut).balanceOf(avatar) : 0;

        // 7. Execute
        bool success = exec(target, 0, data, ISafe.Operation.Call);
        if (!success) revert TransactionFailed();

        // 8. Calculate output amount
        uint256 amountOut = 0;
        if (tokenOut != address(0)) {
            amountOut = IERC20(tokenOut).balanceOf(avatar) - balanceBefore;
        }

        // 9. Emit event for oracle
        emit ProtocolExecution(
            subAccount,
            target,
            opType,
            tokenIn,
            amountIn,
            tokenOut,
            amountOut,
            spendingCost
        );

        return "";
    }

    // ============ No Spending Check Logic ============

    function _executeNoSpendingCheck(
        address subAccount,
        address target,
        bytes calldata data,
        OperationType opType
    ) internal returns (bytes memory) {
        // 1. Parser is required for WITHDRAW/CLAIM to track output tokens for acquired balance
        ICalldataParser parser = protocolParsers[target];
        if (address(parser) == address(0)) {
            revert NoParserRegistered(target);
        }

        // 2. Get output token from parser (parser may query vault for ERC4626)
        address tokenOut = parser.extractOutputToken(target, data);
        uint256 balanceBefore = tokenOut != address(0) ? IERC20(tokenOut).balanceOf(avatar) : 0;

        // 3. Execute (NO spending check - withdrawals and claims are free)
        bool success = exec(target, 0, data, ISafe.Operation.Call);
        if (!success) revert TransactionFailed();

        // 4. Calculate received amount
        uint256 amountOut = 0;
        if (tokenOut != address(0)) {
            amountOut = IERC20(tokenOut).balanceOf(avatar) - balanceBefore;
        }

        // 5. Emit event for oracle to:
        //    - Mark received as acquired if matched to deposit (both WITHDRAW and CLAIM)
        emit ProtocolExecution(
            subAccount,
            target,
            opType,
            address(0), // no tokenIn for withdraw/claim
            0,          // no amountIn
            tokenOut,
            amountOut,
            0           // no spending cost
        );

        return "";
    }

    // ============ Approve Logic ============

    function _executeApproveWithCap(
        address subAccount,
        address target,  // The token contract being approved
        bytes calldata data
    ) internal returns (bytes memory) {
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

        // 5. Emit event
        emit ProtocolExecution(
            subAccount,
            target,
            OperationType.APPROVE,
            tokenIn,
            amount,
            address(0),
            0,
            0 // No spending cost for approve
        );

        return "";
    }

    // ============ Transfer Function ============

    /**
     * @notice Transfer tokens from Safe - always costs full spending amount
     */
    function transferToken(
        address token,
        address recipient,
        uint256 amount
    ) external nonReentrant whenNotPaused returns (bool) {
        if (!hasRole(msg.sender, DEFI_TRANSFER_ROLE)) revert Unauthorized();
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        _requireFreshOracle(msg.sender);

        // Transfers always cost full spending (value leaves Safe)
        uint256 spendingCost = _estimateTokenValueUSD(token, amount);
        if (spendingCost > spendingAllowance[msg.sender]) {
            revert ExceedsSpendingLimit();
        }

        spendingAllowance[msg.sender] -= spendingCost;

        // Also deduct from acquired if available
        uint256 acquired = acquiredBalance[msg.sender][token];
        if (acquired > 0) {
            uint256 deductFromAcquired = amount > acquired ? acquired : amount;
            acquiredBalance[msg.sender][token] -= deductFromAcquired;
        }

        // Execute transfer
        bytes memory transferData = abi.encodeWithSelector(
            IERC20.transfer.selector,
            recipient,
            amount
        );

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
        _enforceAllowanceCap(newAllowance);
        spendingAllowance[subAccount] = newAllowance;
        lastOracleUpdate[subAccount] = block.timestamp;
        emit SpendingAllowanceUpdated(subAccount, newAllowance);
    }

    function updateAcquiredBalance(
        address subAccount,
        address token,
        uint256 newBalance
    ) external onlyOracle {
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
        _enforceAllowanceCap(newAllowance);

        spendingAllowance[subAccount] = newAllowance;
        lastOracleUpdate[subAccount] = block.timestamp;

        for (uint256 i = 0; i < tokens.length; i++) {
            acquiredBalance[subAccount][tokens[i]] = balances[i];
            emit AcquiredBalanceUpdated(subAccount, tokens[i], balances[i]);
        }

        emit SpendingAllowanceUpdated(subAccount, newAllowance);
    }

    function setAuthorizedOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert InvalidOracleAddress();
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

    // ============ Price Feed Functions ============

    function setTokenPriceFeed(address token, address priceFeed) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        if (priceFeed == address(0)) revert InvalidPriceFeed();
        tokenPriceFeeds[token] = AggregatorV3Interface(priceFeed);
    }

    function setTokenPriceFeeds(
        address[] calldata tokens,
        address[] calldata priceFeeds
    ) external onlyOwner {
        if (tokens.length != priceFeeds.length) revert LengthMismatch();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) revert InvalidAddress();
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

    function _enforceAllowanceCap(uint256 newAllowance) internal view {
        _requireFreshSafeValue();
        uint256 maxAllowance = (safeValue.totalValueUSD * absoluteMaxSpendingBps) / 10000;
        if (newAllowance > maxAllowance) {
            revert ExceedsAbsoluteMaxSpending(newAllowance, maxAllowance);
        }
    }

    function _estimateTokenValueUSD(
        address token,
        uint256 amount
    ) internal view returns (uint256 valueUSD) {
        if (amount == 0) return 0;

        AggregatorV3Interface priceFeed = tokenPriceFeeds[token];
        if (address(priceFeed) == address(0)) revert NoPriceFeedSet();

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert StalePriceFeed();
        if (answeredInRound < roundId) revert StalePriceFeed();
        if (block.timestamp - updatedAt > maxPriceFeedAge) revert StalePriceFeed();

        uint8 priceDecimals = priceFeed.decimals();
        uint256 price = uint256(answer);

        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        // Calculate USD value with 18 decimals
        valueUSD = Math.mulDiv(
            amount * price,
            10 ** 18,
            10 ** uint256(tokenDecimals + priceDecimals),
            Math.Rounding.Ceil
        );
    }

    function _getOutputToken(
        address target,
        bytes calldata data,
        ICalldataParser parser
    ) internal view returns (address) {
        if (address(parser) != address(0)) {
            try parser.extractOutputToken(target, data) returns (address token) {
                return token;
            } catch {
                return address(0);
            }
        }
        return address(0);
    }

    // ============ View Functions ============

    function getSafeValue() external view returns (
        uint256 totalValueUSD,
        uint256 lastUpdated,
        uint256 updateCount
    ) {
        return (safeValue.totalValueUSD, safeValue.lastUpdated, safeValue.updateCount);
    }

    function getAcquiredBalance(
        address subAccount,
        address token
    ) external view returns (uint256) {
        return acquiredBalance[subAccount][token];
    }

    function getSpendingAllowance(address subAccount) external view returns (uint256) {
        return spendingAllowance[subAccount];
    }

    function getTokenBalances(
        address[] calldata tokens
    ) external view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balances[i] = IERC20(tokens[i]).balanceOf(avatar);
        }
    }
}
