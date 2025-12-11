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
  timestamp: bigint  // When the deposit happened
  originalAcquisitionTimestamp: bigint  // When the tokens were originally acquired (for FIFO inheritance)
}

/**
 * FIFO queue entry for acquired balances
 * Tracks the original acquisition timestamp so tokens expire together
 * when swapped (output inherits input's original timestamp)
 */
interface AcquiredBalanceEntry {
  amount: bigint
  originalTimestamp: bigint  // When the tokens were originally acquired (for expiry calculation)
}

/**
 * FIFO queue for each token's acquired balance
 * Oldest entries are consumed first when spending
 */
type AcquiredBalanceQueue = AcquiredBalanceEntry[]

interface SubAccountState {
  spendingRecords: { amount: bigint; timestamp: bigint }[]
  depositRecords: DepositRecord[]
  totalSpendingInWindow: bigint
  // FIFO queues for acquired balances per token
  acquiredQueues: Map<Address, AcquiredBalanceQueue>
  // Final calculated acquired balances (sum of non-expired entries)
  acquiredBalances: Map<Address, bigint>
}

// ============ Event Signatures ============

const PROTOCOL_EXECUTION_EVENT = parseAbiItem(
  'event ProtocolExecution(address indexed subAccount, address indexed target, uint8 opType, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, uint256 spendingCost)'
)

const TRANSFER_EXECUTED_EVENT = parseAbiItem(
  'event TransferExecuted(address indexed subAccount, address indexed token, address indexed recipient, uint256 amount, uint256 spendingCost)'
)

const ACQUIRED_BALANCE_UPDATED_EVENT = parseAbiItem(
  'event AcquiredBalanceUpdated(address indexed subAccount, address indexed token, uint256 newBalance)'
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

/**
 * Query historical AcquiredBalanceUpdated events to find all tokens
 * that have ever had acquired balance set for a subaccount.
 * This is used to detect and clear stale on-chain balances.
 */
async function queryHistoricalAcquiredTokens(subAccount: Address): Promise<Set<Address>> {
  const tokens = new Set<Address>()

  try {
    // Query from a reasonable lookback - use extended range to catch all historical tokens
    const currentBlock = await publicClient.getBlockNumber()
    const fromBlock = currentBlock - BigInt(config.blocksToLookBack * 2)

    const logs = await publicClient.getLogs({
      address: config.moduleAddress,
      event: ACQUIRED_BALANCE_UPDATED_EVENT,
      fromBlock,
      toBlock: currentBlock,
      args: { subAccount },
    })

    for (const log of logs) {
      const token = log.args.token as Address
      if (token) {
        tokens.add(token.toLowerCase() as Address)
      }
    }
  } catch (error) {
    log(`Error querying historical acquired tokens: ${error}`)
  }

  return tokens
}

// ============ FIFO Queue Helpers ============

/**
 * Consume tokens from a FIFO queue (oldest first)
 * Returns the entries consumed with their original timestamps
 * Only consumes non-expired entries based on the event timestamp
 */
function consumeFromQueue(
  queue: AcquiredBalanceQueue,
  amount: bigint,
  eventTimestamp: bigint,
  windowDuration: bigint
): { consumed: AcquiredBalanceEntry[]; remaining: bigint } {
  const consumed: AcquiredBalanceEntry[] = []
  let remaining = amount
  const expiryThreshold = eventTimestamp - windowDuration

  while (remaining > 0n && queue.length > 0) {
    const entry = queue[0]

    // Skip expired entries (they shouldn't be consumed as acquired)
    if (entry.originalTimestamp < expiryThreshold) {
      queue.shift()
      continue
    }

    if (entry.amount <= remaining) {
      // Consume entire entry
      consumed.push({ ...entry })
      remaining -= entry.amount
      queue.shift()
    } else {
      // Partial consumption
      consumed.push({ amount: remaining, originalTimestamp: entry.originalTimestamp })
      entry.amount -= remaining
      remaining = 0n
    }
  }

  return { consumed, remaining }
}

/**
 * Add tokens to a FIFO queue with the given original timestamp
 */
function addToQueue(
  queue: AcquiredBalanceQueue,
  amount: bigint,
  originalTimestamp: bigint
): void {
  if (amount <= 0n) return
  queue.push({ amount, originalTimestamp })
}

/**
 * Get total amount in queue that hasn't expired
 */
function getValidQueueBalance(
  queue: AcquiredBalanceQueue,
  currentTimestamp: bigint,
  windowDuration: bigint
): bigint {
  const expiryThreshold = currentTimestamp - windowDuration
  let total = 0n
  for (const entry of queue) {
    if (entry.originalTimestamp >= expiryThreshold) {
      total += entry.amount
    }
  }
  return total
}

/**
 * Remove expired entries from queue
 */
function pruneExpiredEntries(
  queue: AcquiredBalanceQueue,
  currentTimestamp: bigint,
  windowDuration: bigint
): void {
  const expiryThreshold = currentTimestamp - windowDuration
  while (queue.length > 0 && queue[0].originalTimestamp < expiryThreshold) {
    queue.shift()
  }
}

// ============ State Building ============

// Unified event type for chronological processing
type UnifiedEvent =
  | { type: 'protocol'; event: ProtocolExecutionEvent }
  | { type: 'transfer'; event: TransferExecutedEvent }

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
    totalSpendingInWindow: 0n,
    acquiredQueues: new Map(),
    acquiredBalances: new Map(),
  }

  // Filter events for this subaccount
  const filteredProtocol = events
    .filter(e => e.subAccount.toLowerCase() === subAccount.toLowerCase())

  const filteredTransfers = transferEvents
    .filter(e => e.subAccount.toLowerCase() === subAccount.toLowerCase())

  // Merge into unified event list and sort chronologically
  // This ensures transfers are processed in correct order relative to protocol events
  const unifiedEvents: UnifiedEvent[] = [
    ...filteredProtocol.map(e => ({ type: 'protocol' as const, event: e })),
    ...filteredTransfers.map(e => ({ type: 'transfer' as const, event: e })),
  ].sort((a, b) => {
    const timestampDiff = Number(a.event.timestamp - b.event.timestamp)
    if (timestampDiff !== 0) return timestampDiff
    // Same timestamp: sort by block number, then log index
    const blockDiff = Number(a.event.blockNumber - b.event.blockNumber)
    if (blockDiff !== 0) return blockDiff
    return a.event.logIndex - b.event.logIndex
  })

  log(`Processing ${unifiedEvents.length} events for ${subAccount} (FIFO mode, ${filteredProtocol.length} protocol + ${filteredTransfers.length} transfers)`)

  // Track all tokens that ever had acquired balance (for cleanup)
  const tokensWithAcquiredHistory = new Set<Address>()

  // FIFO queues per token - tracks (amount, originalTimestamp)
  const acquiredQueues: Map<Address, AcquiredBalanceQueue> = new Map()

  // Helper to get or create queue
  const getQueue = (token: Address): AcquiredBalanceQueue => {
    const lower = token.toLowerCase() as Address
    if (!acquiredQueues.has(lower)) {
      acquiredQueues.set(lower, [])
    }
    return acquiredQueues.get(lower)!
  }

  // Process ALL events chronologically (unified protocol + transfer events)
  for (const unified of unifiedEvents) {
    if (unified.type === 'protocol') {
      const event = unified.event
      const tokenInLower = event.tokenIn.toLowerCase() as Address
      const tokenOutLower = event.tokenOut.toLowerCase() as Address
      const isInWindow = event.timestamp >= windowStart

      // Track spending (only count if in window)
      if (event.opType === OperationType.SWAP || event.opType === OperationType.DEPOSIT) {
        if (isInWindow && event.spendingCost > 0n) {
          state.spendingRecords.push({
            amount: event.spendingCost,
            timestamp: event.timestamp,
          })
          state.totalSpendingInWindow += event.spendingCost
        }
      }

      // Handle input token consumption (FIFO) - do this before creating deposit record
      // so we can capture the original acquisition timestamp for deposits
      // Use event timestamp to determine expiry - tokens must be valid at the time of the event
      let consumedEntries: AcquiredBalanceEntry[] = []
      if ((event.opType === OperationType.SWAP || event.opType === OperationType.DEPOSIT) &&
          event.amountIn > 0n) {
        const inputQueue = getQueue(tokenInLower)
        const result = consumeFromQueue(inputQueue, event.amountIn, event.timestamp, windowDuration)
        consumedEntries = result.consumed
        tokensWithAcquiredHistory.add(tokenInLower)
      }

      // Track deposits for withdrawal matching
      // Store the original acquisition timestamp so withdrawals inherit it correctly
      if (event.opType === OperationType.DEPOSIT) {
        // Find the oldest original timestamp from consumed acquired tokens
        // If no acquired tokens were consumed, use the deposit timestamp (it's new spending)
        let originalAcquisitionTimestamp = event.timestamp
        if (consumedEntries.length > 0) {
          originalAcquisitionTimestamp = consumedEntries.reduce(
            (oldest, entry) => entry.originalTimestamp < oldest ? entry.originalTimestamp : oldest,
            consumedEntries[0].originalTimestamp
          )
          log(`  DEPOSIT: storing original acquisition timestamp ${originalAcquisitionTimestamp} for future withdrawal`)
        }

        state.depositRecords.push({
          subAccount: event.subAccount,
          target: event.target,
          tokenIn: event.tokenIn,
          amountIn: event.amountIn,
          remainingAmount: event.amountIn,
          timestamp: event.timestamp,
          originalAcquisitionTimestamp,
        })
      }

      // Handle output token (add to acquired queue)
      // For SWAPs: proportionally split output between acquired (inherited timestamp) and new (current timestamp)
      // For WITHDRAW/CLAIM: output matched to deposits inherits their original acquisition timestamp

      if (event.opType === OperationType.SWAP) {
        if (event.amountOut > 0n) {
          tokensWithAcquiredHistory.add(tokenOutLower)
          const outputQueue = getQueue(tokenOutLower)

          // Calculate how much of the input was acquired vs non-acquired
          const totalConsumed = consumedEntries.reduce((sum, e) => sum + e.amount, 0n)
          const fromNonAcquired = event.amountIn - totalConsumed // Remaining came from original funds

          if (totalConsumed > 0n && fromNonAcquired > 0n) {
            // Mixed case: proportionally split the output
            // Acquired portion inherits oldest timestamp, non-acquired portion is newly acquired
            const acquiredRatio = (totalConsumed * 10000n) / event.amountIn // basis points
            const outputFromAcquired = (event.amountOut * acquiredRatio) / 10000n
            const outputFromNonAcquired = event.amountOut - outputFromAcquired

            // Find oldest timestamp from consumed entries
            const oldestTimestamp = consumedEntries.reduce(
              (oldest, entry) => entry.originalTimestamp < oldest ? entry.originalTimestamp : oldest,
              consumedEntries[0].originalTimestamp
            )

            log(`  SWAP: mixed input - ${totalConsumed} acquired + ${fromNonAcquired} non-acquired`)
            log(`    ${outputFromAcquired} ${event.tokenOut} inherits timestamp ${oldestTimestamp}`)
            log(`    ${outputFromNonAcquired} ${event.tokenOut} newly acquired at ${event.timestamp}`)

            addToQueue(outputQueue, outputFromAcquired, oldestTimestamp)
            addToQueue(outputQueue, outputFromNonAcquired, event.timestamp)
          } else if (totalConsumed > 0n) {
            // Entire input was acquired - output inherits oldest timestamp
            const oldestTimestamp = consumedEntries.reduce(
              (oldest, entry) => entry.originalTimestamp < oldest ? entry.originalTimestamp : oldest,
              consumedEntries[0].originalTimestamp
            )
            log(`  SWAP: ${event.amountOut} ${event.tokenOut} inherits timestamp ${oldestTimestamp} from consumed acquired tokens`)
            addToQueue(outputQueue, event.amountOut, oldestTimestamp)
          } else {
            // No acquired input - output is newly acquired
            log(`  SWAP: ${event.amountOut} ${event.tokenOut} is newly acquired at ${event.timestamp}`)
            addToQueue(outputQueue, event.amountOut, event.timestamp)
          }
        }
      } else if (event.opType === OperationType.WITHDRAW || event.opType === OperationType.CLAIM) {
        if (event.amountOut > 0n) {
          // Find matching deposits
          let remainingToMatch = event.amountOut
          let matchedOriginalTimestamp: bigint | null = null

          for (const deposit of state.depositRecords) {
            if (remainingToMatch <= 0n) break

            if (deposit.target.toLowerCase() === event.target.toLowerCase() &&
                deposit.subAccount.toLowerCase() === event.subAccount.toLowerCase() &&
                deposit.tokenIn.toLowerCase() === event.tokenOut.toLowerCase() &&
                deposit.remainingAmount > 0n) {

              const consumeAmount = remainingToMatch > deposit.remainingAmount
                ? deposit.remainingAmount
                : remainingToMatch

              deposit.remainingAmount -= consumeAmount
              remainingToMatch -= consumeAmount

              // Track the original acquisition timestamp for inheritance (not the deposit timestamp)
              // This ensures the full chain of acquired status is preserved:
              // Original swap → deposit → withdrawal all share the same original timestamp
              if (matchedOriginalTimestamp === null || deposit.originalAcquisitionTimestamp < matchedOriginalTimestamp) {
                matchedOriginalTimestamp = deposit.originalAcquisitionTimestamp
              }

              log(`  ${OperationType[event.opType]} consuming ${consumeAmount} from deposit (original acquisition: ${deposit.originalAcquisitionTimestamp})`)
            }
          }

          const matchedAmount = event.amountOut - remainingToMatch
          if (matchedAmount > 0n) {
            tokensWithAcquiredHistory.add(tokenOutLower)
            const outputQueue = getQueue(tokenOutLower)

            // Withdrawal inherits the original acquisition timestamp (not deposit timestamp)
            const outputTimestamp = matchedOriginalTimestamp || event.timestamp
            log(`  ${OperationType[event.opType]} matched: ${matchedAmount} inherits original timestamp ${outputTimestamp}`)
            addToQueue(outputQueue, matchedAmount, outputTimestamp)
          }
        }
      }
    } else {
      // Transfer event
      const transfer = unified.event
      const isInWindow = transfer.timestamp >= windowStart
      const tokenLower = transfer.token.toLowerCase() as Address

      if (isInWindow && transfer.spendingCost > 0n) {
        state.spendingRecords.push({
          amount: transfer.spendingCost,
          timestamp: transfer.timestamp,
        })
        state.totalSpendingInWindow += transfer.spendingCost
      }

      if (transfer.amount > 0n) {
        const queue = getQueue(tokenLower)
        consumeFromQueue(queue, transfer.amount, transfer.timestamp, windowDuration)
        tokensWithAcquiredHistory.add(tokenLower)
      }
    }
  }

  // Calculate final acquired balances (only non-expired entries count)
  for (const token of tokensWithAcquiredHistory) {
    const queue = acquiredQueues.get(token) || []

    // Prune expired entries
    pruneExpiredEntries(queue, currentTimestamp, windowDuration)

    // Sum remaining valid balance
    const validBalance = getValidQueueBalance(queue, currentTimestamp, windowDuration)
    state.acquiredBalances.set(token, validBalance)

    if (validBalance > 0n) {
      log(`  Token ${token}: acquired balance = ${validBalance}`)
    }
  }

  // Store queues in state for potential debugging
  state.acquiredQueues = acquiredQueues

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

  // First, add all tokens from calculated acquired balances
  for (const [token, newBalance] of acquiredBalances) {
    const onChainBalance = await getOnChainAcquiredBalance(subAccount, token)
    if (newBalance !== onChainBalance) {
      acquiredChanged = true
    }
    tokens.push(token)
    balances.push(newBalance)
  }

  // Also check for tokens that have on-chain balance but aren't in calculated map
  // These need to be cleared to 0 (e.g., tokens that aged out or had incorrect matching)
  const historicalTokens = await queryHistoricalAcquiredTokens(subAccount)
  for (const token of historicalTokens) {
    if (!acquiredBalances.has(token)) {
      const onChainBalance = await getOnChainAcquiredBalance(subAccount, token)
      if (onChainBalance > 0n) {
        log(`  Clearing stale acquired balance for ${token}: ${onChainBalance} -> 0`)
        acquiredChanged = true
        tokens.push(token)
        balances.push(0n)
      }
    }
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

  // Query from 2x the lookback range to discover tokens that may have acquired balance
  // even if the original acquisition is outside the current window
  const extendedFromBlock = blockNumber - BigInt(config.blocksToLookBack * 2)

  // Query limits and events in parallel (extended range for token discovery)
  const [{ windowDuration }, protocolEvents, transferEvents] = await Promise.all([
    getSubAccountLimits(subAccount),
    queryProtocolExecutionEvents(extendedFromBlock, blockNumber, subAccount),
    queryTransferEvents(extendedFromBlock, blockNumber, subAccount),
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
