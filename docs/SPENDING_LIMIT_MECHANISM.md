# Spending Limit Mechanism: Acquired Balance Model

## Table of Contents

1. [Introduction & Goals](#1-introduction--goals)
2. [Core Mechanism Design](#2-core-mechanism-design)
3. [Storage & Data Structures](#3-storage--data-structures)
4. [Operation Types](#4-operation-types)
5. [Detailed Flow Examples](#5-detailed-flow-examples)
6. [Potential Issues & Analysis](#6-potential-issues--analysis)
7. [Mitigations](#7-mitigations)
8. [Hybrid On-Chain/Off-Chain Architecture](#8-hybrid-on-chainoff-chain-architecture)
9. [Implementation Considerations](#9-implementation-considerations)
10. [Alternative Approaches](#10-alternative-approaches)
11. [Design Decisions (Resolved)](#11-design-decisions-resolved)
12. [Critical Edge Case: Withdrawals Are Free](#12-critical-edge-case-withdrawals-are-free)
13. [Secure Execution Model (Hybrid A+C)](#13-secure-execution-model-hybrid-ac)

---

## 1. Introduction & Goals

### 1.1 Problem Statement

Sub-accounts delegated to operate on behalf of a Safe need spending limits to:
- Prevent excessive value extraction by compromised keys
- Allow operational flexibility within defined boundaries
- Maintain operational flexibility while enforcing limits

### 1.2 Design Goals

| Goal | Description |
|------|-------------|
| **Portfolio-based limits** | Cap each sub-account to X% of portfolio value per time window |
| **Operational flexibility** | Allow sub-accounts to use assets they acquired through operations |
| **Acquired token flexibility** | Tokens from operations (swaps, withdrawals) are free to use |
| **Value preservation** | Swaps don't "double count" since value stays in Safe |
| **Simplicity** | Minimize complexity while achieving security goals |

### 1.3 Key Insight

The core insight is distinguishing between:
- **Original assets**: Assets in the Safe at window start → using them costs spending
- **Acquired assets**: Assets received from operations during the window → free to use

This allows sub-accounts to:
1. Swap asset A to B (costs spending)
2. Continue using B for further operations (free)
3. Swap back to A if needed (free)
4. Deposit/withdraw without getting "stuck"

---

## 2. Core Mechanism Design

### 2.1 Conceptual Model

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SPENDING LIMIT MODEL                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Daily Limit = Portfolio Value × maxSpendingBps / 10,000                   │
│                                                                             │
│   Net Spending = Σ (Original Assets Used in USD)                            │
│                  (spending is one-way, no recovery)                         │
│                                                                             │
│   Constraint: Net Spending ≤ Daily Limit                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Asset Classification

At any point during a window, each token balance is classified:

```
Total Safe Balance = Original Balance + Acquired Balance

Where:
- Original Balance: Was in Safe at window start (or remainder after use)
- Acquired Balance: Received from operations during current window
```

**Critical Rules:**

1. **Exact Amount Tracking**: Acquired balance tracks the EXACT amount received from each operation.
   - If sub-account swaps USDC for 0.1 ETH, only 0.1 ETH becomes acquired
   - Any other ETH in the Safe remains "original" and costs spending to use
   - This prevents gaming by claiming pre-existing balances as "acquired"

2. **24h Expiry**: Acquired status expires after 24 hours (rolling window).
   - After expiry, tokens become "original" again and cost spending to use
   - Example: ETH acquired at 10:00 AM Monday expires at 10:00 AM Tuesday
   - Oracle tracks timestamps for each acquired record to enforce expiry

### 2.3 Operation Cost Rules

| Operation | Spending Cost | Output Classification |
|-----------|---------------|----------------------|
| **Swap A→B** | USD value of A used from Original | B received is Acquired |
| **Deposit to Protocol** | USD value of token from Original | Tracked for withdrawal matching |
| **Withdraw from Protocol** | None (FREE) | Conditional* |
| **Transfer Out of Safe** | Always full USD value | N/A (leaves Safe) |
| **Receive External** | None | Acquired |
| **Claim Rewards** | None | Conditional** |
| **Approve** | None (capped***) | N/A |

\* Only if deposit matched by the same subaccount in the time window.
\*\* Yield and rewards become acquired only if they result from a transaction by this subaccount within the 24h window.
\*\*\* Approve doesn't consume spending, but is capped: acquired tokens can be approved freely, original tokens approval is capped by spending allowance.

### 2.4 Spending Calculation Logic

When using amount X of token T:

```
1. Check acquiredBalance[subAccount][T]
2. If X ≤ acquiredBalance:
   - Deduct X from acquiredBalance
   - Spending cost = $0
3. If X > acquiredBalance:
   - Use all acquiredBalance (free)
   - Remainder (X - acquiredBalance) comes from Original
   - Spending cost = USD value of remainder
4. Check: currentSpending + cost ≤ limit
```

---

## 3. Storage & Data Structures

### 3.1 Core Storage (Hybrid A+C Model)

```solidity
// ============ Oracle-Managed State ============

/// @notice Current spending allowance per sub-account (set by oracle)
/// @dev This is the REMAINING allowance, updated by oracle based on rolling window
mapping(address => uint256) public spendingAllowance;

/// @notice Acquired (free-to-use) balance per sub-account per token
/// @dev Managed by oracle, tokens received from operations are marked acquired
mapping(address => mapping(address => uint256)) public acquiredBalance;

/// @notice Authorized oracle address (Chainlink CRE)
address public authorizedOracle;

/// @notice Last oracle update timestamp per sub-account
mapping(address => uint256) public lastOracleUpdate;

/// @notice Maximum age for oracle data before operations are blocked
uint256 public maxOracleAge = 15 minutes;


// ============ Selector Registry ============

/// @notice Operation type for each known function selector
enum OperationType {
    UNKNOWN,    // Must use typed function - REVERTS
    SWAP,       // Costs spending, output = acquired
    DEPOSIT,    // Costs spending, tracked for withdrawal matching
    WITHDRAW,   // FREE, output becomes acquired if matched
    CLAIM,      // FREE, no recovery (rewards, airdrops)
    APPROVE     // FREE but capped, enables future operations
}

mapping(bytes4 => OperationType) public selectorType;


// ============ Calldata Parsers ============

/// @notice Parser contract for each protocol (extracts token/amount from calldata)
mapping(address => ICalldataParser) public protocolParsers;


// ============ Configuration ============

/// @notice Absolute maximum spending (safety backstop, oracle cannot exceed)
uint256 public absoluteMaxSpendingBps = 2000; // 20% hard cap

/// @notice Portfolio value (updated by oracle)
struct SafeValue {
    uint256 totalValueUSD;  // 18 decimals
    uint256 lastUpdated;
}
SafeValue public safeValue;


// ============ Price Feeds ============

/// @notice Chainlink price feed per token
mapping(address => AggregatorV3Interface) public tokenPriceFeeds;
```

### 3.2 Events

```solidity
// ============ Execution Events ============

/// @notice Emitted on every protocol interaction
event ProtocolExecution(
    address indexed subAccount,
    address indexed target,
    OperationType opType,
    address tokenIn,
    uint256 amountIn,
    address tokenOut,
    uint256 amountOut,
    uint256 spendingCost,
    uint256 timestamp
);

// ============ Oracle Update Events ============

event SpendingAllowanceUpdated(
    address indexed subAccount,
    uint256 newAllowance,
    uint256 timestamp
);

event AcquiredBalanceUpdated(
    address indexed subAccount,
    address indexed token,
    uint256 newBalance,
    uint256 timestamp
);

event BatchUpdate(
    address indexed subAccount,
    uint256 newAllowance,
    address[] tokens,
    uint256[] balances,
    uint256 timestamp
);

// ============ Registry Events ============

event SelectorRegistered(bytes4 indexed selector, OperationType opType);
event SelectorUnregistered(bytes4 indexed selector);
event ParserRegistered(address indexed protocol, address parser);

// ============ Safety Events ============

event SafeValueUpdated(uint256 totalValueUSD, uint256 timestamp);
```

---

## 4. Operation Types

> **Note**: This section describes operation types conceptually. See **Section 13** for the full implementation using selector-based classification.

### 4.1 Operation Classification

Operations are classified by their function selector and routed accordingly:

| Type | Costs Spending? | Output Status |
|------|-----------------|---------------|
| **SWAP** | Yes (from original) | Acquired |
| **DEPOSIT** | Yes (from original) | Tracked by oracle |
| **WITHDRAW** | No (FREE) | Conditional* |
| **CLAIM** | No (FREE) | Conditional** |
| **APPROVE** | No (capped***) | N/A |
| **TRANSFER** | Always (full amount) | N/A |

\* Only if deposit matched by the same subaccount in the time window.
\*\* Yield and rewards become acquired only if they result from a transaction by this subaccount within the 24h window.
\*\*\* Approve doesn't consume spending, but is capped by (acquiredBalance + spendingAllowance) for the token.

### 4.2 Main Entry Point

All protocol interactions go through a single function:

```solidity
function executeOnProtocol(
    address target,
    bytes calldata data,
    address tokenIn,
    uint256 amountIn
) external nonReentrant whenNotPaused {
    // 1. Validate permissions
    require(hasRole(msg.sender, DEFI_EXECUTE_ROLE), "Unauthorized");
    require(allowedAddresses[msg.sender][target], "Protocol not allowed");
    _requireFreshOracle(msg.sender);

    // 2. Classify operation from selector
    bytes4 selector = bytes4(data[:4]);
    OperationType opType = selectorType[selector];

    // 3. Route based on type
    if (opType == OperationType.UNKNOWN) {
        revert UnknownSelector(selector);
    }
    else if (opType == OperationType.WITHDRAW || opType == OperationType.CLAIM) {
        _executeNoSpendingCheck(msg.sender, target, data, opType);
    }
    else if (opType == OperationType.DEPOSIT || opType == OperationType.SWAP) {
        _executeWithSpendingCheck(msg.sender, target, data, tokenIn, amountIn, opType);
    }
    else if (opType == OperationType.APPROVE) {
        _executeApproveWithCap(msg.sender, target, data, tokenIn, amountIn);
    }
}
```

### 4.3 Spending Check Logic

For DEPOSIT and SWAP operations:

```solidity
function _executeWithSpendingCheck(...) internal {
    // 1. Verify tokenIn/amountIn match calldata (can't lie)
    ICalldataParser parser = protocolParsers[target];
    require(parser.extractInputToken(data) == tokenIn, "Token mismatch");
    require(parser.extractInputAmount(data) == amountIn, "Amount mismatch");

    // 2. Calculate cost (acquired balance is free)
    uint256 acquired = acquiredBalance[subAccount][tokenIn];
    uint256 fromOriginal = amountIn > acquired ? amountIn - acquired : 0;
    uint256 spendingCost = _estimateTokenValueUSD(tokenIn, fromOriginal);

    // 3. Check allowance
    require(spendingCost <= spendingAllowance[subAccount], "Exceeds allowance");

    // 4. Deduct
    spendingAllowance[subAccount] -= spendingCost;
    acquiredBalance[subAccount][tokenIn] -= min(amountIn, acquired);

    // 5. Execute and emit event for oracle
    exec(target, 0, data, Enum.Operation.Call);
    emit ProtocolExecution(...);
}
```

### 4.4 No Spending Check Logic

For WITHDRAW and CLAIM operations:

```solidity
function _executeNoSpendingCheck(...) internal {
    // 1. Get output token from parser
    address outputToken = protocolParsers[target].extractOutputToken(data);
    uint256 balanceBefore = IERC20(outputToken).balanceOf(avatar);

    // 2. Execute (NO spending check)
    exec(target, 0, data, Enum.Operation.Call);

    // 3. Emit event for oracle to:
    //    - Mark received as acquired if matched to deposit (WITHDRAW)
    //    - Mark received as acquired if from subaccount's tx in 24h (CLAIM)
    uint256 received = IERC20(outputToken).balanceOf(avatar) - balanceBefore;
    emit ProtocolExecution(...);
}
```

### 4.5 Approve Logic (Capped but Free)

For APPROVE operations (ERC20 approve/increaseAllowance):

```solidity
function _executeApproveWithCap(
    address subAccount,
    address target,      // The token contract
    bytes calldata data,
    address tokenIn,     // Same as target for approve
    uint256 amountIn     // Approval amount
) internal {
    // 1. Extract spender from calldata (the protocol being approved)
    address spender = _extractApproveSpender(data);
    require(allowedAddresses[subAccount][spender], "Spender not allowed");

    // 2. Check cap: acquired tokens unlimited, original capped by spending allowance
    uint256 acquired = acquiredBalance[subAccount][tokenIn];

    if (amountIn > acquired) {
        // Portion from original tokens - must fit in spending allowance
        uint256 originalPortion = amountIn - acquired;
        uint256 originalValueUSD = _estimateTokenValueUSD(tokenIn, originalPortion);
        require(originalValueUSD <= spendingAllowance[subAccount], "Approval exceeds limit");
    }

    // 3. Execute approve - does NOT deduct spending (deducted at swap/deposit)
    exec(target, 0, data, Enum.Operation.Call);

    emit ProtocolExecution(subAccount, target, OperationType.APPROVE, ...);
}
```

**Key points:**
- Approve doesn't consume spending allowance (actual spending at execution)
- Acquired tokens can be approved without limit (e.g., LP tokens for redemption)
- Original tokens approval is capped by current spending allowance
- Spender must be in allowedAddresses (whitelisted protocols only)

### 4.6 Transfer Out (Separate Function)

Transfers always cost spending regardless of acquired balance:

```solidity
function transferToken(
    address token,
    address recipient,
    uint256 amount
) external nonReentrant whenNotPaused {
    require(hasRole(msg.sender, DEFI_TRANSFER_ROLE), "Unauthorized");
    _requireFreshOracle(msg.sender);

    // Always costs full spending (value leaves Safe)
    uint256 spendingCost = _estimateTokenValueUSD(token, amount);
    require(spendingCost <= spendingAllowance[msg.sender], "Exceeds allowance");

    spendingAllowance[msg.sender] -= spendingCost;

    // Execute
    exec(token, 0, abi.encodeCall(IERC20.transfer, (recipient, amount)), Enum.Operation.Call);

    emit ProtocolExecution(msg.sender, token, OperationType.TRANSFER, ...);
}
```

### 4.6 Oracle Updates State

The oracle monitors `ProtocolExecution` events and updates:

```typescript
// Off-chain oracle logic
if (event.opType === 'SWAP') {
  // Add output as acquired
  state.acquiredBalance[event.tokenOut] += event.amountOut;
}

if (event.opType === 'WITHDRAW') {
  // Check if withdrawal matches a deposit by this subaccount
  const matchedDeposit = findMatchingDeposit(event.subAccount, event.protocol);
  if (matchedDeposit) {
    // Only mark as acquired if deposit was matched
    state.acquiredBalance[event.tokenOut] += event.amountOut;
  }
  // Note: NO spending recovery - spending is one-way
}

// Push updated allowance = maxSpending - spendingUsed
await contract.updateSpendingAllowance(subAccount, newAllowance);
```

---

## 5. Detailed Flow Examples

> **Note**: These examples show the logical flow. Actual state updates are handled by the oracle based on emitted events.

### 5.1 Basic Swap Flow

```
Initial State:
- Safe balance: 10,000 USDC, 1 ETH
- Portfolio value: $12,000
- Sub-account limit: 5% = $600
- spendingAllowance = $600 (set by oracle)
- acquiredBalance[USDC] = 0, acquiredBalance[ETH] = 0

Operation: Swap 500 USDC → 0.25 ETH via executeOnProtocol()

On-Chain:
  1. Classify selector → SWAP
  2. Verify tokenIn=USDC, amountIn=500 match calldata
  3. Check acquired: acquiredBalance[USDC] = 0
  4. Calculate cost: 500 USDC from Original = $500
  5. Check: $500 <= $600 spendingAllowance ✓
  6. Deduct: spendingAllowance = $600 - $500 = $100
  7. Execute swap, receive 0.25 ETH
  8. Emit ProtocolExecution event

Oracle (after event):
  - Add acquired: acquiredBalance[ETH] = 0.25
  - Track spending: spendingUsed = $500
  - Push update to contract

Final State:
- Safe balance: 9,500 USDC, 1.25 ETH
- spendingAllowance = $100 (remaining)
- acquiredBalance[ETH] = 0.25
```

### 5.2 Using Acquired Tokens

```
Continuing from 5.1...

Operation: Deposit 0.25 ETH to Aave

On-Chain:
  1. Classify selector → DEPOSIT
  2. Verify tokenIn=ETH, amountIn=0.25 match calldata
  3. Check acquired: acquiredBalance[ETH] = 0.25
  4. Calculate cost: 0.25 ETH from Acquired = $0
  5. Check: $0 <= $100 spendingAllowance ✓
  6. Deduct acquired: acquiredBalance[ETH] = 0
  7. Execute deposit
  8. Emit ProtocolExecution event

Oracle (after event):
  - Track deposit for withdrawal matching
  - spendingUsed still $500 (no additional cost)

Final State:
- Safe balance: 9,500 USDC, 1 ETH, ~0.25 aETH
- spendingAllowance = $100 (unchanged!)
- acquiredBalance[ETH] = 0
- Oracle tracks: deposited $500 to Aave by this subaccount
```

### 5.3 Withdrawal (Acquired Matching)

```
Continuing from 5.2...

Operation: Withdraw 0.25 ETH from Aave

On-Chain:
  1. Classify selector → WITHDRAW
  2. No spending check (withdrawals are FREE)
  3. Execute withdrawal, receive 0.25 ETH
  4. Emit ProtocolExecution event

Oracle (after event):
  - Match withdrawal to deposit (same subaccount, within 24h)
  - Deposit matched → mark output as acquired
  - Add acquired: acquiredBalance[ETH] = 0.25
  - Note: NO spending recovery - spending stays consumed

Final State:
- Safe balance: 9,500 USDC, 1.25 ETH
- spendingAllowance = $100 (unchanged - no recovery!)
- acquiredBalance[ETH] = 0.25 (free to use)
- Sub-account can use 0.25 ETH freely, but spending limit unchanged
```

### 5.4 Partial Acquired Usage

```
State:
- Safe balance: 10,000 USDC
- acquiredBalance[USDC] = 300
- spendingAllowance = $300 (already used $200 of $500 limit)

Operation: Swap 500 USDC → ETH

On-Chain:
  1. Classify selector → SWAP
  2. Check acquired: acquiredBalance[USDC] = 300
  3. Use 300 from Acquired (free)
  4. Use 200 from Original (costs spending)
  5. spendingCost = $200
  6. Check: $200 <= $300 spendingAllowance ✓
  7. Deduct: spendingAllowance = $300 - $200 = $100
  8. Deduct: acquiredBalance[USDC] = 0
  9. Execute swap
  10. Emit ProtocolExecution event

Oracle (after event):
  - Add acquired ETH from swap output
  - Track spending

Final State:
- spendingAllowance = $100
- acquiredBalance[USDC] = 0
- acquiredBalance[ETH] = (swap output)
```

---

## 6. Potential Issues & Analysis

> **Note**: This section analyzes potential issues that were identified during design. Code examples use simplified pseudocode to illustrate concepts. The chosen implementation approach is detailed in **Section 13 (Secure Execution Model)**.

### 6.1 Price Manipulation / Arbitrage Exploitation

#### 6.1.1 The Problem

Acquired tokens retain their "free to use" status regardless of price changes. A sub-account can exploit this:

```
Window Start: ETH = $2,000

1. Swap $1,000 USDC → 0.5 ETH
   - spendingCost = $1,000 (at limit)
   - acquiredBalance[ETH] = 0.5

2. ETH price pumps to $4,000
   - 0.5 ETH now worth $2,000
   - But still "acquired" (free to use)

3. Sub-account can now move $2,000 of value freely
   - Effective limit exceeded by 2x
```

#### 6.1.2 Severity: HIGH

This fundamentally undermines the spending limit if volatile assets are involved.

#### 6.1.3 Attack Variations

**Intentional Pump Timing**:
- Sub-account monitors for price pumps
- Swaps to volatile asset just before pump
- Gains free spending capacity

**Coordinated Manipulation**:
- If sub-account has external ability to influence price (whale)
- Could pump price after acquiring tokens

**Volatility Harvesting**:
- Repeatedly swap to volatile assets
- On pumps: assets become more valuable (free to use)
- On dumps: swap back and try again
- Asymmetric risk for the Safe

---

### 6.2 Operation Classification Problem

#### 6.2.1 The Problem

The system needs to know what type of operation is being executed:
- `executeSwap()` → output is acquired
- `depositToProtocol()` → tracks for withdrawal matching
- `withdrawFromProtocol()` → output becomes acquired if matched

But DeFi operations are diverse and not always clearly categorized.

#### 6.2.2 Classification Challenges

| Operation | Category? | Ambiguity |
|-----------|-----------|-----------|
| Uniswap swap | Swap | Clear |
| Aave deposit | Deposit | Clear |
| Curve add_liquidity | Deposit? Swap? | LP token returned |
| Yearn vault deposit | Deposit | Clear |
| Compound mint cToken | Deposit | Clear |
| GMX open position | Deposit? | Complex derivative |
| Convex stake | Deposit | Receipt token |
| Harvest rewards | Claim | Not deposit/swap |
| Flash loan | None | Temporary |

#### 6.2.3 Generic Execute Problem

If the contract has a generic `executeOnProtocol()` function:
- Can't classify the operation automatically
- Could bypass typed functions
- Need to either remove generic execute or add classification

---

### 6.3 Yield and Rewards Handling

#### 6.3.1 The Problem

DeFi positions generate yield over time:

```
1. Deposit 1,000 USDC to Aave
   - spendingCost = $1,000
   - depositedToProtocol[Aave] = $1,000

2. Wait 1 month, earn 50 USDC yield

3. Withdraw 1,050 USDC
   - Deposit matched → 1,050 USDC becomes acquired
   - No spending recovery (spending still consumed)

Result: Sub-account has 1,050 USDC as acquired (free to use)
        But spending limit remains consumed until window resets
```

#### 6.3.2 Churning Attack

Sub-account could exploit this:

```
Repeat:
1. Deposit maximum allowed
2. Wait for yield
3. Withdraw (tokens become acquired)
4. Deposit again using acquired tokens (free)

Each cycle: Could accumulate more "acquired" balance from yield
```

#### 6.3.3 Severity: LOW (Mitigated)

**Mitigation**: Yield and rewards only become acquired if they result from a transaction by this subaccount within the 24h window.

- Passive yield accrual (just waiting) does NOT become acquired
- Only explicit claim/harvest transactions within 24h qualify
- Churning is mitigated because the yield must be actively claimed by the subaccount
- The 24h window ensures old positions don't accumulate unlimited free tokens

---

### 6.4 Cross-Sub-Account Balance Conflicts

#### 6.4.1 The Problem

Acquired balance is tracked per sub-account, but Safe balance is shared:

```
Safe USDC balance: 1,500

Sub-account A: acquiredBalance[USDC] = 1,000
Sub-account B: acquiredBalance[USDC] = 800

Total acquired claims: 1,800 > 1,500 actual
```

#### 6.4.2 Race Condition

```
1. Both A and B try to use their "acquired" USDC
2. A goes first, uses 1,000 USDC (free)
3. B tries to use 800 USDC
   - Only 500 USDC left in Safe
   - B's transaction fails or uses less
```

#### 6.4.3 Severity: MEDIUM

- Doesn't break security (can't exceed Safe balance)
- But creates UX issues and unpredictability
- Sub-accounts may think they have more free capacity than they do

---

### 6.5 Window Reset Gaming

#### 6.5.1 The Problem

Window boundaries create discrete state transitions that can be gamed:

```
Window 1 (5 minutes left):
1. Swap all limit to volatile token
2. Token is now "original" in new window

Window 2 (starts):
3. Price pumped 2x overnight
4. Portfolio value doubled
5. New limit is 2x higher
6. All tokens are "original" (cost spending to use)

Net effect: Sub-account now has 2x the limit due to price increase
```

#### 6.5.2 Reverse Gaming

```
Window 1:
1. Sub-account has spent limit
2. Waits for window reset

Window 2:
3. All acquired tokens become "original"
4. Previous activity doesn't carry over
5. Fresh spending limit
```

This is actually expected behavior, but creates predictable exploitation windows.

---

### 6.6 Deposit/Withdrawal Value Mismatch

#### 6.6.1 The Problem

Deposits and withdrawals are tracked in USD, but prices change:

```
1. Deposit 1 ETH when ETH = $2,000
   - spendingCost = $2,000
   - depositedToProtocol = $2,000

2. ETH drops to $1,000

3. Withdraw 1 ETH (now worth $1,000)
   - Deposit matched → 1 ETH becomes acquired
   - No spending recovery

Net: Spent $2,000 (consumed permanently)
     1 ETH now acquired (worth $1,000, free to use)
```

#### 6.6.2 Inverse Scenario

```
1. Deposit 1 ETH when ETH = $1,000
   - depositedToProtocol = $1,000

2. ETH rises to $2,000

3. Withdraw 1 ETH (now worth $2,000)
   - Deposit matched → 1 ETH becomes acquired
   - No spending recovery

Net: Spent $1,000 (consumed permanently)
     1 ETH now acquired (worth $2,000, free to use)
```

#### 6.6.3 Severity: LOW

- No spending recovery simplifies the model
- Price changes only affect acquired token value, not spending limit
- Sub-account can still use withdrawn tokens freely

---

### 6.7 Gas Cost / DoS Concerns

#### 6.7.1 Storage Bloat

Each unique token touched adds to `_acquiredTokens`:

```solidity
// Sub-account interacts with 50 different tokens
_acquiredTokens[subAccount].length() == 50

// Window reset iterates all 50
for (uint256 i = 0; i < 50; i++) {
    delete acquiredBalance[subAccount][tokens.at(i)];
}
// Gas: ~5,000 per token = 250,000 gas just for clearing
```

#### 6.7.2 Griefing Attack

Malicious sub-account could:
1. Interact with many dust tokens
2. Bloat `_acquiredTokens` set
3. Make window reset expensive for themselves
4. If reset is triggered automatically, could cause issues

#### 6.7.3 Severity: LOW-MEDIUM

- Self-griefing mostly
- But could affect UX and gas costs

---

### 6.8 Oracle Manipulation / Stale Prices

#### 6.8.1 The Problem

USD value calculations depend on Chainlink price feeds:

```solidity
function _estimateTokenValueUSD(address token, uint256 amount) internal view {
    (, int256 price, , uint256 updatedAt,) = priceFeed.latestRoundData();
    // ...
}
```

If prices are stale or manipulated:
- Spending cost could be underestimated
- Sub-account uses less limit than they should
- Or overestimated, blocking legitimate operations

#### 6.8.2 Attack Scenario

```
1. Chainlink ETH price: $2,000 (stale from 2 hours ago)
2. Actual market ETH price: $2,500

3. Sub-account swaps $1,000 USDC → 0.4 ETH (at market)
   - Chainlink says 0.4 ETH = $800
   - spendingCost = $800

4. Reality: Sub-account got $1,000 worth of ETH
   - Spent $800 of limit for $1,000 of value
```

---

### 6.9 Complexity and Auditability

#### 6.9.1 The Problem

The mechanism has many interacting components:
- Original vs Acquired classification
- Per-token tracking
- Per-protocol deposit tracking
- Window resets
- Recovery logic
- USD value estimation

#### 6.9.2 Mental Model Difficulty

Users may not understand:
- Why some tokens are "free" and others aren't
- When spending capacity recovers
- How window resets affect their state

#### 6.9.3 Audit Surface

More code paths = more potential bugs:
- Off-by-one in balance tracking
- Overflow/underflow in recovery
- Race conditions in concurrent operations
- Edge cases in window transitions

---

### 6.10 Reentrancy and Callback Risks

#### 6.10.1 The Problem

External calls during operations (swaps, deposits) could callback:

```solidity
function executeSwap(...) external {
    // 1. Consume tokens (state updated)
    uint256 spendingCost = _consumeTokens(...);

    // 2. Execute swap (EXTERNAL CALL - could callback)
    exec(protocol, 0, swapData, Enum.Operation.Call);

    // 3. Mark output as acquired
    _addAcquiredBalance(...);
}
```

If the protocol calls back during step 2:
- State is partially updated
- Could potentially be exploited

#### 6.10.2 Mitigation

Already using `nonReentrant` modifier, but need to ensure it's applied correctly to all entry points.

---

## 7. Mitigations

> **Note**: This section explores various mitigation options that were considered. The chosen approach combines the best elements into the **Hybrid A+C model** described in **Section 13 (Secure Execution Model)**.

### 7.1 Price Manipulation Mitigations

#### 7.1.1 Option A: Track Cost Basis

Track acquired balance by cost basis, not current value:

```solidity
struct AcquiredPosition {
    uint256 amount;         // Token amount
    uint256 costBasisUSD;   // Original USD value when acquired
}

mapping(address => mapping(address => AcquiredPosition)) public acquiredPositions;

// When using acquired tokens, cap "free" value at cost basis
function _calculateSpendingCost(...) internal view returns (uint256) {
    AcquiredPosition memory pos = acquiredPositions[subAccount][token];

    uint256 currentValue = _estimateTokenValueUSD(token, amount);
    uint256 proportionalCostBasis = (pos.costBasisUSD * amount) / pos.amount;

    // Free amount is limited to cost basis, not current value
    uint256 freeValue = min(currentValue, proportionalCostBasis);
    uint256 spendingCost = currentValue - freeValue;

    return spendingCost;
}
```

**Pros**: Prevents price pump exploitation
**Cons**: More complex tracking, doesn't allow "riding gains"

#### 7.1.2 Option B: Re-price on Use

Re-evaluate acquired balance value when used:

```solidity
// Cap acquired value at percentage of original spending
uint256 public maxAcquiredGainBps = 2000; // 20% max gain

function _consumeTokens(...) internal {
    uint256 currentValue = _estimateTokenValueUSD(token, amount);
    uint256 costBasis = acquiredCostBasis[subAccount][token];

    uint256 maxFreeValue = costBasis * (10000 + maxAcquiredGainBps) / 10000;
    uint256 actualFreeValue = min(currentValue, maxFreeValue);

    // Anything above max is treated as "original" (costs spending)
    if (currentValue > actualFreeValue) {
        spendingCost = currentValue - actualFreeValue;
    }
}
```

**Pros**: Allows some upside, caps extreme cases
**Cons**: Still exploitable up to cap

#### 7.1.3 Option C: Volatile Asset Restrictions

Restrict which assets can be acquired:

```solidity
mapping(address => bool) public stablecoinsOnly;

function _addAcquiredBalance(address subAccount, address token, uint256 amount) internal {
    if (stablecoinsOnly[token]) {
        acquiredBalance[subAccount][token] += amount;
    } else {
        // Non-stablecoins don't get acquired status
        // They cost spending when used
    }
}
```

**Pros**: Simple, prevents volatile asset exploitation
**Cons**: Limits operational flexibility

---

### 7.2 Operation Classification Mitigations

#### 7.2.1 Remove Generic Execute

Only allow typed operations:

```solidity
// REMOVE or restrict:
function executeOnProtocol(address target, bytes calldata data) external;

// KEEP only:
function executeSwap(...) external;
function depositToProtocol(...) external;
function withdrawFromProtocol(...) external;
```

**Pros**: Clear classification
**Cons**: Less flexible, may not cover all DeFi operations

#### 7.2.2 Protocol Handlers

Register handlers for each protocol:

```solidity
interface IProtocolHandler {
    function classifyOperation(bytes calldata data)
        external pure returns (OperationType);
    function extractInputToken(bytes calldata data)
        external pure returns (address token, uint256 amount);
    function extractOutputToken(bytes calldata data)
        external pure returns (address token);
}

mapping(address => IProtocolHandler) public protocolHandlers;

function executeOnProtocol(address target, bytes calldata data) external {
    IProtocolHandler handler = protocolHandlers[target];
    require(address(handler) != address(0), "No handler");

    OperationType opType = handler.classifyOperation(data);

    if (opType == OperationType.Swap) {
        _handleSwap(target, data, handler);
    } else if (opType == OperationType.Deposit) {
        _handleDeposit(target, data, handler);
    } // etc.
}
```

**Pros**: Flexible, extensible
**Cons**: High maintenance, handler per protocol

#### 7.2.3 Conservative Default

Unknown operations don't get acquired status:

```solidity
function executeOnProtocol(address target, bytes calldata data) external {
    // No acquired balance tracking
    // Full spending cost
    // No recovery

    _resetWindowIfNeeded(msg.sender);

    // Estimate potential value at risk (conservative)
    uint256 spendingCost = _estimateMaxValueAtRisk(target, data);

    uint256 newSpending = spendingInWindow[msg.sender] + spendingCost;
    require(newSpending <= _getSpendingLimit(msg.sender), "Exceeds limit");
    spendingInWindow[msg.sender] = newSpending;

    exec(target, 0, data, Enum.Operation.Call);
}
```

**Pros**: Safe default
**Cons**: Generic execute becomes expensive/limited

---

### 7.3 Yield Churning Mitigation

#### 7.3.1 Recovery Cooldown

Limit how often recovery can happen:

```solidity
mapping(address => mapping(address => uint256)) public lastRecoveryTime;
uint256 public recoveryCooldown = 1 hours;

function withdrawFromProtocol(...) external {
    require(
        block.timestamp >= lastRecoveryTime[msg.sender][protocol] + recoveryCooldown,
        "Recovery cooldown"
    );

    // ... recovery logic ...

    lastRecoveryTime[msg.sender][protocol] = block.timestamp;
}
```

#### 7.3.2 Cap Yield as Acquired

Only count principal as recovery, force yield to cost spending:

```solidity
// Track deposited amounts in token terms, not USD
mapping(address => mapping(address => mapping(address => uint256)))
    public depositedTokenAmount; // subAccount => protocol => token => amount

function withdrawFromProtocol(...) external {
    uint256 received = ...;
    uint256 deposited = depositedTokenAmount[msg.sender][protocol][token];

    // Only recover up to deposited TOKEN amount (not USD value)
    uint256 recoveryTokens = received > deposited ? deposited : received;
    uint256 recoveryUSD = _estimateTokenValueUSD(token, recoveryTokens);

    // Yield tokens (received - deposited) become acquired
    uint256 yieldTokens = received > deposited ? received - deposited : 0;

    // ... update tracking ...
}
```

---

### 7.4 Cross-Sub-Account Mitigations

#### 7.4.1 Global Acquired Cap

Ensure total acquired claims don't exceed Safe balance:

```solidity
// Global tracking of acquired claims per token
mapping(address => uint256) public totalAcquiredClaims;

function _addAcquiredBalance(address subAccount, address token, uint256 amount) internal {
    uint256 safeBalance = IERC20(token).balanceOf(avatar);
    uint256 newTotalClaims = totalAcquiredClaims[token] + amount;

    // Cap at Safe balance
    if (newTotalClaims > safeBalance) {
        amount = safeBalance > totalAcquiredClaims[token]
            ? safeBalance - totalAcquiredClaims[token]
            : 0;
    }

    acquiredBalance[subAccount][token] += amount;
    totalAcquiredClaims[token] += amount;
}
```

#### 7.4.2 First-Come-First-Served Documentation

Document that acquired balances are "virtual claims":
- Not guaranteed until used
- Race conditions possible
- Sub-accounts should not rely on full acquired balance

---

### 7.5 Window Reset Mitigations

#### 7.5.1 Gradual Reset

Instead of instant reset, gradually restore spending capacity:

```solidity
function _getAvailableSpending(address subAccount) internal view returns (uint256) {
    uint256 timeSinceStart = block.timestamp - windowStart[subAccount];
    uint256 windowDuration = _getWindowDuration(subAccount);
    uint256 maxSpending = _getSpendingLimit(subAccount);

    // Linear recovery over window
    uint256 recoveredCapacity = (maxSpending * timeSinceStart) / windowDuration;

    uint256 spent = spendingInWindow[subAccount];
    return recoveredCapacity > spent ? recoveredCapacity - spent : 0;
}
```

**Pros**: Smoother, less gameable
**Cons**: More complex, different mental model

#### 7.5.2 Rolling Window

Use rolling window instead of fixed reset:

```solidity
// Track spending with timestamps
struct SpendingRecord {
    uint256 amount;
    uint256 timestamp;
}

SpendingRecord[] public spendingHistory;

function _getCurrentSpending(address subAccount) internal view returns (uint256) {
    uint256 windowStart = block.timestamp - windowDuration;
    uint256 total = 0;

    for (uint i = 0; i < spendingHistory.length; i++) {
        if (spendingHistory[i].timestamp >= windowStart) {
            total += spendingHistory[i].amount;
        }
    }

    return total;
}
```

**Pros**: No discrete reset to game
**Cons**: High gas cost, complex implementation

---

### 7.6 Oracle Mitigations

#### 7.6.1 Strict Staleness Checks

Already implemented, but ensure:

```solidity
uint256 public maxPriceFeedAge = 1 hours; // Conservative

function _estimateTokenValueUSD(...) internal view {
    (, int256 price, , uint256 updatedAt,) = priceFeed.latestRoundData();

    require(block.timestamp - updatedAt <= maxPriceFeedAge, "Stale price");
    require(price > 0, "Invalid price");

    // ...
}
```

#### 7.6.2 TWAP Prices

Use time-weighted average prices instead of spot:

```solidity
// Integrate with Uniswap V3 TWAP or similar
function _getTWAPPrice(address token, uint32 period) internal view returns (uint256);
```

**Pros**: Resistant to manipulation
**Cons**: Implementation complexity, not available for all tokens

#### 7.6.3 Multiple Oracle Sources

Cross-check prices from multiple sources:

```solidity
function _estimateTokenValueUSD(...) internal view {
    uint256 chainlinkPrice = _getChainlinkPrice(token);
    uint256 uniswapPrice = _getUniswapTWAP(token);

    uint256 deviation = _calculateDeviation(chainlinkPrice, uniswapPrice);
    require(deviation <= maxAllowedDeviation, "Price deviation too high");

    return (chainlinkPrice + uniswapPrice) / 2;
}
```

---

### 7.7 Gas Optimization Mitigations

#### 7.7.1 Lazy Clearing

Don't clear on reset, use window-based invalidation:

```solidity
struct AcquiredBalance {
    uint256 amount;
    uint256 windowId;
}

mapping(address => mapping(address => AcquiredBalance)) public acquiredBalances;
mapping(address => uint256) public currentWindowId;

function _getAcquiredBalance(address subAccount, address token) internal view returns (uint256) {
    AcquiredBalance memory bal = acquiredBalances[subAccount][token];

    // Invalid if from old window
    if (bal.windowId != currentWindowId[subAccount]) {
        return 0;
    }

    return bal.amount;
}

function _resetWindow(address subAccount) internal {
    currentWindowId[subAccount]++;
    // No iteration needed!
}
```

**Pros**: O(1) reset
**Cons**: Stale data persists in storage (not cleared)

#### 7.7.2 Cap Tracked Tokens

Limit number of tokens that can have acquired balance:

```solidity
uint256 public constant MAX_ACQUIRED_TOKENS = 20;

function _addAcquiredBalance(...) internal {
    require(
        _acquiredTokens[subAccount].length() < MAX_ACQUIRED_TOKENS ||
        _acquiredTokens[subAccount].contains(token),
        "Too many acquired tokens"
    );
    // ...
}
```

---

## 8. Hybrid On-Chain/Off-Chain Architecture

> **Note**: This section describes the oracle responsibilities. For the secure on-chain execution model with selector-based classification, see **Section 13**.

The core use case for this protocol is enabling sub-accounts to manage liquidity on behalf of Safe owners without giving them full access. An off-chain oracle can significantly simplify on-chain logic while enabling more sophisticated rules.

### 8.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      HYBRID ARCHITECTURE                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐    monitors     ┌─────────────────────────────────┐   │
│  │   Sub-Account   │ ───────────────→│      Off-Chain Oracle           │   │
│  │   Transactions  │                 │   (Chainlink CRE / Custom)      │   │
│  └────────┬────────┘                 └───────────────┬─────────────────┘   │
│           │                                          │                      │
│           │ executes                                 │ updates              │
│           ▼                                          ▼                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    DeFiInteractorModule                             │   │
│  │  ┌─────────────────────────────────────────────────────────────┐   │   │
│  │  │  On-Chain State (Oracle-Managed)                            │   │   │
│  │  │  • spendingAllowance[subAccount] - current allowed spending │   │   │
│  │  │  • acquiredBalance[subAccount][token] - free-to-use tokens  │   │   │
│  │  │  • selectorType[selector] - operation classification        │   │   │
│  │  └─────────────────────────────────────────────────────────────┘   │   │
│  │                                                                     │   │
│  │  ┌─────────────────────────────────────────────────────────────┐   │   │
│  │  │  On-Chain Logic (Secure Enforcement - See Section 13)       │   │   │
│  │  │  • Classify operation from selector                         │   │   │
│  │  │  • Verify tokenIn/amountIn from calldata                    │   │   │
│  │  │  • Check: spendingCost <= spendingAllowance                 │   │   │
│  │  │  • Execute through Safe                                     │   │   │
│  │  │  • Emit ProtocolExecution events                            │   │   │
│  │  └─────────────────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 Responsibility Split

| Responsibility | On-Chain | Off-Chain Oracle |
|----------------|----------|------------------|
| **Spending limit enforcement** | Simple check: `cost <= allowance` | Calculate allowance based on complex rules |
| **Acquired balance tracking** | Store values, emit events | Determine when to add/remove acquired status |
| **Window management** | None (stateless) | Track rolling windows, handle expiry |
| **Deposit/withdrawal netting** | Emit deposit/withdraw events | Match deposits to withdrawals, calculate recovery |
| **Portfolio valuation** | Store value, check staleness | Calculate from token balances + prices |
| **Price feeds** | None | Aggregate from Chainlink, TWAP, etc. |
| **Anomaly detection** | None | Detect suspicious patterns, reduce allowance |

### 8.3 On-Chain Contract (Simplified)

The on-chain contract becomes much simpler - just enforcement:

```solidity
// ============ Oracle-Managed State ============

/// @notice Current spending allowance per sub-account (set by oracle)
/// @dev This is the REMAINING allowance, not the limit
mapping(address => uint256) public spendingAllowance;

/// @notice Acquired balance per sub-account per token (managed by oracle)
mapping(address => mapping(address => uint256)) public acquiredBalance;

/// @notice Authorized oracle address
address public authorizedOracle;

/// @notice Last oracle update timestamp per sub-account
mapping(address => uint256) public lastOracleUpdate;

/// @notice Maximum age for oracle data before operations are blocked
uint256 public maxOracleAge = 15 minutes;


// ============ Oracle Update Functions ============

/// @notice Oracle updates spending allowance after analyzing transactions
function updateSpendingAllowance(
    address subAccount,
    uint256 newAllowance
) external onlyOracle {
    spendingAllowance[subAccount] = newAllowance;
    lastOracleUpdate[subAccount] = block.timestamp;

    emit SpendingAllowanceUpdated(subAccount, newAllowance, block.timestamp);
}

/// @notice Oracle updates acquired balance based on tx analysis
function updateAcquiredBalance(
    address subAccount,
    address token,
    uint256 newBalance
) external onlyOracle {
    acquiredBalance[subAccount][token] = newBalance;

    emit AcquiredBalanceUpdated(subAccount, token, newBalance, block.timestamp);
}

/// @notice Batch update for efficiency
function batchUpdate(
    address subAccount,
    uint256 newAllowance,
    address[] calldata tokens,
    uint256[] calldata balances
) external onlyOracle {
    spendingAllowance[subAccount] = newAllowance;

    for (uint i = 0; i < tokens.length; i++) {
        acquiredBalance[subAccount][tokens[i]] = balances[i];
    }

    lastOracleUpdate[subAccount] = block.timestamp;

    emit BatchUpdate(subAccount, newAllowance, tokens, balances, block.timestamp);
}


// ============ Execution ============
// See Section 13 for the full Secure Execution Model (Hybrid A+C)
// Key points:
// - Single entry point: executeOnProtocol(target, data, tokenIn, amountIn)
// - Selector-based operation classification (SWAP, DEPOSIT, WITHDRAW, CLAIM)
// - Calldata parser verification prevents lying about token/amount
// - Withdrawals and claims are FREE (no spending check)
// - Swaps and deposits deduct from spendingAllowance

// Example call flow:
// 1. Wallet calls executeOnProtocol(AAVE_POOL, supplyCalldata, USDC, 1000e6)
// 2. Contract extracts selector from calldata → classified as DEPOSIT
// 3. Calldata parser verifies USDC/1000e6 match the encoded calldata
// 4. _executeWithSpendingCheck() enforces spending limit
// 5. ProtocolExecution event emitted for oracle processing

function _requireFreshOracle(address subAccount) internal view {
    require(
        block.timestamp - lastOracleUpdate[subAccount] <= maxOracleAge,
        "Oracle data stale"
    );
}
```

### 8.4 Off-Chain Oracle Logic

The oracle monitors events and applies complex rules:

```typescript
// Pseudocode for off-chain oracle

interface SpendingState {
  subAccount: Address;
  deposits: Map<Protocol, DepositRecord[]>;   // Historical deposits with timestamps
  spendingHistory: SpendingRecord[];          // Rolling window of spending
  acquiredBalances: Map<Token, AcquiredRecord[]>; // With timestamps
}

interface DepositRecord {
  protocol: Address;
  token: Address;
  amount: bigint;
  valueUSD: bigint;
  timestamp: number;
  txHash: string;
}

interface AcquiredRecord {
  amount: bigint;
  costBasisUSD: bigint;
  source: 'swap' | 'withdrawal' | 'external' | 'rewards';
  timestamp: number;
}

// ============ Rolling Window Spending ============

function calculateCurrentSpending(state: SpendingState): bigint {
  const windowStart = Date.now() - WINDOW_DURATION_MS; // 24 hours

  // Sum spending in window, with linear decay for older entries
  let totalSpending = 0n;

  for (const record of state.spendingHistory) {
    if (record.timestamp >= windowStart) {
      // Full weight for recent spending
      totalSpending += record.valueUSD;
    }
    // Entries older than window are ignored
  }

  return totalSpending;
}

function calculateSpendingAllowance(
  state: SpendingState,
  portfolioValue: bigint,
  maxSpendingBps: number
): bigint {
  const maxSpending = (portfolioValue * BigInt(maxSpendingBps)) / 10000n;
  const currentSpending = calculateCurrentSpending(state);

  // Available = max - current (with floor at 0)
  return currentSpending >= maxSpending ? 0n : maxSpending - currentSpending;
}


// ============ Withdrawal Recovery Logic ============

function processWithdrawal(
  state: SpendingState,
  event: WithdrawalEvent
): { recoveredSpending: bigint; newAcquired: bigint } {
  const { protocol, token, amount, valueUSD, timestamp } = event;

  // Find matching deposits from SAME sub-account within window
  const windowStart = timestamp - WINDOW_DURATION_MS;
  const matchingDeposits = state.deposits.get(protocol)?.filter(d =>
    d.timestamp >= windowStart &&
    d.token === token
  ) || [];

  if (matchingDeposits.length === 0) {
    // No matching deposit - withdrawal is just acquired, no recovery
    return { recoveredSpending: 0n, newAcquired: amount };
  }

  // Match FIFO (first in, first out)
  let remainingWithdraw = valueUSD;
  let recoveredSpending = 0n;

  for (const deposit of matchingDeposits.sort((a, b) => a.timestamp - b.timestamp)) {
    if (remainingWithdraw <= 0n) break;

    const matchAmount = remainingWithdraw > deposit.valueUSD
      ? deposit.valueUSD
      : remainingWithdraw;

    recoveredSpending += matchAmount;
    remainingWithdraw -= matchAmount;

    // Mark deposit as partially/fully matched
    deposit.valueUSD -= matchAmount;
  }

  // Anything beyond matched deposits is just acquired (no recovery)
  const newAcquired = amount; // Full amount is acquired

  return { recoveredSpending, newAcquired };
}


// ============ Acquired Balance Expiry ============

function calculateAcquiredBalance(
  state: SpendingState,
  token: Address
): bigint {
  const windowStart = Date.now() - WINDOW_DURATION_MS;
  const records = state.acquiredBalances.get(token) || [];

  // Only count acquired balance from current window
  let total = 0n;
  for (const record of records) {
    if (record.timestamp >= windowStart) {
      total += record.amount;
    }
    // Older acquired balance "expires" - becomes original again
  }

  return total;
}


// ============ Example: Gradual Expiry ============

function calculateAcquiredBalanceWithDecay(
  state: SpendingState,
  token: Address
): bigint {
  const now = Date.now();
  const records = state.acquiredBalances.get(token) || [];

  let total = 0n;
  for (const record of records) {
    const age = now - record.timestamp;

    if (age >= WINDOW_DURATION_MS) {
      // Fully expired
      continue;
    }

    // Linear decay: 100% at t=0, 0% at t=window
    const remainingWeight = WINDOW_DURATION_MS - age;
    const effectiveAmount = (record.amount * BigInt(remainingWeight)) / BigInt(WINDOW_DURATION_MS);

    total += effectiveAmount;
  }

  return total;
}


// ============ Adding Acquired Balance (Exact Amount Tracking) ============

function addAcquiredBalance(
  state: SpendingState,
  token: Address,
  amount: bigint,  // EXACT amount received from operation
  source: 'swap' | 'withdrawal' | 'external' | 'rewards'
): void {
  const records = state.acquiredBalances.get(token) || [];

  // Create new record with exact amount and current timestamp
  records.push({
    amount,           // Only this exact amount is acquired
    costBasisUSD: 0n, // Set by caller if needed
    source,
    timestamp: Date.now()  // For 24h expiry tracking
  });

  state.acquiredBalances.set(token, records);

  // Note: Any existing balance of this token in the Safe that wasn't
  // received from this operation remains "original" and costs spending
}


// ============ Main Oracle Loop ============

async function oracleLoop() {
  while (true) {
    // 1. Fetch new events from contract
    const events = await fetchNewEvents();

    // 2. Update state for each affected sub-account
    for (const event of events) {
      const state = await loadState(event.subAccount);

      if (event.type === 'SwapExecuted') {
        // Add output token as acquired
        addAcquiredBalance(state, event.tokenOut, event.received, 'swap');

        // Add spending record
        addSpendingRecord(state, event.spendingCost, event.timestamp);
      }

      if (event.type === 'ProtocolDeposit') {
        // Track deposit for withdrawal matching
        addDepositRecord(state, event);

        // Add spending record
        addSpendingRecord(state, event.spendingCost, event.timestamp);
      }

      if (event.type === 'ProtocolWithdrawal') {
        const { recoveredSpending, newAcquired } = processWithdrawal(state, event);

        // Add acquired balance
        addAcquiredBalance(state, event.token, newAcquired, 'withdrawal');

        // Remove from spending history (recovery)
        if (recoveredSpending > 0n) {
          removeSpendingAmount(state, recoveredSpending);
        }
      }

      await saveState(state);
    }

    // 3. Calculate and push updates for all active sub-accounts
    for (const subAccount of activeSubAccounts) {
      const state = await loadState(subAccount);
      const portfolioValue = await getPortfolioValue();

      const newAllowance = calculateSpendingAllowance(state, portfolioValue, MAX_SPENDING_BPS);
      const tokenBalances = calculateAllAcquiredBalances(state);

      await contract.batchUpdate(subAccount, newAllowance, tokenBalances);
    }

    await sleep(UPDATE_INTERVAL); // e.g., every 1 minute
  }
}
```

### 8.5 Example: Rolling Window with Your Scenario

```
Scenario:
- Sub-account deposited $100 24h ago
- Sub-account deposited $500 2h ago
- Current time: 1h after second deposit
- Window duration: 24h

Timeline:
├─ 24h ago ─────────── Deposit $100 ──────────────────┤
│                                                      │
├─ 2h ago ──────────── Deposit $500 ──────────────────┤
│                                                      │
├─ 1h ago ──────────── Now ───────────────────────────┤
│                                                      │
├─ In 1h ─────────────  $100 deposit expires ─────────┤

Current state (1h ago):
  spendingHistory = [
    { value: $100, timestamp: 24h ago },  // About to expire
    { value: $500, timestamp: 2h ago }    // Fresh
  ]
  totalSpending = $600

State in 1 hour (now):
  spendingHistory = [
    { value: $100, timestamp: 24h ago },  // EXPIRED (> 24h)
    { value: $500, timestamp: 2h ago }    // Still valid
  ]
  totalSpending = $500  // $100 fell out of window

Oracle calculation:
  portfolioValue = $10,000
  maxSpendingBps = 1000 (10%)
  maxSpending = $1,000

  Before expiry: allowance = $1,000 - $600 = $400
  After expiry:  allowance = $1,000 - $500 = $500  // +$100 freed up
```

### 8.6 Withdrawal Recovery with Time Matching

```
Rule: Withdrawals only recover spending if deposited by same
      sub-account within same 24h window

Scenario 1: Valid recovery
├─ 6h ago ──────────── Deposit $500 to Aave ──────────┤
├─ 2h ago ──────────── Withdraw $500 from Aave ───────┤

  → Deposit is within 24h window
  → Same sub-account
  → Recovery: $500 ✓

Scenario 2: Expired deposit
├─ 30h ago ─────────── Deposit $500 to Aave ──────────┤
├─ Now ────────────── Withdraw $500 from Aave ────────┤

  → Deposit is OUTSIDE 24h window
  → No matching deposit found
  → Recovery: $0 ✗
  → Withdrawn tokens become "acquired" (free to use)

Scenario 3: Different sub-account
├─ SubAccount A deposits $500 to Aave ────────────────┤
├─ SubAccount B withdraws $500 from Aave ─────────────┤

  → No matching deposit for SubAccount B
  → Recovery: $0 ✗
  → B gets acquired balance but no spending recovery
```

### 8.7 Benefits of Hybrid Approach

| Benefit | Description |
|---------|-------------|
| **Simpler on-chain logic** | Just check `cost <= allowance`, no window management |
| **Lower gas costs** | No complex calculations or iterations on-chain |
| **Flexible rules** | Change recovery rules, window duration, etc. without upgrade |
| **Rolling windows** | Natural implementation off-chain, hard on-chain |
| **Better matching** | FIFO deposit matching, partial matching, time-based expiry |
| **Anomaly detection** | Detect suspicious patterns, reduce allowance proactively |
| **Historical analysis** | Use full transaction history for decisions |
| **Multiple data sources** | Aggregate prices from multiple oracles |

### 8.8 Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| **Oracle downtime** | Contract enforces `maxOracleAge`, blocks operations if stale |
| **Oracle manipulation** | Use Chainlink CRE with decentralized execution |
| **Frontrunning oracle updates** | Oracle can react to pending transactions |
| **Delayed updates** | Conservative initial allowance, frequent updates |
| **Oracle bugs** | On-chain max limits as backstop, monitoring |

### 8.9 On-Chain Safety Backstops

Even with oracle management, keep hard limits on-chain:

```solidity
/// @notice Absolute maximum spending per window (safety backstop)
uint256 public absoluteMaxSpendingBps = 2000; // 20% hard cap

/// @notice Oracle cannot set allowance above this
function updateSpendingAllowance(address subAccount, uint256 newAllowance) external onlyOracle {
    uint256 portfolioValue = safeValue.totalValueUSD;
    uint256 maxAllowed = (portfolioValue * absoluteMaxSpendingBps) / 10000;

    // Oracle can only set up to the hard cap
    uint256 effectiveAllowance = newAllowance > maxAllowed ? maxAllowed : newAllowance;

    spendingAllowance[subAccount] = effectiveAllowance;
    lastOracleUpdate[subAccount] = block.timestamp;
}
```

### 8.10 Integration with Existing Chainlink CRE

The existing `safe-value` Chainlink CRE workflow can be extended:

```typescript
// In chainlink-runtime-environment/safe-value/safe-monitor.ts

// Current: Calculate portfolio value
const portfolioValue = await calculatePortfolioValue(safe);
await updateSafeValue(portfolioValue);

// Extended: Also calculate spending allowances
for (const subAccount of activeSubAccounts) {
  const state = await loadSpendingState(subAccount);

  // Clean expired records
  pruneExpiredRecords(state);

  // Calculate allowance
  const allowance = calculateSpendingAllowance(state, portfolioValue);
  const acquiredBalances = calculateAcquiredBalances(state);

  // Push to contract
  await contract.batchUpdate(subAccount, allowance, acquiredBalances);
}
```

---

## 9. Implementation Considerations

### 9.1 Recommended Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CONTRACT STRUCTURE                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  DeFiInteractorModule (existing)                                            │
│    ├── Role management                                                      │
│    ├── Protocol allowlists                                                  │
│    └── Base execution                                                       │
│                                                                             │
│  SpendingLimitExtension (new, inherits/composes)                           │
│    ├── Window management                                                    │
│    ├── Acquired balance tracking                                            │
│    ├── Deposit/withdrawal tracking                                          │
│    └── Spending calculation                                                 │
│                                                                             │
│  ProtocolHandlers (new, separate contracts)                                 │
│    ├── UniswapHandler                                                       │
│    ├── AaveHandler                                                          │
│    ├── MorphoHandler                                                        │
│    └── ...                                                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 Storage Layout

Plan for upgrades:

```solidity
// Reserve storage slots for future use
uint256[50] private __gap;
```

### 9.3 Testing Strategy

| Test Category | Coverage |
|---------------|----------|
| Unit tests | Each function in isolation |
| Integration tests | Full operation flows |
| Fuzz tests | Random inputs, edge cases |
| Invariant tests | Global properties always hold |
| Fork tests | Against mainnet state |
| Gas benchmarks | Ensure reasonable costs |

### 9.4 Key Invariants to Test

```solidity
// Invariant 1: Spending allowance never goes negative (handled by oracle)
assert(spendingAllowance[subAccount] >= 0);

// Invariant 2: Total acquired claims <= Safe balance
for each token:
    assert(sum(acquiredBalance[all_subaccounts][token]) <= IERC20(token).balanceOf(safe));

// Invariant 3: Recovery never exceeds deposited (tracked off-chain)
// Oracle ensures: totalRecovered[subAccount][protocol] <= totalDeposited[subAccount][protocol]

// Invariant 4: Oracle freshness
// Operations blocked if: block.timestamp - lastOracleUpdate[subAccount] > maxOracleAge
```

---

## 10. Alternative Approaches

### 10.1 Simpler: Fixed Token Budgets

Instead of USD-based limits with acquired tracking:

```solidity
// Per-token daily limit
mapping(address => mapping(address => uint256)) public dailyTokenLimit;
mapping(address => mapping(address => uint256)) public tokenUsedToday;

function useToken(address token, uint256 amount) internal {
    require(
        tokenUsedToday[msg.sender][token] + amount <= dailyTokenLimit[msg.sender][token],
        "Daily token limit exceeded"
    );
    tokenUsedToday[msg.sender][token] += amount;
}
```

**Pros**: Much simpler, no USD conversion needed
**Cons**: Need to configure per token, no portfolio-wide limit

### 10.2 Value Delta Approach

Track portfolio value change instead of individual operations:

```solidity
function checkSpendingLimit(address subAccount) internal view {
    uint256 startValue = windowPortfolioValue[subAccount];
    uint256 currentValue = _getCurrentPortfolioValue();

    uint256 maxLoss = startValue * maxLossBps / 10000;

    require(
        currentValue >= startValue - maxLoss,
        "Portfolio loss exceeds limit"
    );
}
```

**Pros**: Simple, holistic view
**Cons**: Requires fresh portfolio value on every check (expensive)

### 10.3 Allowance Model (Like ERC20)

Sub-accounts get explicit allowances:

```solidity
// Owner grants allowance
function grantAllowance(address subAccount, address token, uint256 amount) external onlyOwner {
    allowance[subAccount][token] = amount;
}

// Sub-account uses allowance
function useAllowance(address subAccount, address token, uint256 amount) internal {
    require(allowance[subAccount][token] >= amount, "Insufficient allowance");
    allowance[subAccount][token] -= amount;
}
```

**Pros**: Very simple, explicit control
**Cons**: Manual management, no automatic recovery

---

## 11. Design Decisions (Resolved)

### 11.1 Policy Decisions

| Question | Decision | Rationale |
|----------|----------|-----------|
| **Should transfers out always cost spending?** | **Yes** | Transfers move value out of Safe permanently |
| **Should yield count as acquired?** | **Conditional** | Only if from subaccount's tx in 24h window |
| **Should protocol rewards/airdrops be acquired?** | **Conditional** | Only if from subaccount's tx in 24h window |
| **Should withdrawals become acquired?** | **Conditional** | Only if deposit matched by same subaccount in time window |
| **Should approve consume spending?** | **No (capped)** | Capped by allowance for original tokens, but not deducted until execution |
| **What if Safe balance decreases externally?** | **Reduce sub-account allowances** | Oracle adjusts based on actual balances |

### 11.2 Technical Decisions

| Question | Decision | Rationale |
|----------|----------|-----------|
| **Cost basis tracking** | **USD** | Simpler implementation, oracle handles price updates |
| **Lazy vs explicit clearing** | **Lazy (window ID)** | Gas efficient, O(1) reset |

### 11.3 UX Decisions

| Question | Decision |
|----------|----------|
| **How to surface spending capacity?** | Custom wallet UI will display state |
| **Should sub-accounts query their state?** | **Yes** - view functions provided |

---

## 12. Critical Edge Case: Withdrawals Are Free

> **Note**: This section explains *why* withdrawals are free. The implementation uses `executeOnProtocol()` with selector-based classification as described in **Section 13**. Code examples here use simplified function names for clarity.

### 12.1 The Problem

```
Scenario:
1. Sub-account has $10,000 allowance (5% of $200k portfolio)
2. Deposits $10,000 USDC to Aave
   → spendingAllowance = $0 (fully consumed)
   → depositedToProtocol[Aave] = $10,000
3. Sub-account wants to withdraw from Aave
   → spendingAllowance = $0... can they withdraw?
```

### 12.2 The Solution: Withdrawals Don't Consume Allowance

**Key insight**: Withdrawals bring value INTO the Safe, they shouldn't be blocked.

```
Operation Types and Spending:

┌─────────────────────┬─────────────────────┬─────────────────────┐
│ Operation           │ Costs Allowance?    │ Rationale           │
├─────────────────────┼─────────────────────┼─────────────────────┤
│ Swap A → B          │ YES (for A)         │ Using Safe assets   │
│ Deposit to protocol │ YES                 │ Value leaves Safe   │
│ Transfer out        │ YES                 │ Value leaves Safe   │
├─────────────────────┼─────────────────────┼─────────────────────┤
│ Withdraw from proto │ NO                  │ Value enters Safe   │
│ Claim rewards       │ NO                  │ Value enters Safe   │
│ Receive external    │ NO                  │ Value enters Safe   │
└─────────────────────┴─────────────────────┴─────────────────────┘
```

### 12.3 Implementation

```solidity
/// @notice Withdraw from protocol - NO spending check required
function withdrawFromProtocol(
    address token,
    address protocol,
    bytes calldata withdrawData
) external nonReentrant whenNotPaused {
    // 1. Validate permissions (but NOT spending allowance)
    require(hasRole(msg.sender, DEFI_EXECUTE_ROLE), "Unauthorized");
    require(allowedAddresses[msg.sender][protocol], "Protocol not allowed");

    // 2. Execute withdrawal - NO allowance check!
    uint256 balanceBefore = IERC20(token).balanceOf(avatar);
    exec(protocol, 0, withdrawData, Enum.Operation.Call);
    uint256 received = IERC20(token).balanceOf(avatar) - balanceBefore;

    // 3. Emit event for oracle to:
    //    - Add received tokens as "acquired" (if deposit matched)
    //    - Note: NO spending recovery
    emit ProtocolWithdrawal(
        msg.sender,
        protocol,
        token,
        received,
        block.timestamp
    );
}
```

### 12.4 Full Flow Example

```
Initial State:
  portfolioValue = $200,000
  maxSpendingBps = 500 (5%)
  spendingAllowance = $10,000
  depositedToProtocol = {}

Step 1: Deposit $10,000 USDC to Aave
  ├─ Check: $10,000 <= $10,000 allowance ✓
  ├─ Deduct: spendingAllowance = $0
  ├─ Track: depositedToProtocol[Aave] = $10,000
  └─ Emit: ProtocolDeposit event

State after deposit:
  spendingAllowance = $0  (fully consumed)
  depositedToProtocol[Aave] = $10,000

Step 2: Withdraw $10,000 USDC from Aave
  ├─ Check allowance? NO! Withdrawals are free
  ├─ Execute withdrawal
  ├─ Emit: ProtocolWithdrawal event
  └─ Oracle processes event:
       ├─ Match to deposit: same subaccount, within 24h ✓
       ├─ Add acquired: acquiredBalance[USDC] += $10,000
       └─ Note: NO spending recovery

Final State:
  spendingAllowance = $0 (still consumed - no recovery!)
  acquiredBalance[USDC] = $10,000 (free to use)
  depositedToProtocol[Aave] = $0 (matched)

Step 3: Sub-account can now:
  ├─ Use acquired USDC for more operations (FREE)
  ├─ But cannot use original assets (spending limit consumed)
  └─ Must wait for 24h window to reset for new spending allowance
```

### 12.5 Security: Why This Is Safe

| Concern | Mitigation |
|---------|------------|
| **Withdraw from wrong protocol?** | `allowedAddresses` whitelist enforced |
| **Withdraw more than deposited?** | Protocol enforces this (can't withdraw what you don't have) |
| **Gaming via fake withdrawals?** | Oracle only marks as acquired if matching deposit exists |
| **Cross-sub-account exploitation?** | Deposits tracked per sub-account, can't mark others' deposits as acquired |

### 12.6 What About Partial Withdrawals?

```
Scenario:
1. Deposit $10,000 USDC (spending consumed)
2. Withdraw $3,000 USDC

Oracle processing:
  depositedToProtocol[Aave] = $10,000
  withdrawValue = $3,000
  Match found → mark as acquired

  New state:
  depositedToProtocol[Aave] = $7,000 (remaining for future matching)
  spendingAllowance = unchanged (no recovery!)
  acquiredBalance[USDC] += $3,000 (free to use)

Later: Withdraw remaining $7,000
  Match found → mark as acquired

  Final state:
  depositedToProtocol[Aave] = $0
  acquiredBalance[USDC] += $7,000
  Spending still consumed until window resets
```

---

## 13. Secure Execution Model (Hybrid A+C)

### 13.1 Problem with Simple Approaches

Several simpler approaches were considered but have security vulnerabilities:

| Approach | Vulnerability |
|----------|---------------|
| **Wallet specifies tokens** | Compromised sub-account lies about `tokenSpent` |
| **Wallet specifies amount** | Compromised sub-account sets `maxSpendAmount = 0` |
| **No on-chain tracking** | Oracle sees attack only AFTER execution |
| **Trust wallet classification** | Malicious wallet claims deposit is withdrawal |

**Key insight**: A compromised sub-account will lie. On-chain verification is essential.

### 13.2 Solution: Selector-Based Classification with Calldata Verification

The contract:
1. **Classifies operations from function selectors** (can't be faked)
2. **Extracts token/amount from calldata** (verifies wallet claims)
3. **Reverts on unknown selectors** (forces typed fallback functions)

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          SECURE EXECUTION FLOW                           │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   1. Extract selector from calldata                                      │
│              │                                                           │
│              ▼                                                           │
│   2. Lookup: selectorType[selector]                                      │
│              │                                                           │
│              ├─── UNKNOWN ──────► REVERT (use typed function)            │
│              │                                                           │
│              ├─── WITHDRAW/CLAIM ──► _executeNoSpendingCheck()           │
│              │                         • No allowance check              │
│              │                         • Execute freely                  │
│              │                         • Emit event for oracle           │
│              │                                                           │
│              └─── DEPOSIT/SWAP ────► _executeWithSpendingCheck()         │
│                                       • Extract token from calldata      │
│                                       • Extract amount from calldata     │
│                                       • Verify matches wallet params     │
│                                       • Check spending allowance         │
│                                       • Deduct from acquired first       │
│                                       • Execute                          │
│                                       • Emit event                       │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### 13.3 Operation Type Registry

```solidity
// ============ Operation Types ============

enum OperationType {
    UNKNOWN,    // Must use typed function - REVERTS
    SWAP,       // Costs spending, output = acquired
    DEPOSIT,    // Costs spending, tracked for withdrawal matching
    WITHDRAW,   // FREE, output becomes acquired if matched
    CLAIM       // FREE, no recovery (rewards, airdrops)
}

// Owner-managed registry of known function selectors
mapping(bytes4 => OperationType) public selectorType;


// ============ Known Selectors ============

// Deposits
bytes4 constant AAVE_SUPPLY = bytes4(keccak256("supply(address,uint256,address,uint16)"));
bytes4 constant AAVE_DEPOSIT = bytes4(keccak256("deposit(address,uint256,address,uint16)"));
bytes4 constant COMPOUND_MINT = bytes4(keccak256("mint(uint256)"));
bytes4 constant COMPOUND_SUPPLY = bytes4(keccak256("supply(address,uint256)"));
bytes4 constant ERC4626_DEPOSIT = bytes4(keccak256("deposit(uint256,address)"));
bytes4 constant MORPHO_SUPPLY = bytes4(keccak256("supply(address,address,uint256,uint256,bytes)"));

// Withdrawals
bytes4 constant AAVE_WITHDRAW = bytes4(keccak256("withdraw(address,uint256,address)"));
bytes4 constant COMPOUND_REDEEM = bytes4(keccak256("redeem(uint256)"));
bytes4 constant COMPOUND_WITHDRAW = bytes4(keccak256("withdraw(address,uint256)"));
bytes4 constant ERC4626_WITHDRAW = bytes4(keccak256("withdraw(uint256,address,address)"));
bytes4 constant ERC4626_REDEEM = bytes4(keccak256("redeem(uint256,address,address)"));
bytes4 constant MORPHO_WITHDRAW = bytes4(keccak256("withdraw(address,address,uint256,uint256,bytes)"));

// Swaps
bytes4 constant UNISWAP_EXACT_INPUT = bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))"));
bytes4 constant UNISWAP_EXACT_OUTPUT = bytes4(keccak256("exactOutputSingle((address,address,uint24,address,uint256,uint256,uint160))"));
bytes4 constant UNISWAP_V2_SWAP = bytes4(keccak256("swapExactTokensForTokens(uint256,uint256,address[],address,uint256)"));

// Claims
bytes4 constant AAVE_CLAIM = bytes4(keccak256("claimRewards(address[],uint256,address,address)"));
bytes4 constant COMPOUND_CLAIM = bytes4(keccak256("claim(address,address,bool)"));
```

### 13.4 Main Entry Point

```solidity
/// @notice Execute any protocol interaction with automatic classification
/// @param target Protocol address (must be in allowedAddresses)
/// @param data Calldata for the protocol call
/// @param tokenIn Token being spent (for DEPOSIT/SWAP, verified against calldata)
/// @param amountIn Amount being spent (for DEPOSIT/SWAP, verified against calldata)
function executeOnProtocol(
    address target,
    bytes calldata data,
    address tokenIn,
    uint256 amountIn
) external nonReentrant whenNotPaused {
    require(hasRole(msg.sender, DEFI_EXECUTE_ROLE), "Unauthorized");
    require(allowedAddresses[msg.sender][target], "Protocol not allowed");

    // 1. Classify operation from selector
    bytes4 selector = bytes4(data[:4]);
    OperationType opType = selectorType[selector];

    // 2. Route based on operation type
    if (opType == OperationType.UNKNOWN) {
        revert UnknownSelector(selector);
    }
    else if (opType == OperationType.WITHDRAW || opType == OperationType.CLAIM) {
        _executeNoSpendingCheck(msg.sender, target, data, opType);
    }
    else if (opType == OperationType.DEPOSIT || opType == OperationType.SWAP) {
        _executeWithSpendingCheck(msg.sender, target, data, tokenIn, amountIn, opType);
    }
}
```

### 13.5 Execution Handlers

#### 13.5.1 No Spending Check (Withdrawals, Claims)

```solidity
function _executeNoSpendingCheck(
    address subAccount,
    address target,
    bytes calldata data,
    OperationType opType
) internal {
    // Get expected output token from calldata parser
    ICalldataParser parser = protocolParsers[target];
    address outputToken = address(0);
    uint256 balanceBefore = 0;

    if (address(parser) != address(0)) {
        outputToken = parser.extractOutputToken(data);
        balanceBefore = IERC20(outputToken).balanceOf(avatar);
    }

    // Execute - NO spending check
    exec(target, 0, data, Enum.Operation.Call);

    // Calculate received
    uint256 received = 0;
    if (outputToken != address(0)) {
        received = IERC20(outputToken).balanceOf(avatar) - balanceBefore;
    }

    // Emit event for oracle to:
    // - Add received tokens as "acquired" (if WITHDRAW, not if CLAIM per design decision)
    // - Recover spending if matching deposit exists (WITHDRAW only)
    emit ProtocolExecution(
        subAccount,
        target,
        opType,
        address(0),  // No token spent
        0,           // No amount spent
        outputToken,
        received,
        0,           // No spending cost
        block.timestamp
    );
}
```

#### 13.5.2 With Spending Check (Deposits, Swaps)

```solidity
function _executeWithSpendingCheck(
    address subAccount,
    address target,
    bytes calldata data,
    address tokenIn,
    uint256 amountIn,
    OperationType opType
) internal {
    // 1. Get parser and verify tokenIn/amountIn match calldata
    ICalldataParser parser = protocolParsers[target];
    require(address(parser) != address(0), "No parser for protocol");

    address extractedToken = parser.extractInputToken(data);
    uint256 extractedAmount = parser.extractInputAmount(data);

    require(extractedToken == tokenIn, "Token mismatch - verify calldata");
    require(extractedAmount == amountIn, "Amount mismatch - verify calldata");

    // 2. Calculate spending cost (acquired balance is free)
    uint256 acquired = acquiredBalance[subAccount][tokenIn];
    uint256 fromOriginal = amountIn > acquired ? amountIn - acquired : 0;
    uint256 spendingCost = _estimateTokenValueUSD(tokenIn, fromOriginal);

    // 3. Check spending allowance
    require(spendingCost <= spendingAllowance[subAccount], "Exceeds spending allowance");

    // 4. Deduct from allowance
    spendingAllowance[subAccount] -= spendingCost;

    // 5. Deduct from acquired balance
    if (amountIn <= acquired) {
        acquiredBalance[subAccount][tokenIn] -= amountIn;
    } else {
        acquiredBalance[subAccount][tokenIn] = 0;
    }

    // 6. Snapshot output token (for swaps)
    address outputToken = address(0);
    uint256 outputBefore = 0;
    if (opType == OperationType.SWAP) {
        outputToken = parser.extractOutputToken(data);
        if (outputToken != address(0)) {
            outputBefore = IERC20(outputToken).balanceOf(avatar);
        }
    }

    // 7. Execute
    exec(target, 0, data, Enum.Operation.Call);

    // 8. Calculate output received (for swaps)
    uint256 outputReceived = 0;
    if (outputToken != address(0)) {
        outputReceived = IERC20(outputToken).balanceOf(avatar) - outputBefore;
    }

    // 9. Emit event for oracle
    emit ProtocolExecution(
        subAccount,
        target,
        opType,
        tokenIn,
        amountIn,
        outputToken,
        outputReceived,
        spendingCost,
        block.timestamp
    );
}
```

### 13.6 Calldata Parsers

Each supported protocol needs a parser to extract token/amount from calldata:

```solidity
interface ICalldataParser {
    /// @notice Extract the input token from calldata
    function extractInputToken(bytes calldata data) external pure returns (address);

    /// @notice Extract the input amount from calldata
    function extractInputAmount(bytes calldata data) external pure returns (uint256);

    /// @notice Extract the output token from calldata (for swaps/withdrawals)
    function extractOutputToken(bytes calldata data) external pure returns (address);
}

// Registry of parsers per protocol
mapping(address => ICalldataParser) public protocolParsers;
```

#### 13.6.1 Example: Aave V3 Parser

```solidity
contract AaveV3CalldataParser is ICalldataParser {

    // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
    bytes4 constant SUPPLY_SELECTOR = 0x617ba037;

    // withdraw(address asset, uint256 amount, address to)
    bytes4 constant WITHDRAW_SELECTOR = 0x69328dec;

    function extractInputToken(bytes calldata data) external pure returns (address) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR) {
            // First parameter is asset address
            return address(bytes20(data[16:36]));
        }

        revert("Unknown selector for input token");
    }

    function extractInputAmount(bytes calldata data) external pure returns (uint256) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR) {
            // Second parameter is amount
            return uint256(bytes32(data[36:68]));
        }

        revert("Unknown selector for input amount");
    }

    function extractOutputToken(bytes calldata data) external pure returns (address) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == WITHDRAW_SELECTOR) {
            // First parameter is asset address (being withdrawn)
            return address(bytes20(data[16:36]));
        }

        revert("Unknown selector for output token");
    }
}
```

#### 13.6.2 Example: Uniswap V3 Parser

```solidity
contract UniswapV3CalldataParser is ICalldataParser {

    // exactInputSingle((address tokenIn, address tokenOut, uint24 fee, address recipient,
    //                   uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96))
    bytes4 constant EXACT_INPUT_SINGLE = 0x414bf389;

    function extractInputToken(bytes calldata data) external pure returns (address) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == EXACT_INPUT_SINGLE) {
            // Struct starts at offset 4, tokenIn is first field
            return address(bytes20(data[16:36]));
        }

        revert("Unknown selector");
    }

    function extractInputAmount(bytes calldata data) external pure returns (uint256) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == EXACT_INPUT_SINGLE) {
            // amountIn is 5th field in struct (offset 4 + 4*32 = 132)
            return uint256(bytes32(data[132:164]));
        }

        revert("Unknown selector");
    }

    function extractOutputToken(bytes calldata data) external pure returns (address) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == EXACT_INPUT_SINGLE) {
            // tokenOut is 2nd field in struct
            return address(bytes20(data[48:68]));
        }

        revert("Unknown selector");
    }
}
```

### 13.7 Typed Fallback Functions

For protocols/selectors not in the registry:

```solidity
/// @notice Deposit to protocol when selector is not registered
/// @dev Use this for new/unregistered protocols
function depositTyped(
    address token,
    uint256 amount,
    address protocol,
    bytes calldata data
) external nonReentrant whenNotPaused {
    require(hasRole(msg.sender, DEFI_EXECUTE_ROLE), "Unauthorized");
    require(allowedAddresses[msg.sender][protocol], "Protocol not allowed");

    // Verify token is actually being transferred
    uint256 balanceBefore = IERC20(token).balanceOf(avatar);

    // Calculate spending
    uint256 acquired = acquiredBalance[msg.sender][token];
    uint256 fromOriginal = amount > acquired ? amount - acquired : 0;
    uint256 spendingCost = _estimateTokenValueUSD(token, fromOriginal);

    require(spendingCost <= spendingAllowance[msg.sender], "Exceeds allowance");
    spendingAllowance[msg.sender] -= spendingCost;

    // Deduct from acquired
    if (amount <= acquired) {
        acquiredBalance[msg.sender][token] -= amount;
    } else {
        acquiredBalance[msg.sender][token] = 0;
    }

    // Execute
    exec(protocol, 0, data, Enum.Operation.Call);

    // Verify token was actually spent
    uint256 balanceAfter = IERC20(token).balanceOf(avatar);
    uint256 actualSpent = balanceBefore - balanceAfter;
    require(actualSpent <= amount, "Spent more than declared");

    emit ProtocolExecution(
        msg.sender, protocol, OperationType.DEPOSIT,
        token, actualSpent, address(0), 0, spendingCost, block.timestamp
    );
}

/// @notice Withdraw from protocol when selector is not registered
/// @dev Use this for new/unregistered protocols
function withdrawTyped(
    address token,
    address protocol,
    bytes calldata data
) external nonReentrant whenNotPaused {
    require(hasRole(msg.sender, DEFI_EXECUTE_ROLE), "Unauthorized");
    require(allowedAddresses[msg.sender][protocol], "Protocol not allowed");

    uint256 balanceBefore = IERC20(token).balanceOf(avatar);

    // Execute - NO spending check
    exec(protocol, 0, data, Enum.Operation.Call);

    uint256 received = IERC20(token).balanceOf(avatar) - balanceBefore;

    emit ProtocolExecution(
        msg.sender, protocol, OperationType.WITHDRAW,
        address(0), 0, token, received, 0, block.timestamp
    );
}

/// @notice Execute swap when selector is not registered
function swapTyped(
    address tokenIn,
    uint256 amountIn,
    address tokenOut,
    address protocol,
    bytes calldata data
) external nonReentrant whenNotPaused {
    require(hasRole(msg.sender, DEFI_EXECUTE_ROLE), "Unauthorized");
    require(allowedAddresses[msg.sender][protocol], "Protocol not allowed");

    // Spending check for tokenIn
    uint256 acquired = acquiredBalance[msg.sender][tokenIn];
    uint256 fromOriginal = amountIn > acquired ? amountIn - acquired : 0;
    uint256 spendingCost = _estimateTokenValueUSD(tokenIn, fromOriginal);

    require(spendingCost <= spendingAllowance[msg.sender], "Exceeds allowance");
    spendingAllowance[msg.sender] -= spendingCost;

    if (amountIn <= acquired) {
        acquiredBalance[msg.sender][tokenIn] -= amountIn;
    } else {
        acquiredBalance[msg.sender][tokenIn] = 0;
    }

    // Snapshot output
    uint256 outputBefore = IERC20(tokenOut).balanceOf(avatar);

    // Execute
    exec(protocol, 0, data, Enum.Operation.Call);

    uint256 outputReceived = IERC20(tokenOut).balanceOf(avatar) - outputBefore;

    emit ProtocolExecution(
        msg.sender, protocol, OperationType.SWAP,
        tokenIn, amountIn, tokenOut, outputReceived, spendingCost, block.timestamp
    );
}
```

### 13.8 Registry Management

```solidity
/// @notice Register a selector to operation type mapping
function registerSelector(
    bytes4 selector,
    OperationType opType
) external onlyOwner {
    require(opType != OperationType.UNKNOWN, "Cannot register as UNKNOWN");
    selectorType[selector] = opType;
    emit SelectorRegistered(selector, opType);
}

/// @notice Batch register selectors
function registerSelectors(
    bytes4[] calldata selectors,
    OperationType[] calldata opTypes
) external onlyOwner {
    require(selectors.length == opTypes.length, "Length mismatch");
    for (uint i = 0; i < selectors.length; i++) {
        require(opTypes[i] != OperationType.UNKNOWN, "Cannot register as UNKNOWN");
        selectorType[selectors[i]] = opTypes[i];
    }
    emit SelectorsRegistered(selectors, opTypes);
}

/// @notice Register a calldata parser for a protocol
function registerParser(
    address protocol,
    ICalldataParser parser
) external onlyOwner {
    protocolParsers[protocol] = parser;
    emit ParserRegistered(protocol, address(parser));
}

/// @notice Unregister a selector (makes it UNKNOWN again)
function unregisterSelector(bytes4 selector) external onlyOwner {
    delete selectorType[selector];
    emit SelectorUnregistered(selector);
}
```

### 13.9 Security Analysis

| Attack Vector | Protection |
|---------------|------------|
| **Lie about tokenIn** | Calldata parser extracts real token, verified on-chain |
| **Lie about amountIn** | Calldata parser extracts real amount, verified on-chain |
| **Claim deposit is withdrawal** | Selector determines type, can't be faked |
| **Use unknown malicious selector** | Reverts with `UnknownSelector`, must use typed function |
| **Typed function abuse** | `depositTyped` verifies balance actually decreased |
| **Bypass spending check** | Only WITHDRAW/CLAIM skip check, determined by selector |
| **Register malicious selector** | Only owner can register, requires governance |

### 13.10 Gas Costs

| Operation | Additional Gas | Notes |
|-----------|----------------|-------|
| Selector lookup | ~200 | Single SLOAD |
| Calldata parsing | ~500-1000 | Pure function, no storage |
| Balance snapshot | ~2600 | Per token (cold SLOAD) |
| Price lookup | ~2600 | Single Chainlink call |
| **Total overhead** | ~6-10k | On top of protocol call |

### 13.11 Wallet Integration

The wallet needs to:

1. **Know the protocol being called** → determines parser
2. **Build the calldata** → standard for each protocol
3. **Pass tokenIn/amountIn** → extracted from same calldata it built

```typescript
// Example: Deposit 1000 USDC to Aave
const aavePool = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2";
const usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const amount = parseUnits("1000", 6);

// Build Aave supply calldata
const calldata = aavePool.interface.encodeFunctionData("supply", [
  usdc,      // asset
  amount,    // amount
  safe,      // onBehalfOf
  0          // referralCode
]);

// Call executeOnProtocol
await module.executeOnProtocol(
  aavePool,   // target
  calldata,   // data
  usdc,       // tokenIn (same as in calldata)
  amount      // amountIn (same as in calldata)
);
```

The contract verifies that `tokenIn` and `amountIn` match what's in `calldata`, so the wallet can't lie.

---

## Appendix A: Full Interface

```solidity
interface ISpendingLimitModule {

    // ============ Enums ============

    enum OperationType {
        UNKNOWN,
        SWAP,
        DEPOSIT,
        WITHDRAW,
        CLAIM,
        TRANSFER
    }

    // ============ Events ============

    event ProtocolExecution(
        address indexed subAccount,
        address indexed target,
        OperationType opType,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 spendingCost,
        uint256 timestamp
    );

    event SpendingAllowanceUpdated(address indexed subAccount, uint256 newAllowance, uint256 timestamp);
    event AcquiredBalanceUpdated(address indexed subAccount, address token, uint256 newBalance, uint256 timestamp);
    event BatchUpdate(address indexed subAccount, uint256 newAllowance, address[] tokens, uint256[] balances, uint256 timestamp);
    event SelectorRegistered(bytes4 indexed selector, OperationType opType);
    event ParserRegistered(address indexed protocol, address parser);
    event SafeValueUpdated(uint256 totalValueUSD, uint256 timestamp);

    // ============ Main Execution ============

    /// @notice Execute any protocol interaction with selector-based classification
    function executeOnProtocol(
        address target,
        bytes calldata data,
        address tokenIn,
        uint256 amountIn
    ) external;

    /// @notice Transfer tokens out of Safe (always costs spending)
    function transferToken(
        address token,
        address recipient,
        uint256 amount
    ) external;

    // ============ Typed Fallbacks (for unregistered selectors) ============

    function depositTyped(address token, uint256 amount, address protocol, bytes calldata data) external;
    function withdrawTyped(address token, address protocol, bytes calldata data) external;
    function swapTyped(address tokenIn, uint256 amountIn, address tokenOut, address protocol, bytes calldata data) external;

    // ============ Oracle Functions ============

    function updateSpendingAllowance(address subAccount, uint256 newAllowance) external;
    function updateAcquiredBalance(address subAccount, address token, uint256 newBalance) external;
    function batchUpdate(address subAccount, uint256 newAllowance, address[] calldata tokens, uint256[] calldata balances) external;
    function updateSafeValue(uint256 totalValueUSD) external;

    // ============ Registry Management (Owner) ============

    function registerSelector(bytes4 selector, OperationType opType) external;
    function registerSelectors(bytes4[] calldata selectors, OperationType[] calldata opTypes) external;
    function unregisterSelector(bytes4 selector) external;
    function registerParser(address protocol, ICalldataParser parser) external;

    // ============ View Functions ============

    function spendingAllowance(address subAccount) external view returns (uint256);
    function acquiredBalance(address subAccount, address token) external view returns (uint256);
    function selectorType(bytes4 selector) external view returns (OperationType);
    function protocolParsers(address protocol) external view returns (ICalldataParser);
    function lastOracleUpdate(address subAccount) external view returns (uint256);
    function safeValue() external view returns (uint256 totalValueUSD, uint256 lastUpdated);

    function canSpend(
        address subAccount,
        address token,
        uint256 amount
    ) external view returns (bool allowed, uint256 spendingCost, uint256 fromAcquired);

    function getOperationType(bytes4 selector) external view returns (OperationType);
}

interface ICalldataParser {
    function extractInputToken(bytes calldata data) external pure returns (address);
    function extractInputAmount(bytes calldata data) external pure returns (uint256);
    function extractOutputToken(bytes calldata data) external pure returns (address);
}
```

---

## Appendix B: Glossary

| Term | Definition |
|------|------------|
| **Original Balance** | Token balance that costs spending to use (not acquired, or acquired that has expired) |
| **Acquired Balance** | Exact token amount received from operations; free to use but expires after 24h |
| **Acquired Expiry** | After 24 hours, acquired tokens become "original" and cost spending to use again |
| **Spending Allowance** | Remaining USD value a sub-account can spend (oracle-managed) |
| **Recovery** | Reduction in spending when withdrawing from protocols |
| **Rolling Window** | 24h sliding window for spending and acquired balance tracking (oracle-managed) |
| **Selector** | First 4 bytes of calldata identifying the function being called |
| **Operation Type** | Classification: SWAP, DEPOSIT, WITHDRAW, CLAIM, TRANSFER |
| **Calldata Parser** | Contract that extracts token/amount from protocol-specific calldata |
| **Oracle** | Off-chain service (Chainlink CRE) that manages spending allowances |
| **Safe** | Gnosis Safe multisig that holds the funds (avatar) |
| **Sub-Account** | EOA delegated to operate on behalf of the Safe |
