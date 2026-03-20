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

1. **Cap how much each sub-account can use** (e.g., 5% of portfolio per day, or a fixed USD amount)
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

| Operation         | Costs Spending?           | Output Acquired? |
| ----------------- | ------------------------- | ---------------- |
| **Swap**          | Yes (original only)       | Yes              |
| **Deposit**       | Yes (original only)       | No               |
| **Withdraw**      | No (FREE)                 | Conditional\*    |
| **Claim Rewards** | No (FREE)                 | Conditional\*\*  |
| **Approve**       | No (capped\*\*\*)         | N/A              |
| **Repay Debt**    | No (permissioned\*\*\*\*) | N/A              |
| **Transfer Out**  | Yes (original only**\***) | N/A              |

\* Only if deposit matched by the same subaccount to the same protocol in the time window.
\*\* Only if deposit matched by the same subaccount to the same protocol in the time window (same rule as withdrawals).
\*\*\* Approve doesn't consume spending, but is capped: acquired tokens can be approved freely, original tokens approval is capped by spending allowance. Actual spending is deducted at execution (swap/deposit).
\*\*\*\* Requires DEFI_REPAY_ROLE (3). Granted via `grantRole(subAccount, 3)`. No spending check — repaying debt improves the Safe's health factor.
\*\*\*\*\* Transfers use acquired balance first (free), then original tokens cost spending for the remainder.

---

## How It Works (Hybrid On-Chain/Off-Chain)

```
┌─────────────────────────────────────────────────────────────────┐
│                      SYSTEM ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Sub-Account Wallet                                             │
│       │                                                         │
│       │ calls executeOnProtocol(target, data)                   │
│       ▼                                                         │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              On-Chain Contract                          │    │
│  │  1. Classify operation from function selector           │    │
│  │  2. Extract tokenIn/amount from calldata via parser     │    │
│  │  3. Check & update spending allowance                   │    │
│  │  4. Execute through Safe (exec → avatar)                │    │
│  │  5. Emit ProtocolExecution event                        │    │
│  └─────────────────────────────────────────────────────────┘    │
│       │                                                         │
│       │ emits events                                            │
│       ▼                                                         │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Off-Chain Oracle (oracle)                  │    │
│  │  1. Monitor events                                      │    │
│  │  2. Track spending in rolling 24h window                │    │
│  │  3. Match deposits to withdrawals (for acquired status) │    │
│  │  4. Calculate spending allowances                       │    │
│  │  5. Update contract state (spendingAllowance, etc.)     │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### On-Chain Responsibilities

- **Simple enforcement**: Check `spendingCost <= spendingAllowance`
- **Selector classification**: Determine operation type from function signature
- **Parser-based extraction**: Extract token/amount from calldata via registered parsers
- **Execute through Safe**: Call protocol via Zodiac Module's `exec()` function

### Off-Chain Oracle Responsibilities

- **Event-driven processing**: RPC polling for ProtocolExecution and TransferExecuted events
- **Rolling window tracking**: Spending expires after 24 hours (one-way, no recovery)
- **Deposit/withdrawal matching**: Mark withdrawn tokens as acquired if matched to deposit
- **FIFO acquired balance management**: Track which tokens are free to use with timestamp inheritance
- **Multi-module support**: Monitor multiple DeFiInteractorModule instances via registry
- **Periodic refresh**: Cron-based updates as spending expires
- **Portfolio valuation**: Calculate total value from balances + Chainlink prices

---

## Security Features

### 1. Selector-Based Classification

Operations are classified by their function selector (first 4 bytes of calldata). A compromised sub-account **cannot lie** about operation type.

```
Aave deposit selector: 0x617ba037 → DEPOSIT (costs spending)
Aave withdraw selector: 0x69328dec → WITHDRAW (free)
```

### 2. Calldata Verification

The contract extracts token and amount directly from calldata via registered parsers. The wallet cannot specify different values—they are parsed from the actual calldata being executed. **Cannot lie about what's being spent.**

### 3. Allowlist Enforcement

Sub-accounts can only interact with **whitelisted protocols**. Even if compromised, they cannot call arbitrary contracts.

### 4. Oracle Freshness Check

Operations are blocked if oracle data is stale (default: >60 minutes). Prevents operating with outdated allowances.

### 5. On-Chain Cumulative Spending Cap

Every spend is tracked by an on-chain cumulative counter (`cumulativeSpent`) that the oracle **cannot reset**. Even if the oracle resets `spendingAllowance`, the cumulative counter blocks spending beyond the per-window limit. `windowSafeValue` is snapshotted at window start, so mid-window `safeValue` inflation has no effect.

### 6. Swap Output Auto-Marking (Tier 1 Acquired)

SWAP outputs are auto-marked as acquired **on-chain** immediately after execution. No oracle involvement — fully trustless for the most common DeFi operation.

### 7. Oracle Acquired Budget (Tier 2)

For WITHDRAW/CLAIM outputs, the oracle can mark tokens as acquired but is bounded by a per-window cumulative budget (`maxOracleAcquiredBps`, default 20% of Safe value). This counter cannot be reset by the oracle.

### 8. Per-Account USD Cap

For sub-accounts using fixed USD limits (`maxSpendingUSD`), the oracle cannot push the allowance above the per-account cap — `_enforceAllowanceCap` takes the minimum of the global BPS cap and the per-account USD limit.

---

## Key Design Decisions

| Decision                     | Choice          | Rationale                                                                                              |
| ---------------------------- | --------------- | ------------------------------------------------------------------------------------------------------ |
| Yield/rewards acquired?      | **Conditional** | Only if deposit matched by same subaccount to same protocol in window                                  |
| Withdrawals become acquired? | **Conditional** | Only if deposit matched by same subaccount in time window                                              |
| Transfers cost spending?     | **Always**      | Value leaves Safe, must be controlled                                                                  |
| Approve consume spending?    | **No (capped)** | Capped by allowance for original tokens, by amount acquired for acquired tokens, deducted at execution |
| Window type                  | **Rolling 24h** | Smoother than fixed reset, harder to game                                                              |
| Selector unknown?            | **Revert**      | Must register selector and parser for the protocol                                                     |

---

## Wallet Integration

The wallet calls a single function for all protocol interactions:

```typescript
// Deposit 1000 USDC to Aave
const calldata = aavePool.interface.encodeFunctionData("supply", [
  USDC, // asset
  1000e6, // amount
  safe, // onBehalfOf
  0, // referralCode
]);

await module.executeOnProtocol(
  AAVE_POOL, // target
  calldata, // data
);
```

The contract extracts `tokenIn` and `amountIn` from the calldata via registered parsers, so the wallet cannot lie about what's being spent.

---

## Emergency Controls

| Control                      | Purpose                                  |
| ---------------------------- | ---------------------------------------- |
| `pause()`                    | Freeze all module operations             |
| `revokeRole()`               | Remove sub-account permissions instantly |
| `unregisterSelector()`       | Block specific operation types           |
| `setAllowedAddresses(false)` | Remove protocol from whitelist           |

---

## Summary

1. **Sub-accounts get daily spending limits** based on portfolio percentage (BPS mode) or a fixed USD amount (USD mode)
2. **Operations are classified automatically** from function selectors
3. **Acquired tokens are free to use** (from swaps, withdrawals) - only exact amounts received
4. **Swap outputs are auto-marked acquired on-chain** (trustless, no oracle needed)
5. **Acquired status expires after 24h** - tokens become "original" and cost spending again
6. **Spending is one-way** - once consumed, only resets when 24h window expires
7. **On-chain cumulative spending counter** prevents oracle from resetting spent budget
8. **Oracle acquired budget** caps how much the oracle can grant as acquired per window
9. **Safe value is snapshotted at window start** - oracle can't inflate mid-window
10. **Oracle uses RPC polling** for event processing + cron for periodic refresh
11. **FIFO queues track acquired balances** with timestamp inheritance through swaps
12. **On-chain verification** prevents lying about operations
13. **Multiple safety layers** protect against compromised sub-accounts and oracle
