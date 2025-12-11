/**
 * Local Spending Oracle
 *
 * Tracks spending and acquired balances for sub-accounts.
 * Uses RPC polling for event detection (replaces Chainlink CRE log triggers).
 *
 * Features:
 * - Rolling 24h window tracking for spending
 * - Deposit/withdrawal matching for acquired status
 * - Event polling for real-time updates
 * - Cron-based periodic refresh
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type Log,
  formatUnits,
  keccak256,
  toHex,
  decodeAbiParameters,
  parseAbiItem,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import cron from 'node-cron'
import { config, validateConfig } from './config.js'
import { DeFiInteractorModuleABI, OperationType } from './abi.js'

// ============ Types ============

interface ProtocolExecutionEvent {
  subAccount: Address
  target: Address
  opType: OperationType
  tokenIn: Address
  amountIn: bigint
  tokenOut: Address
  amountOut: bigint
  spendingCost: bigint
  timestamp: bigint
  blockNumber: bigint
  logIndex: number
}

interface TransferExecutedEvent {
  subAccount: Address
  token: Address
  recipient: Address
  amount: bigint
  spendingCost: bigint
  timestamp: bigint
  blockNumber: bigint
  logIndex: number
}

interface DepositRecord {
  subAccount: Address
  target: Address
  tokenIn: Address
  amountIn: bigint
  remainingAmount: bigint  // Tracks how much of the deposit hasn't been withdrawn yet
  timestamp: bigint
}

interface TokenMovement {
  token: Address
  amount: bigint
  timestamp: bigint
  isOutput: boolean
}

interface SubAccountState {
  spendingRecords: { amount: bigint; timestamp: bigint }[]
  depositRecords: DepositRecord[]
  tokenMovements: Map<Address, TokenMovement[]>
  totalSpendingInWindow: bigint
  acquiredBalances: Map<Address, bigint>
}

// ============ Event Signatures ============

const PROTOCOL_EXECUTION_EVENT = parseAbiItem(
  'event ProtocolExecution(address indexed subAccount, address indexed target, uint8 opType, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, uint256 spendingCost)'
)

const TRANSFER_EXECUTED_EVENT = parseAbiItem(
  'event TransferExecuted(address indexed subAccount, address indexed token, address indexed recipient, uint256 amount, uint256 spendingCost)'
)

// ============ Initialize Clients ============

const publicClient = createPublicClient({
  chain: config.chain,
  transport: http(config.rpcUrl),
})

let walletClient: ReturnType<typeof createWalletClient>
let account: ReturnType<typeof privateKeyToAccount>

// Track last processed block for event polling
let lastProcessedBlock = 0n

// Prevent overlapping operations
let isPolling = false
let isRefreshing = false

function initWalletClient() {
  account = privateKeyToAccount(config.privateKey)
  walletClient = createWalletClient({
    chain: config.chain,
    transport: http(config.rpcUrl),
    account,
  })
}

// ============ Logging ============

function log(message: string) {
  console.log(`[SpendingOracle ${new Date().toISOString()}] ${message}`)
}

// ============ Contract Read Functions ============

async function getSafeValue(): Promise<bigint> {
  try {
    const [totalValueUSD] = await publicClient.readContract({
      address: config.moduleAddress,
      abi: DeFiInteractorModuleABI,
      functionName: 'getSafeValue',
    })
    return totalValueUSD
  } catch (error) {
    log(`Error getting safe value: ${error}`)
    return 0n
  }
}

async function getSubAccountLimits(subAccount: Address): Promise<{ maxSpendingBps: bigint; windowDuration: bigint }> {
  try {
    const [maxSpendingBps, windowDuration] = await publicClient.readContract({
      address: config.moduleAddress,
      abi: DeFiInteractorModuleABI,
      functionName: 'getSubAccountLimits',
      args: [subAccount],
    })
    return { maxSpendingBps, windowDuration }
  } catch (error) {
    log(`Error getting sub-account limits: ${error}`)
    return { maxSpendingBps: 500n, windowDuration: 86400n }
  }
}

async function getActiveSubaccounts(): Promise<Address[]> {
  try {
    const subaccounts = await publicClient.readContract({
      address: config.moduleAddress,
      abi: DeFiInteractorModuleABI,
      functionName: 'getSubaccountsByRole',
      args: [1], // DEFI_EXECUTE_ROLE
    })
    return subaccounts as Address[]
  } catch (error) {
    log(`Error getting subaccounts: ${error}`)
    return []
  }
}

async function getOnChainSpendingAllowance(subAccount: Address): Promise<bigint> {
  try {
    const allowance = await publicClient.readContract({
      address: config.moduleAddress,
      abi: DeFiInteractorModuleABI,
      functionName: 'getSpendingAllowance',
      args: [subAccount],
    })
    return allowance as bigint
  } catch (error) {
    log(`Error getting on-chain spending allowance: ${error}`)
    return 0n
  }
}

async function getOnChainAcquiredBalance(subAccount: Address, token: Address): Promise<bigint> {
  try {
    const balance = await publicClient.readContract({
      address: config.moduleAddress,
      abi: DeFiInteractorModuleABI,
      functionName: 'getAcquiredBalance',
      args: [subAccount, token],
    })
    return balance as bigint
  } catch (error) {
    log(`Error getting on-chain acquired balance: ${error}`)
    return 0n
  }
}

// ============ Event Parsing ============

function parseProtocolExecutionLog(log: Log): ProtocolExecutionEvent {
  const subAccount = log.topics[1] ? (`0x${log.topics[1].slice(-40)}` as Address) : ('0x' as Address)
  const target = log.topics[2] ? (`0x${log.topics[2].slice(-40)}` as Address) : ('0x' as Address)

  const decoded = decodeAbiParameters(
    [
      { name: 'opType', type: 'uint8' },
      { name: 'tokenIn', type: 'address' },
      { name: 'amountIn', type: 'uint256' },
      { name: 'tokenOut', type: 'address' },
      { name: 'amountOut', type: 'uint256' },
      { name: 'spendingCost', type: 'uint256' },
    ],
    log.data
  )

  return {
    subAccount,
    target,
    opType: decoded[0] as OperationType,
    tokenIn: decoded[1] as Address,
    amountIn: decoded[2],
    tokenOut: decoded[3] as Address,
    amountOut: decoded[4],
    spendingCost: decoded[5],
    // Timestamp will be set from block data when processing
    timestamp: 0n,
    blockNumber: log.blockNumber || 0n,
    logIndex: log.logIndex || 0,
  }
}

function parseTransferExecutedLog(log: Log): TransferExecutedEvent {
  const subAccount = log.topics[1] ? (`0x${log.topics[1].slice(-40)}` as Address) : ('0x' as Address)
  const token = log.topics[2] ? (`0x${log.topics[2].slice(-40)}` as Address) : ('0x' as Address)
  const recipient = log.topics[3] ? (`0x${log.topics[3].slice(-40)}` as Address) : ('0x' as Address)

  const decoded = decodeAbiParameters(
    [
      { name: 'amount', type: 'uint256' },
      { name: 'spendingCost', type: 'uint256' },
    ],
    log.data
  )

  return {
    subAccount,
    token,
    recipient,
    amount: decoded[0],
    spendingCost: decoded[1],
    // Timestamp will be set from block data when processing
    timestamp: 0n,
    blockNumber: log.blockNumber || 0n,
    logIndex: log.logIndex || 0,
  }
}

// ============ Event Queries ============

async function queryProtocolExecutionEvents(fromBlock: bigint, toBlock: bigint, subAccount?: Address): Promise<ProtocolExecutionEvent[]> {
  try {
    const logs = await publicClient.getLogs({
      address: config.moduleAddress,
      event: PROTOCOL_EXECUTION_EVENT,
      fromBlock,
      toBlock,
      args: subAccount ? { subAccount } : undefined,
    })

    const events = logs.map(parseProtocolExecutionLog)

    // Fetch block timestamps for accurate window calculations
    const uniqueBlocks = [...new Set(events.map(e => e.blockNumber))]
    const blockTimestamps = new Map<bigint, bigint>()

    await Promise.all(
      uniqueBlocks.map(async (blockNum) => {
        try {
          const block = await publicClient.getBlock({ blockNumber: blockNum })
          blockTimestamps.set(blockNum, block.timestamp)
        } catch (err) {
          // Fallback to current time if block fetch fails
          blockTimestamps.set(blockNum, BigInt(Math.floor(Date.now() / 1000)))
        }
      })
    )

    // Update event timestamps
    for (const event of events) {
      event.timestamp = blockTimestamps.get(event.blockNumber) || BigInt(Math.floor(Date.now() / 1000))
    }

    return events
  } catch (error) {
    log(`Error querying protocol execution events: ${error}`)
    return []
  }
}

async function queryTransferEvents(fromBlock: bigint, toBlock: bigint, subAccount?: Address): Promise<TransferExecutedEvent[]> {
  try {
    const logs = await publicClient.getLogs({
      address: config.moduleAddress,
      event: TRANSFER_EXECUTED_EVENT,
      fromBlock,
      toBlock,
      args: subAccount ? { subAccount } : undefined,
    })

    const events = logs.map(parseTransferExecutedLog)

    // Fetch block timestamps for accurate window calculations
    const uniqueBlocks = [...new Set(events.map(e => e.blockNumber))]
    const blockTimestamps = new Map<bigint, bigint>()

    await Promise.all(
      uniqueBlocks.map(async (blockNum) => {
        try {
          const block = await publicClient.getBlock({ blockNumber: blockNum })
          blockTimestamps.set(blockNum, block.timestamp)
        } catch (err) {
          // Fallback to current time if block fetch fails
          blockTimestamps.set(blockNum, BigInt(Math.floor(Date.now() / 1000)))
        }
      })
    )

    // Update event timestamps
    for (const event of events) {
      event.timestamp = blockTimestamps.get(event.blockNumber) || BigInt(Math.floor(Date.now() / 1000))
    }

    return events
  } catch (error) {
    log(`Error querying transfer events: ${error}`)
    return []
  }
}

// ============ State Building ============

function buildSubAccountState(
  events: ProtocolExecutionEvent[],
  transferEvents: TransferExecutedEvent[],
  subAccount: Address,
  currentTimestamp: bigint,
  windowDuration: bigint
): SubAccountState {
  const windowStart = currentTimestamp - windowDuration

  const state: SubAccountState = {
    spendingRecords: [],
    depositRecords: [],
    tokenMovements: new Map(),
    totalSpendingInWindow: 0n,
    acquiredBalances: new Map(),
  }

  // Filter events for this subaccount within the window
  const relevantEvents = events
    .filter(e => e.subAccount.toLowerCase() === subAccount.toLowerCase())
    .filter(e => e.timestamp >= windowStart)
    .sort((a, b) => Number(a.timestamp - b.timestamp))

  const relevantTransfers = transferEvents
    .filter(e => e.subAccount.toLowerCase() === subAccount.toLowerCase())
    .filter(e => e.timestamp >= windowStart)
    .sort((a, b) => Number(a.timestamp - b.timestamp))

  log(`Processing ${relevantEvents.length} events for ${subAccount} in window`)

  // Track running acquired balance per token
  const runningAcquired: Map<Address, bigint> = new Map()

  for (const event of relevantEvents) {
    const tokenInLower = event.tokenIn.toLowerCase() as Address
    const tokenOutLower = event.tokenOut.toLowerCase() as Address

    // Track spending
    if (event.opType === OperationType.SWAP || event.opType === OperationType.DEPOSIT) {
      if (event.spendingCost > 0n) {
        state.spendingRecords.push({
          amount: event.spendingCost,
          timestamp: event.timestamp,
        })
        state.totalSpendingInWindow += event.spendingCost
      }

      // Track how much of the input came from acquired
      if (event.tokenIn !== '0x0000000000000000000000000000000000000000' && event.amountIn > 0n) {
        const currentAcquired = runningAcquired.get(tokenInLower) || 0n
        const usedFromAcquired = event.amountIn > currentAcquired ? currentAcquired : event.amountIn

        if (usedFromAcquired > 0n) {
          runningAcquired.set(tokenInLower, currentAcquired - usedFromAcquired)

          if (!state.tokenMovements.has(tokenInLower)) {
            state.tokenMovements.set(tokenInLower, [])
          }
          state.tokenMovements.get(tokenInLower)!.push({
            token: event.tokenIn,
            amount: usedFromAcquired,
            timestamp: event.timestamp,
            isOutput: false,
          })
        }
      }
    }

    // Track deposits for withdrawal matching
    if (event.opType === OperationType.DEPOSIT) {
      state.depositRecords.push({
        subAccount: event.subAccount,
        target: event.target,
        tokenIn: event.tokenIn,
        amountIn: event.amountIn,
        remainingAmount: event.amountIn,  // Initially, full amount is available for withdrawal
        timestamp: event.timestamp,
      })
    }

    // Track outputs (add to acquired)
    let acquiredAmount = 0n
    let acquiredToken: Address | null = null

    if (event.opType === OperationType.SWAP) {
      if (event.tokenOut !== '0x0000000000000000000000000000000000000000' && event.amountOut > 0n) {
        acquiredToken = tokenOutLower
        acquiredAmount = event.amountOut
      }
    } else if (event.opType === OperationType.WITHDRAW || event.opType === OperationType.CLAIM) {
      if (event.tokenOut !== '0x0000000000000000000000000000000000000000' && event.amountOut > 0n) {
        // Find matching deposits with remaining balance and consume from them
        let remainingToMatch = event.amountOut

        for (const deposit of state.depositRecords) {
          if (remainingToMatch <= 0n) break

          // Check if this deposit matches (same target, subAccount, and token)
          if (deposit.target.toLowerCase() === event.target.toLowerCase() &&
              deposit.subAccount.toLowerCase() === event.subAccount.toLowerCase() &&
              deposit.tokenIn.toLowerCase() === event.tokenOut.toLowerCase() &&
              deposit.remainingAmount > 0n) {

            // Calculate how much we can consume from this deposit
            const consumeAmount = remainingToMatch > deposit.remainingAmount
              ? deposit.remainingAmount
              : remainingToMatch

            // Consume from the deposit
            deposit.remainingAmount -= consumeAmount
            remainingToMatch -= consumeAmount

            log(`  ${OperationType[event.opType]} consuming ${consumeAmount} from deposit (remaining in deposit: ${deposit.remainingAmount})`)
          }
        }

        // Only the matched portion becomes acquired
        const matchedAmount = event.amountOut - remainingToMatch
        if (matchedAmount > 0n) {
          acquiredToken = tokenOutLower
          acquiredAmount = matchedAmount
          log(`  ${OperationType[event.opType]} matched to deposit: ${matchedAmount} of ${event.tokenOut} (unmatched: ${remainingToMatch})`)
        } else {
          log(`  ${OperationType[event.opType]} NOT matched to any deposit: ${event.amountOut} of ${event.tokenOut}`)
        }
      }
    }

    // Add output to running acquired
    if (acquiredToken && acquiredAmount > 0n) {
      const current = runningAcquired.get(acquiredToken) || 0n
      runningAcquired.set(acquiredToken, current + acquiredAmount)

      if (!state.tokenMovements.has(acquiredToken)) {
        state.tokenMovements.set(acquiredToken, [])
      }
      state.tokenMovements.get(acquiredToken)!.push({
        token: acquiredToken,
        amount: acquiredAmount,
        timestamp: event.timestamp,
        isOutput: true,
      })
    }
  }

  // Process transfer events
  for (const transfer of relevantTransfers) {
    if (transfer.spendingCost > 0n) {
      state.spendingRecords.push({
        amount: transfer.spendingCost,
        timestamp: transfer.timestamp,
      })
      state.totalSpendingInWindow += transfer.spendingCost
    }

    const tokenLower = transfer.token.toLowerCase() as Address
    if (transfer.amount > 0n) {
      const currentAcquired = runningAcquired.get(tokenLower) || 0n
      const usedFromAcquired = transfer.amount > currentAcquired ? currentAcquired : transfer.amount

      if (usedFromAcquired > 0n) {
        runningAcquired.set(tokenLower, currentAcquired - usedFromAcquired)

        if (!state.tokenMovements.has(tokenLower)) {
          state.tokenMovements.set(tokenLower, [])
        }
        state.tokenMovements.get(tokenLower)!.push({
          token: transfer.token,
          amount: usedFromAcquired,
          timestamp: transfer.timestamp,
          isOutput: false,
        })
      }
    }
  }

  // Calculate final acquired balances
  for (const [token, movements] of state.tokenMovements) {
    const validMovements = movements.filter(m => m.timestamp >= windowStart)

    let netAcquired = 0n
    for (const m of validMovements) {
      if (m.isOutput) {
        netAcquired += m.amount
      } else {
        netAcquired -= m.amount
      }
    }

    if (netAcquired < 0n) {
      netAcquired = 0n
    }

    state.acquiredBalances.set(token, netAcquired)
  }

  log(`State built: spending=${state.totalSpendingInWindow}, acquired tokens=${state.acquiredBalances.size}`)

  return state
}

// ============ Allowance Calculation ============

async function calculateSpendingAllowance(
  subAccount: Address,
  state: SubAccountState
): Promise<bigint> {
  const safeValue = await getSafeValue()
  const { maxSpendingBps } = await getSubAccountLimits(subAccount)

  const maxSpending = (safeValue * maxSpendingBps) / 10000n
  const newAllowance = maxSpending > state.totalSpendingInWindow
    ? maxSpending - state.totalSpendingInWindow
    : 0n

  log(`Allowance: safeValue=${formatUnits(safeValue, 18)}, maxBps=${maxSpendingBps}, max=${formatUnits(maxSpending, 18)}, spent=${formatUnits(state.totalSpendingInWindow, 18)}, new=${formatUnits(newAllowance, 18)}`)

  return newAllowance
}

// ============ Contract Write ============

// Threshold for considering allowance values "equal" (0% tolerance for allowances)
const ALLOWANCE_CHANGE_THRESHOLD_BPS = 0n // 0%

async function pushBatchUpdate(
  subAccount: Address,
  newAllowance: bigint,
  acquiredBalances: Map<Address, bigint>
): Promise<string | null> {
  // Get current on-chain values
  const onChainAllowance = await getOnChainSpendingAllowance(subAccount)

  // Check if allowance change is significant
  const allowanceDiff = newAllowance > onChainAllowance
    ? newAllowance - onChainAllowance
    : onChainAllowance - newAllowance
  const allowanceThreshold = (onChainAllowance * ALLOWANCE_CHANGE_THRESHOLD_BPS) / 10000n
  const allowanceChanged = allowanceDiff > allowanceThreshold

  // Check if any acquired balances changed
  const tokens: Address[] = []
  const balances: bigint[] = []
  let acquiredChanged = false

  for (const [token, newBalance] of acquiredBalances) {
    const onChainBalance = await getOnChainAcquiredBalance(subAccount, token)
    if (newBalance !== onChainBalance) {
      acquiredChanged = true
    }
    tokens.push(token)
    balances.push(newBalance)
  }

  // Skip if no changes
  if (!allowanceChanged && !acquiredChanged) {
    log(`Skipping batch update - no changes (allowance: ${formatUnits(onChainAllowance, 18)} -> ${formatUnits(newAllowance, 18)}, tokens: ${tokens.length})`)
    return null
  }

  log(`Pushing batch update: subAccount=${subAccount}, allowance=${formatUnits(newAllowance, 18)} (was ${formatUnits(onChainAllowance, 18)}), tokens=${tokens.length}`)

  try {
    const hash = await walletClient.writeContract({
      chain: config.chain,
      account,
      address: config.moduleAddress,
      abi: DeFiInteractorModuleABI,
      functionName: 'batchUpdate',
      args: [subAccount, newAllowance, tokens, balances],
      gas: config.gasLimit,
    })

    log(`Transaction submitted: ${hash}`)

    const receipt = await publicClient.waitForTransactionReceipt({ hash })
    log(`Transaction confirmed in block ${receipt.blockNumber}`)

    return hash
  } catch (error) {
    log(`Error pushing batch update: ${error}`)
    throw error
  }
}

// ============ Event Polling ============

async function pollForNewEvents() {
  // Prevent overlapping polls
  if (isPolling) {
    return
  }
  isPolling = true

  try {
    const currentBlock = await publicClient.getBlockNumber()

    if (lastProcessedBlock === 0n) {
      // First run - start from recent blocks
      lastProcessedBlock = currentBlock - BigInt(config.blocksToLookBack)
    }

    if (currentBlock <= lastProcessedBlock) {
      isPolling = false
      return // No new blocks
    }

    const blocksToProcess = currentBlock - lastProcessedBlock
    log(`Polling blocks ${lastProcessedBlock + 1n} to ${currentBlock} (${blocksToProcess} blocks)`)

    // Query new events in parallel
    const [protocolEvents, transferEvents] = await Promise.all([
      queryProtocolExecutionEvents(lastProcessedBlock + 1n, currentBlock),
      queryTransferEvents(lastProcessedBlock + 1n, currentBlock),
    ])

    if (protocolEvents.length > 0 || transferEvents.length > 0) {
      log(`Found ${protocolEvents.length} protocol events and ${transferEvents.length} transfer events`)

      // Get unique subaccounts from events
      const affectedSubaccounts = new Set<Address>()
      for (const e of protocolEvents) {
        affectedSubaccounts.add(e.subAccount)
      }
      for (const e of transferEvents) {
        affectedSubaccounts.add(e.subAccount)
      }

      // Process all affected subaccounts in parallel
      await Promise.allSettled(
        [...affectedSubaccounts].map((subAccount) => processSubaccount(subAccount, currentBlock))
      )
    }

    lastProcessedBlock = currentBlock
  } catch (error) {
    log(`Error polling for events: ${error}`)
  } finally {
    isPolling = false
  }
}

// ============ Subaccount Processing ============

async function processSubaccount(subAccount: Address, currentBlock?: bigint) {
  const currentTimestamp = BigInt(Math.floor(Date.now() / 1000))
  const blockNumber = currentBlock ?? await publicClient.getBlockNumber()
  const fromBlock = blockNumber - BigInt(config.blocksToLookBack)

  // Query limits and events in parallel
  const [{ windowDuration }, protocolEvents, transferEvents] = await Promise.all([
    getSubAccountLimits(subAccount),
    queryProtocolExecutionEvents(fromBlock, blockNumber, subAccount),
    queryTransferEvents(fromBlock, blockNumber, subAccount),
  ])

  // Build state
  const state = buildSubAccountState(protocolEvents, transferEvents, subAccount, currentTimestamp, windowDuration)

  // Calculate allowance
  const newAllowance = await calculateSpendingAllowance(subAccount, state)

  // Push update
  await pushBatchUpdate(subAccount, newAllowance, state.acquiredBalances)
}

// ============ Cron Handler ============

async function onCronRefresh() {
  // Prevent overlapping refreshes
  if (isRefreshing) {
    log('Skipping cron refresh - previous refresh still running')
    return
  }
  isRefreshing = true

  log('=== Spending Oracle: Periodic Refresh ===')

  try {
    // Fetch subaccounts and current block in parallel
    const [subaccounts, currentBlock] = await Promise.all([
      getActiveSubaccounts(),
      publicClient.getBlockNumber(),
    ])
    log(`Found ${subaccounts.length} active subaccounts`)

    if (subaccounts.length === 0) {
      log('No active subaccounts, skipping refresh')
      return
    }

    // Process all subaccounts in parallel
    const results = await Promise.allSettled(
      subaccounts.map(async (subAccount) => {
        log(`Processing subaccount: ${subAccount}`)
        return processSubaccount(subAccount, currentBlock)
      })
    )

    // Log any failures
    results.forEach((result, i) => {
      if (result.status === 'rejected') {
        log(`Error processing ${subaccounts[i]}: ${result.reason}`)
      }
    })

    log('=== Periodic Refresh Complete ===')
  } catch (error) {
    log(`Error in periodic refresh: ${error}`)
  } finally {
    isRefreshing = false
  }
}

// ============ Main Functions ============

/**
 * Run a single update (for testing)
 */
export async function runOnce() {
  validateConfig()
  initWalletClient()
  await onCronRefresh()
}

/**
 * Start the oracle with polling and cron
 */
export function start() {
  validateConfig()
  initWalletClient()

  log(`Starting Spending Oracle`)
  log(`Module address: ${config.moduleAddress}`)
  log(`Updater address: ${account.address}`)
  log(`Poll interval: ${config.pollIntervalMs}ms`)
  log(`Cron schedule: ${config.spendingOracleCron}`)

  // Start event polling
  setInterval(pollForNewEvents, config.pollIntervalMs)

  // Start cron for periodic refresh
  cron.schedule(config.spendingOracleCron, onCronRefresh)

  // Run initial refresh
  onCronRefresh()
}

// Run if called directly
if (import.meta.url === `file://${process.argv[1]}`) {
  start()
}
