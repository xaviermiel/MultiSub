#!/usr/bin/env tsx

/**
 * ZeroLend Transaction Script with MultiSubPaymaster
 *
 * This script creates and executes a UserOperation to supply WETH to ZeroLend
 * on Zircuit, with gas sponsored by the MultiSubPaymaster.
 *
 * Features:
 * - Constructs ERC-4337 UserOperation
 * - Generates EIP-712 paymaster signature
 * - Submits to bundler for execution
 * - Monitors transaction status
 *
 * Prerequisites:
 * - Sub-account has DEFI_EXECUTE_ROLE in DeFiInteractorModule
 * - Paymaster is funded with ETH
 * - ZeroLend Pool is whitelisted for sub-account
 * - Sub-account has ETH for gas (for WETH approval if needed)
 * - Safe has WETH balance
 *
 * Note: WETH approval is handled automatically by the script!
 */

import 'dotenv/config'
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  encodeFunctionData,
  encodeAbiParameters,
  parseAbiParameters,
  keccak256,
  concat,
  pad,
  toHex,
  hexToBigInt,
  type Address,
  type Hex
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { zircuit } from 'viem/chains'

// ============ Configuration ============

const ZIRCUIT_RPC_URL = process.env.ZIRCUIT_RPC_URL || 'https://zircuit1-mainnet.p2pify.com/'
// EntryPoint v0.6 (v0.8 not yet deployed on Zircuit)
const ENTRYPOINT_V06 = '0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789'
const BUNDLER_RPC_URL = process.env.BUNDLER_RPC_URL || ZIRCUIT_RPC_URL // Fallback to regular RPC

// Contract addresses - replace with your deployed contracts
const SAFE_ADDRESS = process.env.SAFE_ADDRESS as Address
const SAFE_ERC4337_ACCOUNT = process.env.SAFE_ERC4337_ACCOUNT as Address
const PAYMASTER_ADDRESS = process.env.PAYMASTER_ADDRESS as Address
const DEFI_MODULE_ADDRESS = process.env.DEFI_MODULE_ADDRESS as Address

// ZeroLend on Zircuit
const ZEROLEND_POOL = '0x2774C8B95CaB474D0d21943d83b9322Fb1cE9cF5' as Address
const WETH_ADDRESS = '0x4200000000000000000000000000000000000006' as Address

// Private keys
const SUB_ACCOUNT_KEY = process.env.SUB_ACCOUNT_PRIVATE_KEY as Hex
const PAYMASTER_SIGNER_KEY = process.env.PAYMASTER_SIGNER_PRIVATE_KEY as Hex

// Transaction parameters
const SUPPLY_AMOUNT = parseEther('0.001') // 0.005 WETH

// ============ ABIs ============

const ZEROLEND_POOL_ABI = [
  {
    inputs: [
      { name: 'asset', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'onBehalfOf', type: 'address' },
      { name: 'referralCode', type: 'uint16' }
    ],
    name: 'supply',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function'
  }
] as const

const DEFI_MODULE_ABI = [
  {
    inputs: [
      { name: 'target', type: 'address' },
      { name: 'data', type: 'bytes' }
    ],
    name: 'executeOnProtocol',
    outputs: [{ name: 'result', type: 'bytes' }],
    stateMutability: 'nonpayable',
    type: 'function'
  },
  {
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'target', type: 'address' },
      { name: 'amount', type: 'uint256' }
    ],
    name: 'approveProtocol',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function'
  }
] as const

const ERC20_ABI = [
  {
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' }
    ],
    name: 'approve',
    outputs: [{ name: '', type: 'bool' }],
    stateMutability: 'nonpayable',
    type: 'function'
  },
  {
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' }
    ],
    name: 'allowance',
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ name: 'account', type: 'address' }],
    name: 'balanceOf',
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function'
  }
] as const

// ============ Types ============

interface PackedUserOperation {
  sender: Address
  nonce: bigint
  initCode: Hex
  callData: Hex
  accountGasLimits: Hex // Pack of verificationGasLimit and callGasLimit
  preVerificationGas: bigint
  gasFees: Hex // Pack of maxPriorityFeePerGas and maxFeePerGas
  paymasterAndData: Hex
  signature: Hex
}

// ============ Helper Functions ============

/**
 * Pack gas limits into accountGasLimits
 */
function packAccountGasLimits(verificationGasLimit: bigint, callGasLimit: bigint): Hex {
  const verificationGas = pad(toHex(verificationGasLimit), { size: 16 })
  const callGas = pad(toHex(callGasLimit), { size: 16 })
  return concat([verificationGas, callGas])
}

/**
 * Pack fee per gas into gasFees
 */
function packGasFees(maxPriorityFeePerGas: bigint, maxFeePerGas: bigint): Hex {
  const priorityFee = pad(toHex(maxPriorityFeePerGas), { size: 16 })
  const maxFee = pad(toHex(maxFeePerGas), { size: 16 })
  return concat([priorityFee, maxFee])
}

/**
 * Get user operation hash for EntryPoint v0.8
 */
function getUserOpHash(
  userOp: PackedUserOperation,
  entryPoint: Address,
  chainId: number
): Hex {
  const packedData = encodeAbiParameters(
    parseAbiParameters('address, uint256, bytes32, bytes32, bytes32, uint256, bytes32, bytes32'),
    [
      userOp.sender,
      userOp.nonce,
      keccak256(userOp.initCode),
      keccak256(userOp.callData),
      userOp.accountGasLimits,
      userOp.preVerificationGas,
      userOp.gasFees,
      keccak256(userOp.paymasterAndData)
    ]
  )

  const userOpHash = keccak256(packedData)

  const entryPointData = encodeAbiParameters(
    parseAbiParameters('bytes32, address, uint256'),
    [userOpHash, entryPoint, BigInt(chainId)]
  )

  return keccak256(entryPointData)
}

/**
 * Generate EIP-712 signature for paymaster
 */
async function generatePaymasterSignature(
  userOp: PackedUserOperation,
  validAfter: number,
  validUntil: number,
  paymasterSignerKey: Hex
): Promise<{ signature: Hex; validAfter: number; validUntil: number }> {
  const account = privateKeyToAccount(paymasterSignerKey)

  // Extract paymaster verification and post-op gas limits from paymasterAndData
  const paymasterAndData = userOp.paymasterAndData
  const paymasterVerificationGasLimit = hexToBigInt(('0x' + paymasterAndData.slice(42, 74)) as Hex)
  const paymasterPostOpGasLimit = hexToBigInt(('0x' + paymasterAndData.slice(74, 106)) as Hex)

  // EIP-712 domain
  const domain = {
    name: 'MultiSubPaymaster',
    version: '1',
    chainId: zircuit.id,
    verifyingContract: PAYMASTER_ADDRESS
  } as const

  // EIP-712 types
  const types = {
    UserOperationRequest: [
      { name: 'sender', type: 'address' },
      { name: 'nonce', type: 'uint256' },
      { name: 'initCode', type: 'bytes' },
      { name: 'callData', type: 'bytes' },
      { name: 'accountGasLimits', type: 'bytes32' },
      { name: 'preVerificationGas', type: 'uint256' },
      { name: 'gasFees', type: 'bytes32' },
      { name: 'paymasterVerificationGasLimit', type: 'uint256' },
      { name: 'paymasterPostOpGasLimit', type: 'uint256' },
      { name: 'validAfter', type: 'uint48' },
      { name: 'validUntil', type: 'uint48' }
    ]
  } as const

  // Message to sign
  const message = {
    sender: userOp.sender,
    nonce: userOp.nonce,
    initCode: userOp.initCode,
    callData: userOp.callData,
    accountGasLimits: userOp.accountGasLimits,
    preVerificationGas: userOp.preVerificationGas,
    gasFees: userOp.gasFees,
    paymasterVerificationGasLimit,
    paymasterPostOpGasLimit,
    validAfter: validAfter,
    validUntil: validUntil
  } as const

  // Sign the message
  const signature = await account.signTypedData({
    domain,
    types,
    primaryType: 'UserOperationRequest',
    message
  })

  return { signature, validAfter, validUntil }
}

/**
 * Build paymaster and data field
 */
function buildPaymasterAndData(
  paymasterAddress: Address,
  paymasterVerificationGasLimit: bigint,
  paymasterPostOpGasLimit: bigint,
  validAfter: number,
  validUntil: number,
  signature: Hex
): Hex {
  const verificationGas = pad(toHex(paymasterVerificationGasLimit), { size: 16 })
  const postOpGas = pad(toHex(paymasterPostOpGasLimit), { size: 16 })
  const validAfterBytes = pad(toHex(validAfter), { size: 6 })
  const validUntilBytes = pad(toHex(validUntil), { size: 6 })

  return concat([
    paymasterAddress,
    verificationGas,
    postOpGas,
    validAfterBytes,
    validUntilBytes,
    signature
  ])
}

// ============ Main Script ============

async function main() {
  console.log('=== ZeroLend Paymaster Transaction Script ===\n')

  // Validate environment variables
  if (!SAFE_ADDRESS || !SAFE_ERC4337_ACCOUNT || !PAYMASTER_ADDRESS ||
      !DEFI_MODULE_ADDRESS || !SUB_ACCOUNT_KEY || !PAYMASTER_SIGNER_KEY) {
    console.error('Error: Missing required environment variables')
    console.error('Required: SAFE_ADDRESS, SAFE_ERC4337_ACCOUNT, PAYMASTER_ADDRESS,')
    console.error('          DEFI_MODULE_ADDRESS, SUB_ACCOUNT_PRIVATE_KEY, PAYMASTER_SIGNER_PRIVATE_KEY')
    process.exit(1)
  }

  // Create clients
  const publicClient = createPublicClient({
    chain: zircuit,
    transport: http(ZIRCUIT_RPC_URL)
  })

  const subAccount = privateKeyToAccount(SUB_ACCOUNT_KEY)

  console.log('Configuration:')
  console.log(`  Safe: ${SAFE_ADDRESS}`)
  console.log(`  Safe ERC4337 Account: ${SAFE_ERC4337_ACCOUNT}`)
  console.log(`  Sub-account: ${subAccount.address}`)
  console.log(`  Paymaster: ${PAYMASTER_ADDRESS}`)
  console.log(`  DeFi Module: ${DEFI_MODULE_ADDRESS}`)
  console.log(`  ZeroLend Pool: ${ZEROLEND_POOL}`)
  console.log(`  Supply Amount: ${SUPPLY_AMOUNT} wei (${Number(SUPPLY_AMOUNT) / 1e18} WETH)\n`)

  // Step 1: Check WETH balance
  console.log('Step 1: Checking WETH balance...')
  const wethBalance = await publicClient.readContract({
    address: WETH_ADDRESS,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: [SAFE_ADDRESS]
  })
  console.log(`  Safe WETH balance: ${wethBalance} wei (${Number(wethBalance) / 1e18} WETH)`)

  if (wethBalance < SUPPLY_AMOUNT) {
    console.error(`  Error: Insufficient WETH balance. Need ${SUPPLY_AMOUNT}, have ${wethBalance}`)
    process.exit(1)
  }

  // Step 2: Check and approve WETH allowance for ZeroLend Pool
  console.log('\nStep 2: Checking WETH allowance...')
  const allowance = await publicClient.readContract({
    address: WETH_ADDRESS,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: [SAFE_ADDRESS, ZEROLEND_POOL]
  })
  console.log(`  Current allowance: ${allowance} wei (${Number(allowance) / 1e18} WETH)`)

  if (allowance < SUPPLY_AMOUNT) {
    console.log(`  Insufficient allowance! Approving WETH for ZeroLend Pool...`)

    const approvalAmount = SUPPLY_AMOUNT
    console.log(`  Approval amount: ${approvalAmount} wei (${Number(approvalAmount) / 1e18} WETH)`)

    // Create wallet client for sending transaction
    const walletClient = createWalletClient({
      account: subAccount,
      chain: zircuit,
      transport: http(ZIRCUIT_RPC_URL)
    })

    try {
      // Call approveProtocol on DeFiInteractorModule
      const hash = await walletClient.writeContract({
        address: DEFI_MODULE_ADDRESS,
        abi: DEFI_MODULE_ABI,
        functionName: 'approveProtocol',
        args: [WETH_ADDRESS, ZEROLEND_POOL, approvalAmount]
      })

      console.log(`  Approval transaction sent: ${hash}`)
      console.log(`  Waiting for confirmation...`)

      // Wait for transaction receipt
      const receipt = await publicClient.waitForTransactionReceipt({ hash })

      if (receipt.status === 'success') {
        console.log(`  ✓ Approval successful! (Block: ${receipt.blockNumber})`)
      } else {
        console.error(`  ✗ Approval failed!`)
        process.exit(1)
      }

      // Verify new allowance
      const newAllowance = await publicClient.readContract({
        address: WETH_ADDRESS,
        abi: ERC20_ABI,
        functionName: 'allowance',
        args: [SAFE_ADDRESS, ZEROLEND_POOL]
      })
      console.log(`  New allowance: ${newAllowance} wei (${Number(newAllowance) / 1e18} WETH)`)

    } catch (error) {
      console.error(`  Error approving WETH:`, error)
      console.error(`  Please ensure:`)
      console.error(`    - Sub-account has DEFI_EXECUTE_ROLE`)
      console.error(`    - ZeroLend Pool is whitelisted for sub-account`)
      console.error(`    - Sub-account has ETH for gas`)
      process.exit(1)
    }
  } else {
    console.log(`  ✓ Sufficient allowance already exists`)
  }

  // Step 3: Build the ZeroLend supply call
  console.log('\nStep 3: Building ZeroLend supply call...')
  const supplyCallData = encodeFunctionData({
    abi: ZEROLEND_POOL_ABI,
    functionName: 'supply',
    args: [
      WETH_ADDRESS,
      SUPPLY_AMOUNT,
      SAFE_ADDRESS, // onBehalfOf (the Safe receives the aTokens)
      0 // referralCode
    ]
  })
  console.log(`  Supply call data: ${supplyCallData.slice(0, 66)}...`)

  // Step 4: Build the DeFi Module executeOnProtocol call
  console.log('\nStep 4: Building DeFi Module call...')
  const moduleCallData = encodeFunctionData({
    abi: DEFI_MODULE_ABI,
    functionName: 'executeOnProtocol',
    args: [ZEROLEND_POOL, supplyCallData]
  })
  console.log(`  Module call data: ${moduleCallData.slice(0, 66)}...`)

  // Step 5: Get nonce from EntryPoint
  console.log('\nStep 5: Getting nonce from EntryPoint...')
  const nonce = await publicClient.readContract({
    address: ENTRYPOINT_V06 as Address,
    abi: [{
      inputs: [
        { name: 'sender', type: 'address' },
        { name: 'key', type: 'uint192' }
      ],
      name: 'getNonce',
      outputs: [{ name: 'nonce', type: 'uint256' }],
      stateMutability: 'view',
      type: 'function'
    }],
    functionName: 'getNonce',
    args: [SAFE_ERC4337_ACCOUNT, BigInt(0)]
  })
  console.log(`  Nonce: ${nonce}`)

  // Step 6: Get gas estimates
  console.log('\nStep 6: Estimating gas...')
  const block = await publicClient.getBlock()
  const maxPriorityFeePerGas = BigInt(1000000000) // 1 gwei
  const maxFeePerGas = block.baseFeePerGas ? block.baseFeePerGas * BigInt(2) + maxPriorityFeePerGas : BigInt(50000000000)

  const verificationGasLimit = BigInt(200000)
  const callGasLimit = BigInt(300000)
  const preVerificationGas = BigInt(100000)
  const paymasterVerificationGasLimit = BigInt(150000)
  const paymasterPostOpGasLimit = BigInt(50000)

  console.log(`  Verification gas limit: ${verificationGasLimit}`)
  console.log(`  Call gas limit: ${callGasLimit}`)
  console.log(`  Pre-verification gas: ${preVerificationGas}`)
  console.log(`  Max fee per gas: ${maxFeePerGas}`)
  console.log(`  Max priority fee per gas: ${maxPriorityFeePerGas}`)

  // Step 7: Build initial UserOperation (without paymaster signature)
  console.log('\nStep 7: Building UserOperation...')

  const validAfter = Math.floor(Date.now() / 1000) - 60 // 1 minute ago
  const validUntil = Math.floor(Date.now() / 1000) + 3600 // 1 hour from now

  // Build initial paymasterAndData (without signature)
  const initialPaymasterAndData = buildPaymasterAndData(
    PAYMASTER_ADDRESS,
    paymasterVerificationGasLimit,
    paymasterPostOpGasLimit,
    validAfter,
    validUntil,
    '0x' // Empty signature for now
  )

  let userOp: PackedUserOperation = {
    sender: SAFE_ERC4337_ACCOUNT,
    nonce,
    initCode: '0x',
    callData: moduleCallData,
    accountGasLimits: packAccountGasLimits(verificationGasLimit, callGasLimit),
    preVerificationGas,
    gasFees: packGasFees(maxPriorityFeePerGas, maxFeePerGas),
    paymasterAndData: initialPaymasterAndData,
    signature: '0x'
  }

  // Step 8: Generate paymaster signature
  console.log('\nStep 8: Generating paymaster signature...')
  const { signature: paymasterSignature } = await generatePaymasterSignature(
    userOp,
    validAfter,
    validUntil,
    PAYMASTER_SIGNER_KEY
  )
  console.log(`  Paymaster signature: ${paymasterSignature.slice(0, 66)}...`)

  // Update paymasterAndData with actual signature
  userOp.paymasterAndData = buildPaymasterAndData(
    PAYMASTER_ADDRESS,
    paymasterVerificationGasLimit,
    paymasterPostOpGasLimit,
    validAfter,
    validUntil,
    paymasterSignature
  )

  // Step 9: Sign UserOperation
  console.log('\nStep 9: Signing UserOperation...')
  const userOpHash = getUserOpHash(userOp, ENTRYPOINT_V06 as Address, zircuit.id)
  console.log(`  UserOp hash: ${userOpHash}`)

  const userOpSignature = await subAccount.signMessage({
    message: { raw: userOpHash }
  })
  userOp.signature = userOpSignature
  console.log(`  User signature: ${userOpSignature.slice(0, 66)}...`)

  // Step 10: Submit UserOperation to bundler
  console.log('\nStep 10: Submitting UserOperation to bundler...')
  console.log(`  Bundler RPC: ${BUNDLER_RPC_URL}`)

  try {
    // Send via eth_sendUserOperation JSON-RPC call
    const response = await fetch(BUNDLER_RPC_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_sendUserOperation',
        params: [
          {
            sender: userOp.sender,
            nonce: `0x${userOp.nonce.toString(16)}`,
            initCode: userOp.initCode,
            callData: userOp.callData,
            accountGasLimits: userOp.accountGasLimits,
            preVerificationGas: `0x${userOp.preVerificationGas.toString(16)}`,
            gasFees: userOp.gasFees,
            paymasterAndData: userOp.paymasterAndData,
            signature: userOp.signature
          },
          ENTRYPOINT_V06
        ]
      })
    })

    const result = await response.json()

    if (result.error) {
      console.error('  Error from bundler:', result.error)
      throw new Error(result.error.message)
    }

    const userOpHashFromBundler = result.result
    console.log(`  UserOperation submitted successfully!`)
    console.log(`  UserOp hash from bundler: ${userOpHashFromBundler}`)

    // Step 11: Wait for UserOperation receipt
    console.log('\nStep 11: Waiting for UserOperation receipt...')

    let receipt = null
    let attempts = 0
    const maxAttempts = 30

    while (!receipt && attempts < maxAttempts) {
      attempts++
      await new Promise(resolve => setTimeout(resolve, 2000)) // Wait 2 seconds

      const receiptResponse = await fetch(BUNDLER_RPC_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'eth_getUserOperationReceipt',
          params: [userOpHashFromBundler]
        })
      })

      const receiptResult = await receiptResponse.json()

      if (receiptResult.result) {
        receipt = receiptResult.result
        break
      }

      console.log(`  Attempt ${attempts}/${maxAttempts}: Waiting...`)
    }

    if (receipt) {
      console.log('\n=== Transaction Successful! ===')
      console.log(`  Transaction hash: ${receipt.receipt.transactionHash}`)
      console.log(`  Block number: ${receipt.receipt.blockNumber}`)
      console.log(`  Gas used: ${receipt.actualGasUsed}`)
      console.log(`  Success: ${receipt.success}`)

      // Check new WETH balance
      const newWethBalance = await publicClient.readContract({
        address: WETH_ADDRESS,
        abi: ERC20_ABI,
        functionName: 'balanceOf',
        args: [SAFE_ADDRESS]
      })
      console.log(`\n  New Safe WETH balance: ${newWethBalance} wei (${Number(newWethBalance) / 1e18} WETH)`)
      console.log(`  Difference: ${wethBalance - newWethBalance} wei (${Number(wethBalance - newWethBalance) / 1e18} WETH)`)

    } else {
      console.error('\n  Failed to get receipt after maximum attempts')
    }

  } catch (error) {
    console.error('\n  Error submitting UserOperation:', error)

    // Fallback: Display the UserOperation for manual submission
    console.log('\n=== UserOperation (for manual submission) ===')
    console.log(JSON.stringify({
      sender: userOp.sender,
      nonce: `0x${userOp.nonce.toString(16)}`,
      initCode: userOp.initCode,
      callData: userOp.callData,
      accountGasLimits: userOp.accountGasLimits,
      preVerificationGas: `0x${userOp.preVerificationGas.toString(16)}`,
      gasFees: userOp.gasFees,
      paymasterAndData: userOp.paymasterAndData,
      signature: userOp.signature
    }, null, 2))
  }

  console.log('\n=== Script Complete ===')
}

// Run the script
main().catch(console.error)
