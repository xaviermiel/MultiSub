# MultiSub

> A secure self-custody DeFi wallet built as a **custom Zodiac module**, combining Safe multisig security with delegated permission-restricted interactions.

[![Solidity](https://img.shields.io/badge/solidity-0.8.20-blue)]()
[![Tests](https://img.shields.io/badge/tests-44%2F44%20passing-brightgreen)]()
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

# 2. Deploy
forge script script/DeployDeFiModule.s.sol --broadcast

# 3. Configure
forge script script/SetupDeFiModule.s.sol --broadcast
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
│  • approveProtocol()               │
│  • executeOnProtocol()             │
│  • transferToken()                 │
└────────────────────────────────────┘
```

## Key Features

### Streamlined Roles
- **DEFI_EXECUTE_ROLE (1)**: Approve tokens & execute protocol operations
- **DEFI_TRANSFER_ROLE (2)**: Transfer tokens from Safe

### Granular Controls
- **Per-Sub-Account Allowlists**: Each sub-account has its own protocol whitelist
- **Custom Limits**: Configurable deposit/withdraw/loss percentages per sub-account
- **Time Windows**: Rolling 24-hour windows prevent rapid drain attacks

### Security
- Separate approval workflow (prevents approval draining)
- Time-windowed cumulative limits (prevents rapid drain attacks)
- Emergency pause mechanism
- Instant role revocation
- Unusual activity detection

## Usage

### Owner (Safe) Operations

```bash
# Grant roles
cast send $MODULE "grantRole(address,uint16)" $SUB_ACCOUNT 1

# Set limits (15% deposit, 10% withdraw, 8% max loss, 48h window)
cast send $MODULE "setSubAccountLimits(address,uint256,uint256,uint256,uint256)" \
  $SUB_ACCOUNT 1500 1000 800 172800

# Configure allowed protocols
cast send $MODULE "setAllowedAddresses(address,address[],bool)" \
  $SUB_ACCOUNT "[$MORPHO_VAULT,$AAVE_POOL]" true
```

### Sub-Account Operations

```bash
# Approve token
cast send $MODULE "approveProtocol(address,address,uint256)" \
  $USDC $MORPHO_VAULT 1000000000

# Execute protocol operation
DATA=$(cast calldata "deposit(uint256,address)" 500000000 $SAFE)
cast send $MODULE "executeOnProtocol(address,bytes)" $MORPHO_VAULT $DATA

# Transfer tokens
cast send $MODULE "transferToken(address,address,uint256)" \
  $USDC $RECIPIENT 100000000
```

## Default Limits

If not configured, sub-accounts use:
- **Max transfer**: 1% per 24 hours
- **Max Loss**: 5% per 24 hours
- **Window**: 24 hours (86400 seconds)

## File Structure

```
src/
├── base/Module.sol               # Base Zodiac module
├── DeFiInteractorModule.sol      # Main module (18.5 KB)
└── interfaces/                   # Interface files

script/
├── DeployDeFiModule.s.sol       # Deploy
└── SetupDeFiModule.s.sol        # Configure

test/
└── DeFiInteractorModule.t.sol
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

## Use Cases

- **Individual Users**: Mobile DeFi with cold storage security
- **Family Wallets**: Each member with custom limits
- **DAOs**: Delegate treasury management with controls
- **Institutions**: Operational DeFi with compliance

## Security

**Built-in Protection**:
- Role-based access control
- Time-windowed cumulative limits
- Separate approval workflow
- Emergency pause mechanism
- Reentrancy guards

## Chainlink Runtime Environment (CRE) Integration

The **DeFiInteractorModule** includes integrated Safe value monitoring powered by Chainlink Runtime Environment.

### Safe Value Monitoring

The module automatically tracks and stores the USD value of its associated Safe:
- Runs every 30 seconds (configurable)
- Fetches token balances from the Safe (ERC20 + DeFi positions)
- Supports Aave aTokens, Morpho vaults, Uniswap LP, and 100+ major tokens
- Gets USD prices from Chainlink price feeds
- Calculates total portfolio value in USD
- Stores value on-chain via signed Chainlink reports
- Queryable by any smart contract

**Key Features:**
- Single contract deployment (module + value storage)
- Module knows its Safe via `avatar()` property
- Authorized Chainlink updater only
- Staleness checks included
- Event logging for all updates

**Implementation:**
- `src/DeFiInteractorModule.sol` - Module with integrated value storage
- `chainlink-runtime-environment/safe-value/safe-monitor.ts` - CRE workflow
- `chainlink-runtime-environment/safe-value/config.safe-monitor.json` - Configuration

**Use Cases:**
- On-chain collateralization checks
- Treasury value tracking
- Automated DeFi integrations based on Safe value
- Compliance and reporting

**Quick Deploy:**
```bash
# Deploy module with Chainlink updater
export SAFE_ADDRESS=0xYourSafe
export AUTHORIZED_UPDATER=0xChainlinkCREProxy
forge script script/DeployDeFiModule.s.sol --broadcast

# Query Safe value
cast call MODULE_ADDRESS "getSafeValue()(uint256,uint256,uint256)"

# Query multiple token balances (batch query)
cast call MODULE_ADDRESS "getTokenBalances(address[])(uint256[])" \
  "[0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14]"
```

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
