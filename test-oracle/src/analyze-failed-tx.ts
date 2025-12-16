/**
 * Failed Transaction Analyzer
 *
 * Analyzes failed transactions on Sepolia by:
 * 1. Fetching transaction data from Etherscan
 * 2. Decoding the calldata
 * 3. Re-simulating to get the error
 * 4. Matching error to smart contract errors
 * 5. Providing human-readable explanation
 *
 * Usage: npx tsx src/analyze-failed-tx.ts <tx-hash>
 */

import {
  createPublicClient,
  http,
  decodeErrorResult,
  decodeFunctionData,
  formatEther,
  formatUnits,
  parseAbi,
  type Hex,
  type Address,
} from 'viem'
import { sepolia } from 'viem/chains'
import dotenv from 'dotenv'

dotenv.config()

// ============ Contract Error Definitions ============
// These match the errors in DeFiInteractorModule.sol and Module.sol

const CONTRACT_ERRORS = {
  // DeFiInteractorModule errors
  UnknownSelector: {
    signature: 'UnknownSelector(bytes4)',
    description: 'The function selector is not registered in the module',
    solution: 'Register the selector using registerSelector() or use a supported function',
  },
  TransactionFailed: {
    signature: 'TransactionFailed()',
    description: 'The underlying transaction to the protocol failed',
    solution: 'Check the target protocol for the actual error (insufficient balance, slippage, etc.)',
  },
  ApprovalFailed: {
    signature: 'ApprovalFailed()',
    description: 'The token approval transaction failed',
    solution: 'Check if the token contract allows approvals or if there are approval restrictions',
  },
  InvalidLimitConfiguration: {
    signature: 'InvalidLimitConfiguration()',
    description: 'Invalid sub-account limit configuration (maxSpendingBps > 10000 or windowDuration < 1 hour)',
    solution: 'Ensure maxSpendingBps <= 10000 and windowDuration >= 3600',
  },
  AddressNotAllowed: {
    signature: 'AddressNotAllowed()',
    description: 'The target address is not in the sub-account\'s whitelist',
    solution: 'Add the target address to allowedAddresses using setAllowedAddresses()',
  },
  ExceedsSpendingLimit: {
    signature: 'ExceedsSpendingLimit()',
    description: 'The operation would exceed the sub-account\'s spending allowance',
    solution: 'Wait for oracle to refresh allowance, use acquired tokens, or reduce operation size',
  },
  OnlyAuthorizedOracle: {
    signature: 'OnlyAuthorizedOracle()',
    description: 'Only the authorized oracle can call this function',
    solution: 'Use the authorized oracle address to call this function',
  },
  InvalidOracleAddress: {
    signature: 'InvalidOracleAddress()',
    description: 'Cannot set oracle to zero address',
    solution: 'Provide a valid oracle address',
  },
  StaleOracleData: {
    signature: 'StaleOracleData()',
    description: 'Oracle data for this sub-account is too old or never set',
    solution: 'Wait for oracle to update spending allowance (must be within maxOracleAge)',
  },
  StalePortfolioValue: {
    signature: 'StalePortfolioValue()',
    description: 'Safe\'s portfolio value is stale or never updated',
    solution: 'Oracle must call updateSafeValue() first',
  },
  InvalidPriceFeed: {
    signature: 'InvalidPriceFeed()',
    description: 'Price feed address is invalid (zero address)',
    solution: 'Set a valid Chainlink price feed address',
  },
  StalePriceFeed: {
    signature: 'StalePriceFeed()',
    description: 'Chainlink price feed data is stale',
    solution: 'Check if Chainlink price feed is still active on this network',
  },
  InvalidPrice: {
    signature: 'InvalidPrice()',
    description: 'Chainlink returned a zero or negative price',
    solution: 'Check if the price feed contract is correct',
  },
  NoPriceFeedSet: {
    signature: 'NoPriceFeedSet()',
    description: 'No Chainlink price feed configured for this token',
    solution: 'Owner must set price feed using setTokenPriceFeed()',
  },
  ApprovalExceedsLimit: {
    signature: 'ApprovalExceedsLimit()',
    description: 'Approval amount exceeds spending allowance for non-acquired tokens',
    solution: 'Reduce approval amount or wait for allowance refresh',
  },
  SpenderNotAllowed: {
    signature: 'SpenderNotAllowed()',
    description: 'The spender address in approve() is not whitelisted',
    solution: 'Add the spender to allowedAddresses before approving',
  },
  NoParserRegistered: {
    signature: 'NoParserRegistered(address)',
    description: 'No calldata parser is registered for this protocol',
    solution: 'Owner must register a parser using registerParser()',
  },
  ExceedsAbsoluteMaxSpending: {
    signature: 'ExceedsAbsoluteMaxSpending(uint256,uint256)',
    description: 'Oracle tried to set spending above absolute max limit',
    solution: 'This is a safety limit - cannot be exceeded even by oracle',
  },
  CannotRegisterUnknown: {
    signature: 'CannotRegisterUnknown()',
    description: 'Cannot register a selector with UNKNOWN operation type',
    solution: 'Use a valid operation type (SWAP, DEPOSIT, WITHDRAW, CLAIM, APPROVE)',
  },
  LengthMismatch: {
    signature: 'LengthMismatch()',
    description: 'Array lengths don\'t match (tokens vs amounts or balances)',
    solution: 'Ensure arrays have the same length',
  },
  ExceedsMaxBps: {
    signature: 'ExceedsMaxBps()',
    description: 'Basis points value exceeds 10000 (100%)',
    solution: 'Use a value <= 10000',
  },
  InvalidRecipient: {
    signature: 'InvalidRecipient(address,address)',
    description: 'Operation recipient is not the Safe (potential fund theft)',
    solution: 'Ensure recipient in calldata matches the Safe address',
  },
  CannotBeSubaccount: {
    signature: 'CannotBeSubaccount(address)',
    description: 'This address cannot be a sub-account (Safe, Module, or Oracle)',
    solution: 'Use a different address for the sub-account',
  },
  CannotBeOracle: {
    signature: 'CannotBeOracle(address)',
    description: 'This address cannot be the oracle (Safe, Module, or existing sub-account)',
    solution: 'Use a different address for the oracle',
  },
  CannotWhitelistCoreAddress: {
    signature: 'CannotWhitelistCoreAddress(address)',
    description: 'Cannot whitelist Safe or Module as interaction targets',
    solution: 'These addresses are blocked for security',
  },
  CannotRegisterParserForCoreAddress: {
    signature: 'CannotRegisterParserForCoreAddress(address)',
    description: 'Cannot register parser for Safe or Module',
    solution: 'Parsers cannot be registered for core addresses',
  },
  // Module.sol errors
  Unauthorized: {
    signature: 'Unauthorized()',
    description: 'Caller is not authorized (not owner or lacks required role)',
    solution: 'Use an address with the required role (DEFI_EXECUTE_ROLE or DEFI_TRANSFER_ROLE)',
  },
  InvalidAddress: {
    signature: 'InvalidAddress()',
    description: 'Address is invalid (zero address)',
    solution: 'Provide a valid non-zero address',
  },
  ModuleTransactionFailed: {
    signature: 'ModuleTransactionFailed()',
    description: 'Module transaction execution failed on the Safe',
    solution: 'Check if the module is enabled on the Safe',
  },
}

// ABI for error decoding
const ERROR_ABI = parseAbi([
  'error UnknownSelector(bytes4 selector)',
  'error TransactionFailed()',
  'error ApprovalFailed()',
  'error InvalidLimitConfiguration()',
  'error AddressNotAllowed()',
  'error ExceedsSpendingLimit()',
  'error OnlyAuthorizedOracle()',
  'error InvalidOracleAddress()',
  'error StaleOracleData()',
  'error StalePortfolioValue()',
  'error InvalidPriceFeed()',
  'error StalePriceFeed()',
  'error InvalidPrice()',
  'error NoPriceFeedSet()',
  'error ApprovalExceedsLimit()',
  'error SpenderNotAllowed()',
  'error NoParserRegistered(address target)',
  'error ExceedsAbsoluteMaxSpending(uint256 requested, uint256 maximum)',
  'error CannotRegisterUnknown()',
  'error LengthMismatch()',
  'error ExceedsMaxBps()',
  'error InvalidRecipient(address recipient, address expected)',
  'error CannotBeSubaccount(address account)',
  'error CannotBeOracle(address account)',
  'error CannotWhitelistCoreAddress(address account)',
  'error CannotRegisterParserForCoreAddress(address account)',
  'error Unauthorized()',
  'error InvalidAddress()',
  'error ModuleTransactionFailed()',
  // Parser errors
  'error UnsupportedSelector()',
  // Common EVM errors
  'error Panic(uint256 code)',
])

// DeFiInteractorModule function signatures for decoding
const MODULE_ABI = parseAbi([
  'function executeOnProtocol(address target, bytes calldata data) external returns (bytes memory)',
  'function executeOnProtocolWithValue(address target, bytes calldata data) external payable returns (bytes memory)',
  'function transferToken(address token, address recipient, uint256 amount) external returns (bool)',
  'function updateSafeValue(uint256 totalValueUSD) external',
  'function updateSpendingAllowance(address subAccount, uint256 newAllowance) external',
  'function updateAcquiredBalance(address subAccount, address token, uint256 newBalance) external',
  'function batchUpdate(address subAccount, uint256 newAllowance, address[] calldata tokens, uint256[] calldata balances) external',
  'function grantRole(address member, uint16 roleId) external',
  'function revokeRole(address member, uint16 roleId) external',
  'function registerSelector(bytes4 selector, uint8 opType) external',
  'function unregisterSelector(bytes4 selector) external',
  'function registerParser(address protocol, address parser) external',
  'function setSubAccountLimits(address subAccount, uint256 maxSpendingBps, uint256 windowDuration) external',
  'function setAllowedAddresses(address subAccount, address[] calldata targets, bool allowed) external',
  'function setTokenPriceFeed(address token, address priceFeed) external',
  'function setTokenPriceFeeds(address[] calldata tokens, address[] calldata priceFeeds) external',
  'function setAuthorizedOracle(address newOracle) external',
  'function setAbsoluteMaxSpendingBps(uint256 newMaxBps) external',
  'function pause() external',
  'function unpause() external',
])

// Common protocol function signatures
const PROTOCOL_SIGNATURES: Record<string, string> = {
  '0x617ba037': 'Aave V3 supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)',
  '0x69328dec': 'Aave V3 withdraw(address asset, uint256 amount, address to)',
  '0x573ade81': 'Aave V3 repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf)',
  '0x095ea7b3': 'ERC20 approve(address spender, uint256 amount)',
  '0xa9059cbb': 'ERC20 transfer(address to, uint256 amount)',
  '0x23b872dd': 'ERC20 transferFrom(address from, address to, uint256 amount)',
  '0x3593564c': 'Uniswap Universal Router execute(bytes commands, bytes[] inputs, uint256 deadline)',
  '0x414bf389': 'Uniswap V3 exactInputSingle(ExactInputSingleParams params)',
  '0xc04b8d59': 'Uniswap V3 exactInput(ExactInputParams params)',
}

// Operation type names
const OPERATION_TYPES = ['UNKNOWN', 'SWAP', 'DEPOSIT', 'WITHDRAW', 'CLAIM', 'APPROVE']

interface EtherscanTxResponse {
  status: string
  message: string
  result: {
    blockNumber: string
    timeStamp: string
    hash: string
    from: string
    to: string
    value: string
    gas: string
    gasUsed: string
    isError: string
    txreceipt_status: string
    input: string
    contractAddress: string
    gasPrice: string
    nonce: string
  }
}

interface AnalysisResult {
  txHash: string
  status: 'failed' | 'success' | 'pending'
  from: Address
  to: Address
  value: string
  gasUsed: string
  timestamp: Date
  blockNumber: number
  decodedFunction?: {
    name: string
    args: Record<string, unknown>
  }
  innerCall?: {
    target: Address
    selector: string
    selectorName?: string
  }
  error?: {
    name: string
    args?: Record<string, unknown>
    description: string
    solution: string
    rawData?: string
  }
  simulationError?: string
}

// Create a reusable client
function getClient() {
  const rpcUrl = process.env.RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com'
  return createPublicClient({
    chain: sepolia,
    transport: http(rpcUrl),
  })
}

interface TxData {
  from: Address
  to: Address
  value: string
  input: Hex
  blockNumber: number
  hash: string
}

async function fetchTransaction(txHash: Hex): Promise<TxData | null> {
  const client = getClient()

  try {
    const tx = await client.getTransaction({ hash: txHash })

    if (!tx) return null

    return {
      from: tx.from,
      to: tx.to as Address,
      value: tx.value.toString(),
      input: tx.input,
      blockNumber: Number(tx.blockNumber),
      hash: tx.hash,
    }
  } catch (error) {
    console.error('Error fetching transaction:', error)
    return null
  }
}

async function fetchTxReceipt(txHash: Hex): Promise<{ status: 'success' | 'reverted'; gasUsed: string } | null> {
  const client = getClient()

  try {
    const receipt = await client.getTransactionReceipt({ hash: txHash })

    if (!receipt) return null

    return {
      status: receipt.status,
      gasUsed: receipt.gasUsed.toString(),
    }
  } catch (error) {
    console.error('Error fetching receipt:', error)
    return null
  }
}

async function getBlockTimestamp(blockNumber: number): Promise<Date | null> {
  const client = getClient()

  try {
    const block = await client.getBlock({ blockNumber: BigInt(blockNumber) })

    if (block && block.timestamp) {
      return new Date(Number(block.timestamp) * 1000)
    }
    return null
  } catch {
    return null
  }
}

function decodeModuleFunction(input: Hex): { name: string; args: Record<string, unknown> } | null {
  try {
    const decoded = decodeFunctionData({
      abi: MODULE_ABI,
      data: input,
    })

    const args: Record<string, unknown> = {}
    if (decoded.args) {
      decoded.args.forEach((arg, i) => {
        args[`arg${i}`] = arg
      })
    }

    return {
      name: decoded.functionName,
      args,
    }
  } catch {
    return null
  }
}

function decodeContractError(errorData: Hex): { name: string; args?: Record<string, unknown> } | null {
  try {
    const decoded = decodeErrorResult({
      abi: ERROR_ABI,
      data: errorData,
    })

    const args: Record<string, unknown> = {}
    if (decoded.args && decoded.args.length > 0) {
      decoded.args.forEach((arg, i) => {
        args[`arg${i}`] = arg
      })
    }

    return {
      name: decoded.errorName,
      args: Object.keys(args).length > 0 ? args : undefined,
    }
  } catch {
    // Try to extract error selector for unknown errors
    if (errorData.length >= 10) {
      const selector = errorData.slice(0, 10)
      return {
        name: `UnknownError(${selector})`,
        args: { rawData: errorData },
      }
    }
    return null
  }
}

function getProtocolSelectorName(selector: string): string | undefined {
  return PROTOCOL_SIGNATURES[selector.toLowerCase()]
}

async function simulateTransaction(
  client: ReturnType<typeof createPublicClient>,
  tx: {
    from: Address
    to: Address
    data: Hex
    value: bigint
    blockNumber: bigint
  }
): Promise<{ success: boolean; error?: string; errorData?: Hex }> {
  try {
    await client.call({
      account: tx.from,
      to: tx.to,
      data: tx.data,
      value: tx.value,
      blockNumber: tx.blockNumber - 1n, // Simulate at block before tx was mined
    })
    return { success: true }
  } catch (error: unknown) {
    // Deep extract error data from various possible locations
    const extractErrorData = (obj: unknown): Hex | undefined => {
      if (!obj || typeof obj !== 'object') return undefined

      const o = obj as Record<string, unknown>

      // Check direct data property
      if (typeof o.data === 'string' && o.data.startsWith('0x')) {
        return o.data as Hex
      }

      // Check cause.data
      if (o.cause && typeof o.cause === 'object') {
        const causeData = extractErrorData(o.cause)
        if (causeData) return causeData
      }

      // Check error.data
      if (o.error && typeof o.error === 'object') {
        const errData = extractErrorData(o.error)
        if (errData) return errData
      }

      // Check for data in message (some providers include it)
      if (typeof o.message === 'string') {
        const match = o.message.match(/data: "(0x[a-fA-F0-9]+)"/)
        if (match) return match[1] as Hex
      }

      // Check details string
      if (typeof o.details === 'string') {
        const match = o.details.match(/(0x[a-fA-F0-9]{8,})/)
        if (match) return match[1] as Hex
      }

      return undefined
    }

    const err = error as { message?: string; shortMessage?: string }
    const errorData = extractErrorData(error)

    return {
      success: false,
      error: err.shortMessage || err.message || 'Unknown simulation error',
      errorData,
    }
  }
}

async function analyzeFailedTx(txHash: string): Promise<AnalysisResult> {
  console.log(`\nAnalyzing transaction: ${txHash}`)
  console.log('='.repeat(66))

  // Initialize result
  const result: AnalysisResult = {
    txHash,
    status: 'pending',
    from: '0x0' as Address,
    to: '0x0' as Address,
    value: '0',
    gasUsed: '0',
    timestamp: new Date(),
    blockNumber: 0,
  }

  // Fetch transaction
  console.log('\n1. Fetching transaction...')
  const tx = await fetchTransaction(txHash as Hex)

  if (!tx) {
    console.error('   Failed to fetch transaction')
    throw new Error('Transaction not found')
  }

  result.from = tx.from
  result.to = tx.to
  result.value = formatEther(BigInt(tx.value))
  result.blockNumber = tx.blockNumber

  console.log(`   From: ${result.from}`)
  console.log(`   To: ${result.to}`)
  console.log(`   Value: ${result.value} ETH`)
  console.log(`   Block: ${result.blockNumber}`)

  // Fetch receipt
  const receipt = await fetchTxReceipt(txHash as Hex)
  if (receipt) {
    result.status = receipt.status === 'success' ? 'success' : 'failed'
    result.gasUsed = receipt.gasUsed
    console.log(`   Status: ${result.status}`)
    console.log(`   Gas Used: ${result.gasUsed}`)
  }

  // Get timestamp
  const timestamp = await getBlockTimestamp(tx.blockNumber)
  if (timestamp) {
    result.timestamp = timestamp
    console.log(`   Time: ${timestamp.toISOString()}`)
  }

  // Decode function call
  console.log('\n2. Decoding transaction calldata...')
  const input = tx.input
  const decoded = decodeModuleFunction(input)

  if (decoded) {
    result.decodedFunction = decoded
    console.log(`   Function: ${decoded.name}`)

    // For executeOnProtocol, decode the inner call
    if (decoded.name === 'executeOnProtocol' || decoded.name === 'executeOnProtocolWithValue') {
      const target = decoded.args.arg0 as Address
      const data = decoded.args.arg1 as Hex
      const selector = data.slice(0, 10)
      const selectorName = getProtocolSelectorName(selector)

      result.innerCall = {
        target,
        selector,
        selectorName,
      }

      console.log(`   Target protocol: ${target}`)
      console.log(`   Inner selector: ${selector}`)
      if (selectorName) {
        console.log(`   Inner function: ${selectorName}`)
      }
    }

    // Log other arguments
    Object.entries(decoded.args).forEach(([key, value]) => {
      if (key !== 'arg0' && key !== 'arg1') {
        console.log(`   ${key}: ${value}`)
      }
    })
  } else {
    console.log(`   Raw selector: ${input.slice(0, 10)}`)
    const selectorName = getProtocolSelectorName(input.slice(0, 10))
    if (selectorName) {
      console.log(`   Function: ${selectorName}`)
    }
  }

  // If transaction failed, simulate to get error
  if (result.status === 'failed') {
    console.log('\n3. Re-simulating transaction to get error...')

    const rpcUrl = process.env.RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com'
    const client = createPublicClient({
      chain: sepolia,
      transport: http(rpcUrl),
    })

    const simResult = await simulateTransaction(client, {
      from: result.from,
      to: result.to,
      data: input,
      value: BigInt(tx.value),
      blockNumber: BigInt(result.blockNumber),
    })

    if (!simResult.success) {
      result.simulationError = simResult.error
      console.log(`   Simulation error: ${simResult.error}`)

      if (simResult.errorData) {
        console.log(`   Error data: ${simResult.errorData}`)

        // Decode the error
        const decodedError = decodeContractError(simResult.errorData)
        if (decodedError) {
          const errorInfo = CONTRACT_ERRORS[decodedError.name as keyof typeof CONTRACT_ERRORS]

          result.error = {
            name: decodedError.name,
            args: decodedError.args,
            description: errorInfo?.description || 'Unknown error',
            solution: errorInfo?.solution || 'Check contract source for error details',
            rawData: simResult.errorData,
          }
        }
      }
    }

    // Print error analysis
    console.log('\n4. Error Analysis:')
    console.log('─'.repeat(66))

    if (result.error) {
      console.log(`   Error: ${result.error.name}`)
      if (result.error.args) {
        Object.entries(result.error.args).forEach(([key, value]) => {
          console.log(`   ${key}: ${value}`)
        })
      }
      console.log(`\n   Description: ${result.error.description}`)
      console.log(`\n   Solution: ${result.error.solution}`)
    } else {
      console.log('   Could not decode error. Possible causes:')
      console.log('   - The error may be from the underlying protocol')
      console.log('   - Out of gas')
      console.log('   - State has changed since the original transaction')
      if (result.simulationError) {
        console.log(`\n   Raw error: ${result.simulationError}`)
      }
    }
  } else if (result.status === 'success') {
    console.log('\n3. Transaction was successful - no error to analyze')
  }

  return result
}

// Additional context lookup for common scenarios
async function lookupContext(
  client: ReturnType<typeof createPublicClient>,
  result: AnalysisResult,
  moduleAddress: Address
): Promise<void> {
  if (!result.error) return

  console.log('\n5. Additional Context:')
  console.log('─'.repeat(66))

  const moduleAbi = parseAbi([
    'function getSpendingAllowance(address subAccount) external view returns (uint256)',
    'function getAcquiredBalance(address subAccount, address token) external view returns (uint256)',
    'function lastOracleUpdate(address) external view returns (uint256)',
    'function maxOracleAge() external view returns (uint256)',
    'function allowedAddresses(address subAccount, address target) external view returns (bool)',
    'function hasRole(address member, uint16 roleId) external view returns (bool)',
    'function authorizedOracle() external view returns (address)',
    'function avatar() external view returns (address)',
    'function safeValue() external view returns (uint256 totalValueUSD, uint256 lastUpdated, uint256 updateCount)',
  ])

  try {
    switch (result.error.name) {
      case 'ExceedsSpendingLimit': {
        const allowance = await client.readContract({
          address: moduleAddress,
          abi: moduleAbi,
          functionName: 'getSpendingAllowance',
          args: [result.from],
        })
        console.log(`   Current spending allowance: ${formatUnits(allowance, 18)} USD`)
        break
      }

      case 'StaleOracleData': {
        const lastUpdate = await client.readContract({
          address: moduleAddress,
          abi: moduleAbi,
          functionName: 'lastOracleUpdate',
          args: [result.from],
        })
        const maxAge = await client.readContract({
          address: moduleAddress,
          abi: moduleAbi,
          functionName: 'maxOracleAge',
        })
        const now = BigInt(Math.floor(Date.now() / 1000))
        const age = now - lastUpdate
        console.log(`   Last oracle update: ${new Date(Number(lastUpdate) * 1000).toISOString()}`)
        console.log(`   Data age: ${age} seconds (max allowed: ${maxAge})`)
        break
      }

      case 'AddressNotAllowed': {
        if (result.innerCall) {
          const isAllowed = await client.readContract({
            address: moduleAddress,
            abi: moduleAbi,
            functionName: 'allowedAddresses',
            args: [result.from, result.innerCall.target],
          })
          console.log(`   Target ${result.innerCall.target} allowed: ${isAllowed}`)
        }
        break
      }

      case 'Unauthorized': {
        const hasExecuteRole = await client.readContract({
          address: moduleAddress,
          abi: moduleAbi,
          functionName: 'hasRole',
          args: [result.from, 1], // DEFI_EXECUTE_ROLE
        })
        const hasTransferRole = await client.readContract({
          address: moduleAddress,
          abi: moduleAbi,
          functionName: 'hasRole',
          args: [result.from, 2], // DEFI_TRANSFER_ROLE
        })
        console.log(`   Caller ${result.from}`)
        console.log(`   Has DEFI_EXECUTE_ROLE (1): ${hasExecuteRole}`)
        console.log(`   Has DEFI_TRANSFER_ROLE (2): ${hasTransferRole}`)
        break
      }

      case 'OnlyAuthorizedOracle': {
        const oracle = await client.readContract({
          address: moduleAddress,
          abi: moduleAbi,
          functionName: 'authorizedOracle',
        })
        console.log(`   Authorized oracle: ${oracle}`)
        console.log(`   Caller: ${result.from}`)
        break
      }

      case 'StalePortfolioValue': {
        const [totalValue, lastUpdated, updateCount] = await client.readContract({
          address: moduleAddress,
          abi: moduleAbi,
          functionName: 'safeValue',
        })
        console.log(`   Safe value: ${formatUnits(totalValue, 18)} USD`)
        console.log(`   Last updated: ${new Date(Number(lastUpdated) * 1000).toISOString()}`)
        console.log(`   Update count: ${updateCount}`)
        break
      }
    }
  } catch (error) {
    console.log('   Could not fetch additional context')
  }
}

// Main execution
async function main() {
  const txHash = process.argv[2]

  if (!txHash) {
    console.log('Usage: npx tsx src/analyze-failed-tx.ts <tx-hash>')
    console.log('')
    console.log('Environment variables:')
    console.log('  RPC_URL          - Sepolia RPC URL (default: public node)')
    console.log('  ETHERSCAN_API_KEY - Optional Etherscan API key')
    console.log('  MODULE_ADDRESS   - DeFiInteractorModule address (for context lookup)')
    process.exit(1)
  }

  try {
    const result = await analyzeFailedTx(txHash)

    // Lookup additional context if module address is provided
    const moduleAddress = process.env.MODULE_ADDRESS as Address | undefined
    if (moduleAddress && result.error) {
      const rpcUrl = process.env.RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com'
      const client = createPublicClient({
        chain: sepolia,
        transport: http(rpcUrl),
      })
      await lookupContext(client, result, moduleAddress)
    }

    console.log('\n' + '='.repeat(66))
    console.log('Analysis complete')

    // Return result for programmatic use
    return result
  } catch (error) {
    console.error('\nAnalysis failed:', error)
    process.exit(1)
  }
}

main()

export { analyzeFailedTx, CONTRACT_ERRORS, type AnalysisResult }
