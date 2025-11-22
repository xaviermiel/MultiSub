# MultiSub

> A secure self-custody DeFi wallet system that leverages Safe (Gnosis) multisig and Zodiac Roles for delegated, permission-restricted interactions with curated DeFi protocols like Morpho Vaults.

[![Tests](https://img.shields.io/badge/tests-1%2F1%20passing-brightgreen)]()
[![Solidity](https://img.shields.io/badge/solidity-0.8.20-blue)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()

## Overview

MultiSub is a self-custody DeFi wallet system that combines the security of Safe multisig with the flexibility of delegated permissions. Sub-accounts can execute DeFi operations within strict limits, while the Safe retains full control and can revoke permissions instantly.

### Key Features

- **Smart Delegation**
- Role-based access control via Zodiac
- Per-sub-account protocol allowlisting (granular control)
- Time-windowed cumulative limits (24h rolling windows)
- Instant permission revocation

- **Multi-Protocol Support**
- Native Morpho Vault integration (ERC4626)
- Generic protocol execution with loss limits
- Chainlink oracle integration for portfolio valuation

## Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- A Safe multisig deployed (create at [app.safe.global](https://app.safe.global/))
- Zodiac Roles module attached to your Safe

### Installation

```bash
# Clone repository
git clone <repository-url>
cd MultiSub

# Install dependencies
forge install

# Build contracts
forge build

# Run tests (98/98 passing)
forge test
```

## Architecture

```
┌──────────────────┐
│  Safe Multisig   │ ← Root owner (3/5 signatures)
└────────┬─────────┘
         │
         ↓
┌──────────────────┐
│  Zodiac Roles    │ ← Access control layer
└────────┬─────────┘
         │
         ↓
┌──────────────────┐
│ DeFiInteractor   │ ← Enforces limits & security
└────────┬─────────┘
         │
         ↓
┌──────────────────┐
│  Sub-Accounts    │ ← Delegated permissions
└────────┬─────────┘
         │
         ↓
┌──────────────────┐
│  Morpho Vaults   │ ← Curated DeFi protocols
└──────────────────┘
```

## Test Coverage

```bash
forge test -vv
```

## Smart Contract Addresses

Contracts will be deployed to Sepolia testnet:

```bash
# Add to .env after deployment
SAFE_ADDRESS=0x...
ZODIAC_ROLES_ADDRESS=0x...
DEFI_INTERACTOR_ADDRESS=0x...
```

## Resources

- [Safe Documentation](https://docs.safe.global/)
- [Zodiac Roles](https://zodiac.wiki/index.php/Category:Roles_Modifier)
- [Morpho Documentation](https://docs.morpho.org/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)

## License

MIT License - see [LICENSE](./LICENSE) for details

## Disclaimer

⚠️ **Use at your own risk**

- Testnet deployment recommended
- External audit required for production
- Smart contracts may contain undiscovered vulnerabilities
- Not financial advice

---

**Built for the DeFi self-custody community**
