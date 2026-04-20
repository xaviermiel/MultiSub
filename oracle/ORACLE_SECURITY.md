# Oracle Security: Compromise Risk & Mitigations

## 1. The Risk: Oracle Key Compromise

### Trust Model

The oracle EOA has three setter functions on `DeFiInteractorModule`:

| Function                                                            | What it controls                                 | On-chain cap                                                                                        |
| ------------------------------------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| `updateSafeValue(uint256)`                                          | USD portfolio value used to compute spending cap | Snapshotted at window start; mid-window inflation has no effect                                     |
| `updateSpendingAllowance(address, uint256 version, uint256)`        | USD budget for original tokens                   | Per-account cap (`maxSpendingBps * safeValue` or `maxSpendingUSD`) + cumulative cap + version check |
| `updateAcquiredBalance(address, address, uint256 version, uint256)` | Per-token balance that bypasses spending limits  | `_capToSafeBalance` + cumulative oracle acquired budget + version check                             |

### What the Oracle Cannot Do (Enforced On-Chain)

1. **Reset cumulative spending** — `cumulativeSpent` is only incremented by execution functions (`_executeWithSpendingCheck`, `transferToken`). The oracle has no write access.
2. **Inflate `safeValue` mid-window** — `windowSafeValue` is snapshotted once per window at the first operation. Subsequent `updateSafeValue` calls don't affect the spending cap until the next window.
3. **Grant unlimited acquired balance** — `cumulativeOracleGrantedUSD` tracks all oracle-granted acquired increases per window. Capped at `maxOracleAcquiredBps * windowSafeValue / 10000` (default 20%).
4. **Set allowance above the sub-account cap** — `_enforceAllowanceCap` enforces the per-account limit (`maxSpendingBps * safeValue` in BPS mode or `maxSpendingUSD` in USD mode). Unconfigured accounts fall back to `DEFAULT_MAX_SPENDING_BPS` (5%).
5. **Overwrite stale state** — monotonic version counters (`allowanceVersion`, `acquiredBalanceVersion`) require the oracle to pass the expected version it read. If on-chain state changed since the oracle read (e.g., agent spent, Tier 1 marked swap output), the update is skipped. Prevents the oracle from undoing on-chain mutations.

### Maximum Damage from Compromised Oracle (Per Window)

```
(per-account) maxSpendingBps/maxSpendingUSD + maxOracleAcquiredBps
```

The per-account spending limit is configured via `setSubAccountLimits()`; the oracle acquired budget is configured via `setMaxOracleAcquiredBps()` (default 20%). This is a **mathematical guarantee** enforced by on-chain cumulative counters the oracle cannot reset.

---

## 2. Implemented Mitigations

### Solution 1: On-Chain Cumulative Spending Tracker

Tracks total USD spent per sub-account per window **inside the contract**, incremented only by execution functions.

#### State Variables

```solidity
mapping(address => uint256) public windowStart;        // Window start timestamp
mapping(address => uint256) public windowSafeValue;    // Safe value snapshot at window start
mapping(address => uint256) public cumulativeSpent;    // USD spent in current window
```

#### Mechanism

```solidity
function _trackCumulativeSpending(address subAccount, uint256 spendingCost) internal {
    if (spendingCost == 0) return;

    (uint256 maxSpendingBps, uint256 maxSpendingUSD, uint256 windowDuration) = getSubAccountLimits(subAccount);

    // New window: snapshot safeValue, reset counter
    if (windowStart[subAccount] == 0 || block.timestamp > windowStart[subAccount] + windowDuration) {
        _requireFreshSafeValue();
        windowStart[subAccount] = block.timestamp;
        windowSafeValue[subAccount] = safeValue.totalValueUSD;
        cumulativeSpent[subAccount] = 0;
    }

    cumulativeSpent[subAccount] += spendingCost;

    // Dual-mode cap computation (per-account)
    uint256 maxSpending = maxSpendingUSD > 0
        ? maxSpendingUSD
        : (windowSafeValue[subAccount] * maxSpendingBps) / 10000;

    if (cumulativeSpent[subAccount] > maxSpending) revert ExceedsCumulativeSpendingLimit(...);
}
```

Called from both `_executeWithSpendingCheck` and `transferToken`.

#### What It Fixes

- **Spending reset**: cumulative counter only written by execution functions, never by oracle
- **`safeValue` inflation**: `windowSafeValue` snapshotted once per window, oracle can't inflate mid-window
- **Allowance becomes advisory**: `spendingAllowance` from the oracle is a UX hint; real enforcement is on-chain

---

### Solution 6: Hybrid On-Chain Acquired Marking

Two-tier system: trustless for swaps, budget-capped for oracle-managed operations.

#### Tier 1 — On-chain Swap Marking (Trustless)

SWAP outputs are marked as acquired immediately by the contract after execution:

```solidity
// In _executeWithSpendingCheck, after execution:
if (opType == OperationType.SWAP) {
    for (uint256 i = 0; i < tokensOut.length; i++) {
        if (amountsOut[i] > 0) {
            acquiredBalance[subAccount][tokensOut[i]] += amountsOut[i];
        }
    }
}
```

Covers all DEX operations (Uniswap, 1inch, Paraswap, KyberSwap) — the highest-frequency operation type. No oracle involvement.

#### Tier 2 — Oracle Acquired Budget (Capped)

For WITHDRAW/CLAIM outputs, the oracle marks tokens as acquired after deposit/withdrawal matching. The oracle's power is bounded by a per-window cumulative budget:

```solidity
mapping(address => uint256) public acquiredGrantWindowStart;
mapping(address => uint256) public cumulativeOracleGrantedUSD;
uint256 public maxOracleAcquiredBps = 2000; // 20% of Safe value per window
```

```solidity
function _trackOracleAcquiredGrant(address subAccount, address token, uint256 oldBalance, uint256 newBalance) internal {
    if (newBalance <= oldBalance) return; // Decreases always allowed

    uint256 increaseValueUSD = _estimateTokenValueUSD(token, newBalance - oldBalance);

    // Window check/reset
    if (acquiredGrantWindowStart[subAccount] == 0
        || block.timestamp > acquiredGrantWindowStart[subAccount] + windowDuration) {
        acquiredGrantWindowStart[subAccount] = block.timestamp;
        cumulativeOracleGrantedUSD[subAccount] = 0;
    }

    cumulativeOracleGrantedUSD[subAccount] += increaseValueUSD;

    uint256 refValue = windowSafeValue[subAccount] > 0 ? windowSafeValue[subAccount] : safeValue.totalValueUSD;
    uint256 maxGrant = (refValue * maxOracleAcquiredBps) / 10000;

    if (cumulativeOracleGrantedUSD[subAccount] > maxGrant) revert ExceedsOracleAcquiredBudget(...);
}
```

Called from `updateAcquiredBalance` and `batchUpdate`.

---

### Per-Account Cap in `_enforceAllowanceCap`

The allowance cap is derived entirely from the sub-account's configured limit. USD-mode accounts cap at `maxSpendingUSD`; BPS-mode accounts cap at `maxSpendingBps * safeValue`. Unconfigured accounts fall back to `DEFAULT_MAX_SPENDING_BPS` (5%).

```solidity
function _enforceAllowanceCap(address subAccount, uint256 newAllowance) internal view {
    (uint256 maxSpendingBps, uint256 maxSpendingUSD,) = getSubAccountLimits(subAccount);

    uint256 maxAllowance;
    if (maxSpendingUSD > 0) {
        maxAllowance = maxSpendingUSD;
    } else {
        _requireFreshSafeValue();
        maxAllowance = (safeValue.totalValueUSD * maxSpendingBps) / 10000;
    }

    if (newAllowance > maxAllowance) revert ExceedsAllowanceCap(newAllowance, maxAllowance);
}
```

### Optimistic Concurrency (Version Counters)

Every mutation to `spendingAllowance` or `acquiredBalance` bumps a monotonic version counter. The oracle must pass the version it read when computing; the contract skips the update if the version changed.

```solidity
mapping(address => uint256) public allowanceVersion;
mapping(address => mapping(address => uint256)) public acquiredBalanceVersion;
```

**Why this matters:** Without version checks, a race condition exists:

1. Tier 1 marks swap output as acquired (100 tokens)
2. Agent spends all 100 → acquired balance returns to 0
3. Oracle (computed before step 2) tries to SET acquired to 100
4. Values match (both 0) → oracle overwrites, restoring 100 tokens as acquired

With version counters, steps 1 and 2 each bump the version. The oracle's expected version (from before step 1) no longer matches → update is skipped.

Updates that are skipped still refresh `lastOracleUpdate` (the oracle is alive) and emit `OracleUpdateSkipped`. The oracle retries on the next cycle with fresh versions.

---

## 3. Combined Protection Summary

| Attack Vector                        | Protection                                          | Enforced By                            |
| ------------------------------------ | --------------------------------------------------- | -------------------------------------- |
| Spending allowance reset             | On-chain cumulative counter per window              | Contract execution functions           |
| `safeValue` inflation                | Window-start snapshot                               | Contract (first op in new window)      |
| Acquired balance reset (swaps)       | Marked on-chain at execution time                   | Contract (`_executeWithSpendingCheck`) |
| Acquired balance reset (withdrawals) | Cumulative oracle budget per window                 | Contract (`updateAcquiredBalance`)     |
| Allowance inflation                  | Per-account `maxSpendingBps` / `maxSpendingUSD` cap | Contract (`_enforceAllowanceCap`)      |
| Stale oracle overwrites              | Monotonic version counters                          | Contract (all oracle update functions) |

**Oracle role after mitigations:**

| Before                                | After                                                                              |
| ------------------------------------- | ---------------------------------------------------------------------------------- |
| Full control of spending allowance    | Provides freshness attestation; spending tracked on-chain; version-gated writes    |
| Full control of all acquired balances | Only manages WITHDRAW/CLAIM acquired, within a capped budget; version-gated writes |
| Full control of `safeValue`           | `safeValue` is snapshotted at window start; mid-window inflation has no effect     |
| Stateless overwrites                  | Version counters prevent overwriting state that changed since oracle read          |

---

## 4. Configuration

| Parameter              | Default       | Owner Function              | Description                                                        |
| ---------------------- | ------------- | --------------------------- | ------------------------------------------------------------------ |
| `maxSpendingBps`       | 500 (default) | `setSubAccountLimits()`     | Per-account spending cap as % of Safe value (BPS mode)             |
| `maxSpendingUSD`       | —             | `setSubAccountLimits()`     | Per-account fixed USD cap (USD mode — mutually exclusive with BPS) |
| `maxOracleAcquiredBps` | 2000          | `setMaxOracleAcquiredBps()` | Oracle acquired budget (20%)                                       |
| `maxOracleAge`         | 60 min        | —                           | Max staleness before operations freeze                             |
| `maxSafeValueAge`      | 60 min        | —                           | Max staleness for safe value                                       |

**Tuning guidance:**

- `maxOracleAcquiredBps` must be generous enough for legitimate withdrawals. A sub-account that routinely moves 20% of Safe value through DeFi needs at least 20% budget.
- If oracle budget is exhausted by legitimate activity, further withdrawn tokens are treated as original — the sub-account must use spending allowance for them.

---

## 5. Alternative: Chainlink CRE Migration

The project previously used Chainlink CRE (Computation Runtime Environment). CRE and on-chain caps protect against different threats:

| Threat                    | CRE                   | On-chain caps (Solutions 1 + 6) |
| ------------------------- | --------------------- | ------------------------------- |
| Oracle key theft          | Yes (no single key)   | Yes (limits damage)             |
| Oracle logic bug          | No (executes the bug) | Yes (hard cap regardless)       |
| Workflow owner compromise | No                    | Yes                             |
| Supply chain attack       | No                    | Yes                             |
| DON threshold compromise  | No                    | Yes                             |

On-chain caps provide a **mathematical guarantee from the contract alone**. CRE provides a **probabilistic guarantee** based on the difficulty of compromising the DON. Both can be combined.
