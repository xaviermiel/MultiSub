# Claim-Only SubAccount for DAO Treasury Management

This document describes how to implement a SubAccount that can **only claim rewards** from DeFi protocols, without the ability to deposit, withdraw, swap, or transfer funds.

## Use Case

A DAO treasury wants to delegate reward claiming to a hot wallet (SubAccount) while maintaining full custody of assets. The SubAccount should be able to:
- Claim rewards from AAVE, Morpho, Sky, and other protocols
- Not spend any of the treasury's assets
- Not perform any other DeFi operations

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  DAO Treasury Setup                                          │
│                                                              │
│  Safe Multisig                                               │
│       │                                                      │
│       ├── Deposits to Morpho Vault ──► Earns rewards         │
│       ├── Deposits to AAVE ──────────► Earns rewards         │
│       └── Stakes in Sky ─────────────► Earns rewards         │
│                                              │               │
│                                              ▼               │
│                                    Merkl aggregates all      │
│                                              │               │
│                                              ▼               │
│  SubAccount (claim only)                                     │
│       │                                                      │
│       └── Calls claim() on Merkl ──► All rewards to Safe     │
│           Distributor (single tx)                            │
│                                                              │
│  Restrictions:                                               │
│  ✓ Can only call Merkl Distributor                           │
│  ✓ Can only use CLAIM selector                               │
│  ✓ Zero spending allowance needed                            │
│  ✗ Cannot deposit/withdraw/swap                              │
└──────────────────────────────────────────────────────────────┘
```

## How CLAIM Operations Work

The `DeFiInteractorModule` classifies operations by selector into types:

| Operation Type | Spending Cost | Description |
|----------------|---------------|-------------|
| SWAP | Yes | Costs spending allowance |
| DEPOSIT | Yes | Costs spending allowance |
| WITHDRAW | No | FREE operation |
| CLAIM | No | FREE operation |
| APPROVE | Capped | Limited by spending allowance |

**CLAIM operations are routed via `_executeNoSpendingCheck()`**, meaning a SubAccount can claim rewards without any spending allowance.

---

## Merkl: Universal Reward Distribution

Many DeFi protocols now use **Merkl** (by Angle Labs) for reward distribution. Instead of each protocol having its own reward contract, they all funnel through Merkl's single Distributor.

```
┌───────────────────────────────────────────────────────────────────────┐
│                    Merkl System                                       │
│                                                                       │
│  Morpho ──────┐                                                       │
│  AAVE ────────┼──► Merkl Engine ──► Merkle Root ──► Distributor       │
│  Sky ─────────┘    (off-chain)      (on-chain)     (single contract)  │
│  Other ───────┘                                                       │
│                                                                       │
│                         │                                             │
│                         ▼                                             │
│                    User Claims                                        │
│              (with Merkle proofs)                                     │
└───────────────────────────────────────────────────────────────────────┘
```

### Merkl Distributor Contract

| Network | Address |
|---------|---------|
| Ethereum Mainnet | `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` |

### Claim Function Signature

```solidity
function claim(
    address[] calldata users,      // Array of user addresses claiming
    address[] calldata tokens,     // Array of reward tokens
    uint256[] calldata amounts,    // Cumulative claimable amounts
    bytes32[][] calldata proofs    // Merkle proofs for each claim
) external
```

**Selector:** `0x71ee95c0`

**Key points:**
- All arrays must have the **same length**
- `amounts` are **cumulative** (total earned, not delta)
- Contract tracks what's already been claimed
- Can batch multiple users/tokens in one call

---

## Protocol-Specific Support

### AAVE V3

AAVE has its own RewardsController for direct claiming (in addition to Merkl):

| Function | Selector | Type |
|----------|----------|------|
| `claimRewards(address[],uint256,address,address)` | `0x236300dc` | CLAIM |
| `claimRewardsOnBehalf(address[],uint256,address,address,address)` | `0x33028b99` | CLAIM |
| `claimAllRewards(address[],address)` | `0xbb492bf5` | CLAIM |
| `claimAllRewardsOnBehalf(address[],address,address)` | `0x9ff55db9` | CLAIM |

**Parser:** `AaveV3Parser.sol` (already implemented)

### Morpho

Morpho uses two systems:
1. **Merkl** (current) - for new reward programs
2. **Universal Rewards Distributor (URD)** (legacy) - for historical rewards

| Contract | Address | Function |
|----------|---------|----------|
| Merkl Distributor | `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` | `claim()` |
| Morpho URD | `0x678dDC1d07eaa166521325394cDEb1E4c086DF43` | `claim(address,address,uint256,bytes32[])` |

### Sky (formerly MakerDAO)

Sky uses staking/farming contracts for the Sky Token Rewards (STR) module:

| Contract | Description |
|----------|-------------|
| REWARDS_LSSKY_USDS | `0x38E4254bD82ED5Ee97CD1C4278FAae748d998865` |

---

## Implementation

### 1. MerklParser Contract

The MerklParser is already implemented at `src/parsers/MerklParser.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title MerklParser
 * @notice Calldata parser for Merkl Distributor reward claims
 * @dev Extracts token information from Merkl claim function calldata
 *      Merkl Distributor address: 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae (most chains)
 */
contract MerklParser is ICalldataParser {
    error UnsupportedSelector();

    // Merkl Distributor function selector
    // claim(address[] users, address[] tokens, uint256[] amounts, bytes32[][] proofs)
    bytes4 public constant CLAIM_SELECTOR = 0x71ee95c0;

    /// @inheritdoc ICalldataParser
    function extractInputToken(address, bytes calldata data) external pure override returns (address) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == CLAIM_SELECTOR) {
            // CLAIM operations don't have input tokens (no spending)
            return address(0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmount(address, bytes calldata data) external pure override returns (uint256) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == CLAIM_SELECTOR) {
            // CLAIM operations don't have input amounts (no spending)
            return 0;
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractOutputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == CLAIM_SELECTOR) {
            // claim(address[] users, address[] tokens, uint256[] amounts, bytes32[][] proofs)
            // Extract first token from tokens array as the output token
            (, address[] memory tokens,,) = abi.decode(data[4:], (address[], address[], uint256[], bytes32[][]));
            if (tokens.length > 0) {
                return tokens[0];
            }
            return address(0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == CLAIM_SELECTOR;
    }

    /**
     * @notice Get the operation type for the given calldata
     * @param data The calldata to analyze
     * @return opType 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     */
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == CLAIM_SELECTOR) {
            return 4; // CLAIM
        }
        return 0; // UNKNOWN
    }
}
```

### 2. Configuration

Use the existing scripts in `/script` to configure a claim-only SubAccount:

**Step 1: Run ConfigureParsersAndSelectors.s.sol** (if not already done)

This deploys all parsers (including MerklParser) and registers all selectors.

```bash
SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... \
forge script script/ConfigureParsersAndSelectors.s.sol \
  --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
```

**Step 2: Configure the Claim-Only SubAccount**

Use `ConfigureSubaccount.s.sol` with restricted settings:

```bash
# Grant only execute role, no transfer role
# Set 0% spending limit (claims are free anyway)
SAFE_ADDRESS=0x... \
DEFI_MODULE_ADDRESS=0x... \
SUB_ACCOUNT_ADDRESS=0x... \
MAX_SPENDING_BPS=0 \
WINDOW_DURATION=3600 \
GRANT_TRANSFER_ROLE=false \
forge script script/ConfigureSubaccount.s.sol \
  --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
```

**Step 3: Restrict Whitelist to Claim Contracts Only**

Use `WhitelistAddresses.s.sol` to set up a minimal whitelist:

```bash
# First remove all default protocols (if ConfigureSubaccount added them)
SAFE_ADDRESS=0x... \
DEFI_MODULE_ADDRESS=0x... \
SUB_ACCOUNT_ADDRESS=0x... \
ADDRESSES=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951,0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E,0x1238536071E1c677A632429e3655c799b22cDA52,0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4,0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD \
ALLOW=false \
forge script script/WhitelistAddresses.s.sol \
  --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY

# Keep only Merkl Distributor and AAVE Rewards Controller
SAFE_ADDRESS=0x... \
DEFI_MODULE_ADDRESS=0x... \
SUB_ACCOUNT_ADDRESS=0x... \
ADDRESSES=0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae,0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb \
ALLOW=true \
forge script script/WhitelistAddresses.s.sol \
  --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
```

**Key selectors registered for claims:**

| Function | Selector | Type |
|----------|----------|------|
| Merkl `claim` | `0x71ee95c0` | CLAIM |
| AAVE `claimRewards` | `0x236300dc` | CLAIM |
| AAVE `claimRewardsOnBehalf` | `0x33028b99` | CLAIM |
| AAVE `claimAllRewards` | `0xbb492bf5` | CLAIM |
| AAVE `claimAllRewardsOnBehalf` | `0x9ff55db9` | CLAIM |

### 3. Oracle Configuration

The oracle should set spending allowance to 0 for claim-only SubAccounts:

```solidity
// Claims don't consume spending, but oracle still needs to update timestamp
oracle.updateSpendingAllowance(claimOnlySubAccount, 0);
```

---

## Security Considerations

### What the Claim-Only SubAccount CAN Do

| Action | Allowed | Reason |
|--------|---------|--------|
| Claim rewards via Merkl | ✅ | Allowlisted + CLAIM selector |
| Claim rewards via AAVE RewardsController | ✅ | Allowlisted + CLAIM selector |
| Batch claim multiple rewards | ✅ | Single Merkl tx |

### What the Claim-Only SubAccount CANNOT Do

| Action | Blocked | Reason |
|--------|---------|--------|
| Deposit to protocols | ❌ | Protocol addresses not in allowlist |
| Withdraw from protocols | ❌ | Protocol addresses not in allowlist |
| Swap tokens | ❌ | DEX addresses not in allowlist |
| Transfer tokens | ❌ | No DEFI_TRANSFER_ROLE granted |
| Approve tokens | ❌ | APPROVE requires allowlisted spender |

### Multiple Layers of Protection

1. **Role Check**: SubAccount must have `DEFI_EXECUTE_ROLE`
2. **Allowlist Check**: Target must be in SubAccount's allowlist
3. **Selector Check**: Function selector must be registered (as CLAIM)
4. **Parser Required**: Parser must be registered for the target

---

## FAQ

### If the multisig deposits in a new Morpho vault, can the SubAccount still claim?

**Yes.** With Merkl:
1. Morpho uses Merkl for reward distribution
2. Merkl computes rewards off-chain based on on-chain positions
3. All rewards (from any vault) are claimable via the **same Merkl Distributor**
4. SubAccount calls `claim()` with the proof from Merkl API
5. No configuration change needed when adding new vaults

### What about protocols not using Merkl?

For protocols with their own reward contracts:
1. Create a parser for the protocol's claim function
2. Register the claim selector as `OperationType.CLAIM`
3. Add the reward contract to the SubAccount's allowlist

### Can rewards be claimed to a different address?

With `claimWithRecipient`, rewards can be sent to specified recipients. However, this requires the Safe to be the claimant and proper operator permissions.

### What if a protocol changes its reward contract?

The Safe owner (multisig) would need to:
1. Deploy/use a new parser if the function signature changed
2. Register any new selectors
3. Update the SubAccount's allowlist with the new contract address

---

## References

- [Merkl Technical Overview](https://docs.merkl.xyz/merkl-mechanisms/technical-overview)
- [Merkl Contracts GitHub](https://github.com/AngleProtocol/merkl-contracts)
- [Morpho Claim Rewards via Merkl](https://docs.morpho.org/build/rewards/tutorials/claim-rewards)
- [Morpho Universal Rewards Distributors](https://docs.morpho.org/rewards/contracts/urd/)
- [AAVE V3 RewardsController](https://docs.aave.com/developers/periphery-contracts/rewardscontroller)
