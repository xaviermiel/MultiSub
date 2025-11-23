# MultiSub Scripts

This directory contains scripts for interacting with the MultiSub contracts on Zircuit.

## ZeroLend Paymaster Transaction Script

The `zerolend-paymaster-tx.ts` script demonstrates how to:

1. Create an ERC-4337 UserOperation to supply WETH to ZeroLend
2. Use the MultiSubPaymaster to sponsor gas fees
3. Generate EIP-712 signatures for the paymaster
4. Submit the transaction to a bundler
5. Monitor the transaction status

### Prerequisites

Before running the script, ensure:

1. **Contracts are deployed:**
   - Safe multisig
   - SafeERC4337Account (enabled as a Safe module)
   - DeFiInteractorModule (enabled as a Safe module)
   - MultiSubPaymaster (funded with ETH)

2. **Sub-account has proper permissions:**
   - Sub-account has `DEFI_EXECUTE_ROLE` in DeFiInteractorModule
   - ZeroLend Pool (`0x2774C8B95CaB474D0d21943d83b9322Fb1cE9cF5`) is whitelisted for the sub-account

3. **WETH is ready:**
   - Safe has WETH balance (address: `0x4200000000000000000000000000000000000006`)
   - WETH approval will be handled automatically by the script if needed
   - Sub-account needs ETH for gas (for approval transaction if needed)

4. **Environment variables are set:**
   - Copy `.env.example` to `.env` and fill in all values
   - Never commit the `.env` file!

### Installation

```bash
cd scripts
npm install
```

**For detailed setup instructions, see [SETUP.md](SETUP.md)**

### Configuration

Edit `.env` file with your contract addresses and private keys:

```bash
cp .env.example .env
# Edit .env with your values
```

### Usage

```bash
npm run zerolend-tx
```

Or directly:

```bash
ts-node zerolend-paymaster-tx.ts
```

### What the Script Does

1. **Validates configuration** - Checks all required environment variables
2. **Checks WETH balance** - Ensures the Safe has enough WETH
3. **Checks and approves WETH** - Automatically approves WETH for ZeroLend if needed (approves supply amount)
4. **Builds the supply call** - Encodes the ZeroLend `supply()` function call
5. **Wraps in module call** - Encodes the DeFi Module `executeOnProtocol()` call
6. **Gets nonce** - Fetches the current nonce from EntryPoint
7. **Builds UserOperation** - Constructs the complete UserOp structure
8. **Generates paymaster signature** - Signs with EIP-712 using the paymaster signer key
9. **Signs UserOperation** - Signs the UserOp hash with the sub-account key
10. **Submits to bundler** - Sends via `eth_sendUserOperation` JSON-RPC
11. **Monitors receipt** - Polls for the UserOp receipt using `eth_getUserOperationReceipt`
12. **Displays results** - Shows transaction details and updated balances

### Important Notes

#### ERC-4337 Bundler Support on Zircuit

As of the time of writing, Zircuit's ERC-4337 bundler infrastructure may still be in development. The script includes fallback functionality:

- If a dedicated bundler RPC is not available, the script will attempt to use the standard Zircuit RPC
- Zircuit is focusing on EIP-7702 for account abstraction support
- For production use, you may need to use a third-party bundler service like:
  - Pimlico: https://www.pimlico.io/
  - Stackup: https://www.stackup.sh/
  - Alchemy Account Kit: https://www.alchemy.com/account-kit

#### Gas Sponsorship

The MultiSubPaymaster validates:
- Sub-account has proper roles (DEFI_EXECUTE_ROLE or DEFI_TRANSFER_ROLE)
- Gas cost doesn't exceed `maxGasPerOperation`
- Signature from the authorized paymaster signer is valid

The paymaster must have sufficient ETH deposited in the EntryPoint to cover gas costs.

#### Security

- **Never commit private keys** to version control
- The `.env` file contains sensitive information
- Use separate keys for testnet and mainnet
- Consider using a hardware wallet or secure key management system for production

### Troubleshooting

**"Insufficient WETH balance"**
- Ensure the Safe has enough WETH
- WETH address on Zircuit: `0x4200000000000000000000000000000000000006`

**"Error approving WETH" or "Approval failed"**
- The script automatically approves WETH if insufficient allowance is detected
- This error occurs during the automatic approval process
- Ensure:
  - Sub-account has `DEFI_EXECUTE_ROLE` in DeFiInteractorModule
  - ZeroLend Pool (`0x2774C8B95CaB474D0d21943d83b9322Fb1cE9cF5`) is whitelisted for the sub-account
  - Sub-account has ETH for gas to pay for the approval transaction

**"SubAccountNotAuthorized"**
- Grant `DEFI_EXECUTE_ROLE` to the sub-account
- Call `grantRole()` on the DeFiInteractorModule (requires Safe owner)

**"AddressNotAllowed"**
- Whitelist the ZeroLend Pool for the sub-account
- Call `setAllowedAddresses()` on the DeFiInteractorModule (requires Safe owner)

**"Bundler error"**
- Check if Zircuit has ERC-4337 bundler support
- Try using a third-party bundler service
- Verify the bundler RPC URL is correct

**"Invalid signature"**
- Ensure the paymaster signer key matches the signer address set in the paymaster
- Verify the EIP-712 domain and types match the contract

### References

- [ZeroLend Documentation](https://docs.zerolend.xyz/)
- [Aave v3 Pool Documentation](https://docs.aave.com/developers/core-contracts/pool)
- [ERC-4337 Specification](https://eips.ethereum.org/EIPS/eip-4337)
- [Zircuit Documentation](https://docs.zircuit.com/)
- [Account Abstraction Guide](https://www.blocknative.com/blog/account-abstraction-erc-4337-guide)

## ZeroLend Withdrawal Script

The `zerolend-withdraw-tx.ts` script withdraws the **full aToken balance** from ZeroLend back to WETH.

### Usage

```bash
npm run zerolend-withdraw
```

Or directly:

```bash
npx tsx zerolend-withdraw-tx.ts
```

### What the Withdrawal Script Does

1. **Fetches aToken address** - Gets the aWETH token address from ZeroLend
2. **Checks aToken balance** - Verifies the Safe has aTokens to withdraw
3. **Builds withdraw call** - Uses `type(uint256).max` to withdraw ALL available aTokens
4. **Wraps in module call** - Encodes through DeFi Module's `executeOnProtocol()`
5. **Creates UserOperation** - Constructs the complete UserOp structure
6. **Signs with paymaster** - Generates EIP-712 paymaster signature for gas sponsorship
7. **Submits to bundler** - Sends via `eth_sendUserOperation`
8. **Monitors receipt** - Polls for confirmation
9. **Shows updated balances** - Displays aToken and WETH balances after withdrawal

### Important Notes

- The script withdraws **ALL** available aTokens (uses `type(uint256).max`)
- Same prerequisites as the supply script (roles, permissions, paymaster funding)
- The withdrawn WETH goes back to the Safe
- Gas is sponsored by the MultiSubPaymaster

### Next Steps

After successfully running the scripts:

1. **Monitor the Safe** - Check the Safe's aToken and WETH balances on ZeroLend
2. **Verify on explorer** - View the transactions on Zircuit block explorer
3. **Track gas costs** - Monitor how much gas the paymaster has sponsored
4. **Test the full cycle** - Supply WETH, wait for interest, then withdraw
5. **Implement error handling** - Add retry logic and better error messages
6. **Build a UI** - Create a frontend for easier interaction
