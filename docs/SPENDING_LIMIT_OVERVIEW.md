# Spending Limit Mechanism - Overview

## What is MultiSub?

MultiSub enables **Safe multisig owners** to delegate DeFi operations to **sub-accounts** (hot wallets) while maintaining strict spending controls. Sub-accounts can interact with whitelisted protocols but cannot exceed their allocated spending limits.

```
┌─────────────────────────────────────────────────────────────────┐
│                     MULTISUB ARCHITECTURE                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Safe Multisig (holds funds)                                   │
│         │                                                       │
│         │ enables module                                        │
│         ▼                                                       │
│   DeFiInteractorModule                                          │
│         │                                                       │
│         │ delegates operations to                               │
│         ▼                                                       │
│   Sub-Accounts (hot wallets)                                    │
│         │                                                       │
│         │ interact with                                         │
│         ▼                                                       │
│   Whitelisted DeFi Protocols (Aave, Uniswap, etc.)              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## The Problem

Without spending limits, a compromised sub-account could drain the entire Safe. We need:

1. **Cap how much each sub-account can use** (e.g., 5% of portfolio per day)
2. **Allow operational flexibility** (swap, deposit, withdraw without getting stuck)
3. **Prevent gaming** (can't bypass limits by swapping back and forth)

---

## The Solution: Acquired Balance Model

### Core Concept

- **Original tokens** (in Safe at start of day) → using them **costs spending**
- **Acquired tokens** (received from operations) → **free to use**

**Critical Rules:**
1. **Exact amount tracking**: Only the specific amount received is acquired (swap USDC for 0.1 ETH → only 0.1 ETH is acquired, not all ETH in Safe)
2. **24h expiry**: Acquired status expires after 24 hours. After expiry, tokens become "original" again and cost spending to use.

This allows sub-accounts to:
- Swap USDC → ETH (costs spending)
- Use that ETH for further operations (free)
- Deposit ETH to Aave (free, since ETH was acquired)
- Withdraw from Aave (free, tokens become acquired)

### Example Flow

```
Day Start:
  Portfolio: $100,000
  Sub-account limit: 5% = $5,000
  Safe holds: 50,000 USDC, 10 ETH

1. Swap $5,000 USDC → 2 ETH
   ✓ Spending used: $5,000 (at limit)
   ✓ 2 ETH marked as "acquired"

2. Deposit 2 ETH to Aave
   ✓ Spending used: still $5,000 (ETH was acquired = free)
   ✓ Deposit tracked (for acquired matching on withdrawal)

3. Sub-account tries to swap more USDC
   ✗ BLOCKED - already at $5,000 limit

4. Withdraw 2 ETH from Aave
   ✓ FREE (withdrawals don't cost spending)
   ✓ 2 ETH marked as "acquired" (matched to deposit)

5. Sub-account can use the 2 ETH freely (acquired)
   But still at $5,000 spending limit until window resets
```

---

## Operation Types

| Operation | Costs Spending? | Output Acquired? |
|-----------|-----------------|------------------|
| **Swap** | Yes (original only) | Yes |
| **Deposit** | Yes (original only) | No |
| **Withdraw** | No (FREE) | Conditional* |
| **Claim Rewards** | No (FREE) | Conditional** |
| **Approve** | No (capped***) | N/A |
| **Transfer Out** | Always | N/A |

\* Only if deposit matched by the same subaccount to the same protocol in the time window.
\*\* Only if deposit matched by the same subaccount to the same protocol in the time window (same rule as withdrawals).
\*\*\* Approve doesn't consume spending, but is capped: acquired tokens can be approved freely, original tokens approval is capped by spending allowance. Actual spending is deducted at execution (swap/deposit).

---

## How It Works (Hybrid On-Chain/Off-Chain)

```
┌─────────────────────────────────────────────────────────────────┐
│                      SYSTEM ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Sub-Account Wallet                                             │
│       │                                                         │
│       │ calls executeOnProtocol(target, data, tokenIn, amount)  │
│       ▼                                                         │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              On-Chain Contract                          │    │
│  │  1. Classify operation from function selector           │    │
│  │  2. Verify tokenIn/amount match calldata                │    │
│  │  3. Check & update spending allowance                   │    │
│  │  4. Execute through Safe                                │    │
│  │  5. Emit ProtocolExecution event                        │    │
│  └─────────────────────────────────────────────────────────┘    │
│       │                                                         │
│       │ emits events                                            │
│       ▼                                                         │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Off-Chain Oracle (Chainlink CRE)           │    │
│  │  1. Monitor events                                      │    │
│  │  2. Track spending in rolling 24h window                │    │
│  │  3. Match deposits to withdrawals (for acquired status) │    │
│  │  4. Calculate spending allowances                       │    │
│  │  5. Update contract state                               │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### On-Chain Responsibilities

- **Simple enforcement**: Check `spendingCost <= spendingAllowance`
- **Selector classification**: Determine operation type from function signature
- **Calldata verification**: Extract and verify token/amount from calldata
- **Execute through Safe**: Call protocol via `execTransactionFromModule`

### Off-Chain Oracle Responsibilities

- **Rolling window tracking**: Spending expires after 24 hours
- **Deposit/withdrawal matching**: Mark withdrawn tokens as acquired if matched to deposit
- **Acquired balance management**: Track which tokens are free to use
- **Portfolio valuation**: Calculate total value from balances + prices

---

## Security Features

### 1. Selector-Based Classification

Operations are classified by their function selector (first 4 bytes of calldata). A compromised sub-account **cannot lie** about operation type.

```
Aave deposit selector: 0x617ba037 → DEPOSIT (costs spending)
Aave withdraw selector: 0x69328dec → WITHDRAW (free)
```

### 2. Calldata Verification

The contract extracts token and amount directly from calldata and verifies they match what the wallet claims. **Cannot lie about what's being spent.**

### 3. Allowlist Enforcement

Sub-accounts can only interact with **whitelisted protocols**. Even if compromised, they cannot call arbitrary contracts.

### 4. Oracle Freshness Check

Operations are blocked if oracle data is stale (>15 minutes). Prevents operating with outdated allowances.

### 5. Hard Safety Cap

Oracle cannot set allowances above an absolute maximum (e.g., 20% of portfolio). Prevents oracle bugs from enabling unlimited spending.

---

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Yield/rewards acquired? | **Conditional** | Only if deposit matched by same subaccount to same protocol in window |
| Withdrawals become acquired? | **Conditional** | Only if deposit matched by same subaccount in time window |
| Transfers cost spending? | **Always** | Value leaves Safe, must be controlled |
| Approve consume spending? | **No (capped)** | Capped by allowance for original tokens, by amount acquired for acquired tokens, deducted at execution |
| Window type | **Rolling 24h** | Smoother than fixed reset, harder to game |
| Selector unknown? | **Revert** | Must use typed fallback function |

---

## Wallet Integration

The wallet calls a single function for all protocol interactions:

```typescript
// Deposit 1000 USDC to Aave
const calldata = aavePool.interface.encodeFunctionData("supply", [
  USDC,    // asset
  1000e6,  // amount
  safe,    // onBehalfOf
  0        // referralCode
]);

await module.executeOnProtocol(
  AAVE_POOL,   // target
  calldata,    // data
  USDC,        // tokenIn
  1000e6       // amountIn
);
```

The contract verifies `tokenIn` and `amountIn` match the calldata, so the wallet cannot cheat.

---

## Emergency Controls

| Control | Purpose |
|---------|---------|
| `pause()` | Freeze all module operations |
| `revokeRole()` | Remove sub-account permissions instantly |
| `unregisterSelector()` | Block specific operation types |
| `setAllowedAddresses(false)` | Remove protocol from whitelist |

---

## Summary

1. **Sub-accounts get daily spending limits** based on portfolio percentage
2. **Operations are classified automatically** from function selectors
3. **Acquired tokens are free to use** (from swaps, withdrawals) - only exact amounts received
4. **Acquired status expires after 24h** - tokens become "original" and cost spending again
5. **Spending is one-way** - once consumed, only resets when 24h window expires
6. **Oracle manages rolling windows** and updates allowances
7. **On-chain verification** prevents lying about operations
8. **Multiple safety layers** protect against compromised sub-accounts

