# MultiSub

> A secure self-custody DeFi wallet built as a **custom Zodiac module**, combining Safe multisig security with delegated permission-restricted interactions.

[![Solidity](https://img.shields.io/badge/solidity-0.8.20-blue)]()
[![Tests](https://img.shields.io/badge/tests-109%2F109%20passing-brightgreen)]()
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

### Acquired Balance Model
The spending limit mechanism distinguishes between:
- **Original tokens** (in Safe at start of window) → using them **costs spending**
- **Acquired tokens** (received from operations) → **free to use**

This allows sub-accounts to chain operations (swap → deposit → withdraw) without hitting limits on every step.

**Critical Rules:**
1. Only the exact amount received is marked as acquired
2. Acquired status expires after 24 hours (tokens become "original" again)

### Operation Types

| Operation | Costs Spending? | Output Acquired? |
|-----------|-----------------|------------------|
| **Swap** | Yes (original only) | Yes |
| **Deposit** | Yes (original only) | No |
| **Withdraw** | No (FREE) | Conditional* |
| **Claim Rewards** | No (FREE) | Conditional* |
| **Approve** | No (capped) | N/A |
| **Transfer Out** | Always | N/A |

\* Only if deposit matched by the same subaccount to the same protocol in the time window.

### Granular Controls
- **Per-Sub-Account Allowlists**: Each sub-account has its own protocol whitelist
- **Custom Limits**: Configurable spending percentages per sub-account
- **Rolling Windows**: 24-hour rolling windows prevent rapid drain attacks

### Security
- **Selector-Based Classification**: Operations classified by function selector
- **Calldata Verification**: Token/amount extracted from calldata and verified
- **Allowlist Enforcement**: Sub-accounts can only interact with whitelisted protocols
- **Oracle Freshness Check**: Operations blocked if oracle data is stale (>15 minutes)
- **Hard Safety Cap**: Oracle cannot set allowances above absolute maximum
- Emergency pause mechanism
- Instant role revocation

## Default Limits

If not configured, sub-accounts use:
- **Max Spending**: 5% of portfolio per 24 hours
- **Window**: Rolling 24 hours (86400 seconds)

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
│  │              Off-Chain Oracle (Chainlink CRE)           │    │
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

| Control | Purpose |
|---------|---------|
| `pause()` | Freeze all module operations |
| `revokeRole()` | Remove sub-account permissions instantly |
| `unregisterSelector()` | Block specific operation types |
| `setAllowedAddresses(false)` | Remove protocol from whitelist |

## Chainlink Runtime Environment (CRE) Integration

The **DeFiInteractorModule** includes integrated Safe value monitoring powered by Chainlink Runtime Environment.

### Safe Value Monitoring

The module automatically tracks and stores the USD value of its associated Safe:
- Runs every hours (configurable)
- Fetches token balances from the Safe (ERC20 + DeFi positions)
- Supports Aave aTokens, Morpho vaults, Uniswap LP, and 100+ major tokens
- Gets USD prices from Chainlink price feeds
- Calculates total portfolio value in USD
- Stores value on-chain via signed Chainlink reports
- Queryable by any smart contract

**Implementation:**
- `src/DeFiInteractorModule.sol` - Module with integrated value storage
- `chainlink-runtime-environment/safe-value/safe-monitor.ts` - CRE workflow
- `chainlink-runtime-environment/safe-value/config.safe-monitor.json` - Configuration

**Use Cases:**
- On-chain collateralization checks
- Treasury value tracking
- Automated DeFi integrations based on Safe value
- Compliance and reporting

## Resources

- [Zodiac Wiki](https://www.zodiac.wiki/)
- [Safe Documentation](https://docs.safe.global/)
- [Foundry Book](https://book.getfoundry.sh/)
- [Chainlink Documentation](https://docs.chain.link/)

## License

MIT License - see [LICENSE](./LICENSE)

## Disclaimer

⚠️ **Use at your own risk**

- Smart contracts may contain vulnerabilities
- Not financial advice

---

**Built with Zodiac for secure DeFi self-custody** 🛡️
