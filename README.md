# MultiSub

> A secure self-custody DeFi wallet built as a **custom Zodiac module**, combining Safe multisig security with delegated permission-restricted interactions.

[![Solidity](https://img.shields.io/badge/solidity-0.8.20-blue)]()
[![Tests](https://img.shields.io/badge/tests-446%20passing-brightgreen)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()
[![Zodiac](https://img.shields.io/badge/zodiac-module-purple)]()

## Overview

MultiSub is a **custom Zodiac module** that enables Safe multisig owners to delegate DeFi operations to sub-accounts (hot wallets) while maintaining strict security controls.

**The Problem**: Traditional self-custody forces you to choose between security (multisig), usability (hot wallet), or flexibility (delegation).

**Our Solution**: A self-contained Zodiac module with integrated role management, per-sub-account allowlists, and time-windowed limits.

## Quick Start

```bash
# 1. Install
git clone <repository-url>
cd MultiSub
forge install && forge build

# 2. Deploy module and enable on Safe
SAFE_ADDRESS=0x... AUTHORIZED_UPDATER=0x... \
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY

# 3. Deploy parsers and register selectors
SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... \
forge script script/ConfigureParsersAndSelectors.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY

# 4. Configure sub-accounts
SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... SUB_ACCOUNT_ADDRESS=0x... \
forge script script/ConfigureSubaccount.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
```

**Prerequisites**: [Foundry](https://getfoundry.sh/), a deployed [Safe](https://app.safe.global/)

## Architecture

```
┌────────────────────────────────────┐
│        Safe Multisig               │
│      (Avatar & Owner)              │
│                                    │
│  • Enables/disables module         │
│  • Configures roles & limits       │
│  • Emergency controls              │
└─────────────┬──────────────────────┘
              │ enableModule()
              ↓
┌────────────────────────────────────┐
│    DeFiInteractorModule            │
│    (Custom Zodiac Module)          │
│                                    │
│  Features:                         │
│  ├─ 2 Roles (Execute, Transfer)    │
│  ├─ Per-sub-account allowlists     │
│  ├─ Customizable limits            │
│  └─ Emergency pause                │
│                                    │
│  Uses: exec() → Safe               │
└─────────────┬──────────────────────┘
              │
              ↓
┌────────────────────────────────────┐
│      Sub-Accounts (EOAs)           │
│                                    │
│  • executeOnProtocol()             │
│  • executeOnProtocolWithValue()    │
│  • transferToken()                 │
└────────────────────────────────────┘
```

## Key Features

### Streamlined Roles

- **DEFI_EXECUTE_ROLE (1)**: Execute protocol operations (swaps, deposits, withdrawals, claims, approvals)
- **DEFI_TRANSFER_ROLE (2)**: Transfer tokens out of Safe
- **DEFI_REPAY_ROLE (3)**: Repay protocol debt (no spending check — improves Safe health)

### Acquired Balance Model

The spending limit mechanism distinguishes between:

- **Original tokens** (in Safe at start of window) → using them **costs spending**
- **Acquired tokens** (received from operations) → **free to use**

This allows sub-accounts to chain operations (swap → deposit → withdraw) without hitting limits on every step.

**Critical Rules:**

1. Only the exact amount received is marked as acquired
2. Acquired status expires after 24 hours (tokens become "original" again)

### Operation Types

| Operation         | Costs Spending?     | Output Acquired? |
| ----------------- | ------------------- | ---------------- |
| **Swap**          | Yes (original only) | Yes              |
| **Deposit**       | Yes (original only) | No               |
| **Withdraw**      | No (FREE)           | Conditional\*    |
| **Claim Rewards** | No (FREE)           | Conditional\*    |
| **Approve**       | No (capped)         | N/A              |
| **Repay Debt**    | No (REPAY role\*\*) | N/A              |
| **Transfer Out**  | Always              | N/A              |

\* Only if deposit matched by the same subaccount to the same protocol in the time window.
\*\* Requires DEFI_REPAY_ROLE (3). Granted via `grantRole(subAccount, 3)`. Improves Safe health factor.

### Granular Controls

- **Per-Sub-Account Allowlists**: Each sub-account has its own protocol whitelist
- **Dual-Mode Spending Limits**: Configurable as either a percentage of Safe value (BPS mode) or a fixed USD amount (USD mode) per sub-account
- **Rolling Windows**: 24-hour rolling windows prevent rapid drain attacks

### Security

- **Selector-Based Classification**: Operations classified by function selector
- **Calldata Verification**: Token/amount extracted from calldata and verified
- **Allowlist Enforcement**: Sub-accounts can only interact with whitelisted protocols
- **Oracle Freshness Check**: Operations blocked if oracle data is stale (>60 minutes)
- **Cumulative Spending Cap**: On-chain `cumulativeSpent` counter that the oracle cannot reset — real spending enforcement
- **Safe Value Snapshot**: `windowSafeValue` frozen at window start — oracle can't inflate mid-window
- **Swap Auto-Marking (Tier 1)**: Swap outputs auto-marked as acquired on-chain, no oracle needed
- **Oracle Acquired Budget (Tier 2)**: `cumulativeOracleGrantedUSD` caps oracle's acquired grants per window (default 20%)
- **Per-Account Allowance Cap**: `_enforceAllowanceCap` enforces the sub-account's `maxSpendingBps` (BPS mode) or `maxSpendingUSD` (USD mode)
- **Version Counters**: Oracle must pass expected version; stale writes are skipped to prevent overwriting on-chain state changes
- Emergency pause mechanism
- Instant role revocation

**Max oracle compromise damage per window**: per-account spending cap (`maxSpendingBps` or `maxSpendingUSD`) + `maxOracleAcquiredBps` (default 20%). See [`oracle/ORACLE_SECURITY.md`](./oracle/ORACLE_SECURITY.md).

## Default Limits

If not configured, sub-accounts use:

- **Max Spending**: 5% of portfolio per 24 hours (BPS mode)
- **Window**: Rolling 24 hours (86400 seconds)

Limits can be set in two modes via `setSubAccountLimits`:

- **BPS mode** (`maxSpendingBps > 0, maxSpendingUSD = 0`): spending cap = percentage of Safe's USD value. Adjusts automatically as portfolio value changes.
- **USD mode** (`maxSpendingBps = 0, maxSpendingUSD > 0`): spending cap = fixed USD amount (18 decimals). Stays constant regardless of portfolio value.

Exactly one mode must be active — setting both or neither reverts.

## Hybrid On-Chain/Off-Chain Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Sub-Account calls executeOnProtocol(target, data)              │
│       ▼                                                         │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              On-Chain Contract                          │    │
│  │  1. Classify operation from function selector           │    │
│  │  2. Extract tokenIn/amount from calldata via parser     │    │
│  │  3. Check & update spending allowance                   │    │
│  │  4. Execute through Safe (exec → avatar)                │    │
│  │  5. Emit ProtocolExecution event                        │    │
│  └─────────────────────────────────────────────────────────┘    │
│       ▼                                                         │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Off-Chain Oracle                           │    │
│  │  1. Monitor events                                      │    │
│  │  2. Track spending in rolling 24h window                │    │
│  │  3. Match deposits to withdrawals (for acquired status) │    │
│  │  4. Calculate spending allowances                       │    │
│  │  5. Update contract state (spendingAllowance, etc.)     │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Testing

```bash
# Run all tests
forge test

# With gas reporting
forge test --gas-report

# Specific test with verbosity
forge test --match-test testGrantRole -vvv
```

## Emergency Controls

| Control                      | Purpose                                  |
| ---------------------------- | ---------------------------------------- |
| `pause()`                    | Freeze all module operations             |
| `revokeRole()`               | Remove sub-account permissions instantly |
| `unregisterSelector()`       | Block specific operation types           |
| `setAllowedAddresses(false)` | Remove protocol from whitelist           |

## Oracle Integration

The **DeFiInteractorModule** relies on an off-chain oracle (`oracle/`) for autonomous operation. See [`oracle/README.md`](./oracle/README.md) for full documentation.

### 1. Spending Oracle

Monitors events and manages spending allowances for the Acquired Balance Model:

- RPC polling for `ProtocolExecution` and `TransferExecuted` events
- FIFO tracking of acquired balances with timestamp inheritance
- Rolling 24-hour window spending calculations
- Multi-module support via ModuleRegistry discovery
- Cron-based periodic refresh

**Implementation:** `oracle/src/spending-oracle.ts`

### 2. Safe Value Oracle

Tracks and stores the USD value of the associated Safe:

- Runs periodically (configurable cron schedule)
- Fetches token balances from the Safe (ERC20 + native ETH)
- Supports Aave aTokens, Morpho vaults, Uniswap V2 LP
- Gets USD prices from Chainlink price feeds
- Threshold-based updates (>1% change or staleness)
- Stores value on-chain via oracle transaction

**Implementation:** `oracle/src/safe-value.ts`

### Supported Protocols

| Protocol         | Parser                  | Operations                                                    |
| ---------------- | ----------------------- | ------------------------------------------------------------- |
| Aave V3          | `AaveV3Parser`          | Supply, Withdraw, Repay, Claim Rewards                        |
| Morpho Vault     | `MorphoParser`          | Deposit, Mint, Withdraw, Redeem                               |
| Morpho Blue      | `MorphoBlueParser`      | Supply, Withdraw, Repay, SupplyCollateral, WithdrawCollateral |
| Uniswap V3       | `UniswapV3Parser`       | Swaps (exact in/out), LP Mint/Increase/Decrease/Collect       |
| Uniswap V4       | `UniswapV4Parser`       | modifyLiquidities (Mint, Increase, Decrease, Burn)            |
| Universal Router | `UniversalRouterParser` | V2/V3/V4 swaps, WRAP/UNWRAP ETH                               |
| Paraswap         | `ParaswapParser`        | V5/V6 swaps                                                   |
| 1inch            | `OneInchParser`         | swap, unoswapTo, clipperSwapTo                                |
| KyberSwap        | `KyberSwapParser`       | swap, swapSimpleMode, swapGeneric                             |
| Merkl            | `MerklParser`           | Reward claims                                                 |

> **Note**: Fee-on-transfer tokens are not currently supported. Operations involving deflationary tokens will revert.

## Resources

- [Zodiac Wiki](https://www.zodiac.wiki/)
- [Safe Documentation](https://docs.safe.global/)
- [Foundry Book](https://book.getfoundry.sh/)

## License

MIT License - see [LICENSE](./LICENSE)

## Disclaimer

⚠️ **Use at your own risk**

- Smart contracts may contain vulnerabilities
- Not financial advice

---

**Built with Zodiac for secure DeFi self-custody** 🛡️
