# MultiSub Oracle

Off-chain oracle infrastructure for the MultiSub DeFi module. Replaces the previous Chainlink CRE (Computation Runtime Environment) implementation with a self-hosted Node.js service.

## Architecture

The oracle consists of two independent services:

### 1. Spending Oracle (`src/spending-oracle.ts`)

Event-driven monitor that tracks spending and acquired balances for sub-accounts.

- **RPC polling** for `ProtocolExecution` and `TransferExecuted` events
- **Rolling 24h window** tracking for spending calculations
- **Deposit/withdrawal matching** for acquired balance status (FIFO queues)
- **Dual-mode spending limits**: reads per-sub-account limits from `getSubAccountLimits()` — supports both BPS (percentage of Safe value) and fixed USD modes
- **Cron-based periodic refresh** to update allowances as spending expires
- **Multi-module support** via ModuleRegistry discovery

### 2. Safe Value Oracle (`src/safe-value.ts`)

Periodic portfolio valuation service that calculates and stores the total USD value of the Safe.

- **Token balance fetching** (ERC20 + native ETH)
- **Chainlink price feed** integration for USD conversion
- **DeFi position support**: Aave aTokens (1:1), Morpho vaults (share-to-asset conversion), Uniswap V2 LP (reserve-based)
- **Threshold-based updates** — only writes to chain if value changed >1% or data is stale
- **Multi-module support** via ModuleRegistry

## Trust Model

The oracle wallet has constrained on-chain power, bounded by cumulative counters it cannot reset:

| Capability                             | On-chain constraint                                                                               |
| -------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Set `spendingAllowance` per subaccount | `min(absoluteMaxSpendingBps * safeValue, maxSpendingUSD)` — advisory only, real cap is cumulative |
| Set `acquiredBalance` per token        | `_capToSafeBalance` + cumulative oracle acquired budget (`maxOracleAcquiredBps`, default 20%)     |
| Update `safeValue`                     | Snapshotted at window start; mid-window inflation has no effect on spending cap                   |

**If the oracle key is compromised**, maximum damage per window is capped to `absoluteMaxSpendingBps + maxOracleAcquiredBps` (default 20% + 20% = 40%) — enforced by on-chain cumulative counters. Swap acquired balances are marked trustlessly (Tier 1). Version counters prevent stale oracle writes from overwriting on-chain state changes. See [`ORACLE_SECURITY.md`](./ORACLE_SECURITY.md) for full analysis.

**If the oracle goes down**, all subaccount operations freeze within `maxOracleAge` (default 60 minutes) due to staleness checks.

## Setup

### Prerequisites

- Node.js 18+ or Bun
- Access to an RPC endpoint (Alchemy, Infura, or public node)
- A funded wallet for oracle transactions

### Installation

```bash
cd oracle
npm install
```

### Environment Variables

Create a `.env` file in the project root:

```env
# Required
PRIVATE_KEY=0x...           # Oracle wallet private key
MODULE_ADDRESS=0x...        # DeFiInteractorModule contract address

# Optional
CHAIN=sepolia               # Chain: sepolia | base | base-sepolia (default: sepolia)
RPC_URL=https://...         # RPC endpoint (default: public node for selected chain)
REGISTRY_ADDRESS=0x...      # ModuleRegistry for multi-module support
SAFE_VALUE_CRON="0 */10 * * * *"      # Safe value update schedule (default: every 10 min)
SPENDING_ORACLE_CRON="0 */2 * * * *"  # Spending oracle schedule (default: every 2 min)
POLL_INTERVAL_MS=24000      # Event polling interval in ms (default: 2x chain block time)
GAS_LIMIT=500000            # Gas limit for oracle transactions
```

## Running

### Development

```bash
# Run both oracles
npx tsx src/index.ts

# Run only safe value oracle
npx tsx src/safe-value.ts

# Run only spending oracle
npx tsx src/spending-oracle.ts
```

### Production

```bash
npm run build
node dist/index.js
```

### Testing

```bash
npx vitest run
```

## Supported Chains

| Chain        | RPC Default                           | Block Time | ETH/USD Feed   |
| ------------ | ------------------------------------- | ---------- | -------------- |
| Sepolia      | `ethereum-sepolia-rpc.publicnode.com` | 12s        | `0x694A...306` |
| Base         | `mainnet.base.org`                    | 2s         | `0x7104...70`  |
| Base Sepolia | `sepolia.base.org`                    | 2s         | `0x4aDC...01`  |

## Token Configuration

Tokens for Safe value calculation are configured per-chain in `src/config.ts`. Supported token types:

| Type            | Valuation Method                                      |
| --------------- | ----------------------------------------------------- |
| `erc20`         | `balance * chainlinkPrice`                            |
| `aave-atoken`   | Same as erc20 (1:1 with underlying)                   |
| `morpho-vault`  | `convertToAssets(shares) * underlyingPrice`           |
| `uniswap-v2-lp` | `(ownedReserve0 * price0) + (ownedReserve1 * price1)` |

## Monitoring

Recommended alerts:

- **Oracle wallet balance** — needs ETH/gas to submit transactions
- **Staleness** — if `lastOracleUpdate` exceeds `maxOracleAge` (60 min), operations are frozen
- **Safe value age** — if `safeValue.lastUpdated` exceeds `maxSafeValueAge` (60 min), allowance updates fail
- **RPC availability** — oracle depends on a single RPC endpoint
- **Process health** — the Node.js process must stay running; no persistence layer means restart requires event replay

## Failure Modes

| Failure                  | Impact                                                                               | Recovery                                              |
| ------------------------ | ------------------------------------------------------------------------------------ | ----------------------------------------------------- |
| Oracle process crashes   | Operations freeze in 60 min                                                          | Restart process; state rebuilds from events           |
| RPC endpoint down        | Same as process crash                                                                | Switch RPC URL, restart                               |
| Oracle wallet out of gas | Oracle can't update chain                                                            | Fund the wallet                                       |
| Oracle key compromised   | Max damage: `absoluteMaxSpendingBps + maxOracleAcquiredBps` per window (default 40%) | Rotate oracle via `setAuthorizedOracle`, pause module |
