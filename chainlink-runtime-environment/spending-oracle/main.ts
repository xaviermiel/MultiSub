/**
 * Spending Oracle for DeFiInteractorModule
 *
 * Implements the Acquired Balance Model with FIFO tracking:
 * - Rolling 24h window tracking for spending
 * - FIFO queue for acquired balances with original timestamp preservation
 * - Deposit/withdrawal matching for acquired status with timestamp inheritance
 * - 24h expiry for acquired balances based on original acquisition timestamp
 * - Periodic allowance refresh via cron trigger
 * - Proper tracking of acquired balance usage (deductions)
 * - Stale on-chain balance clearing
 *
 * State Management:
 * Since CRE workflows are stateless, we query historical events from the chain
 * to reconstruct state on each invocation. This ensures verifiable, decentralized
 * state derivation.
 *
 * Key Design:
 * - FIFO queues track (amount, originalTimestamp) for each token
 * - When swapping/depositing, consumed acquired tokens' timestamps are inherited
 * - Mixed acquired/non-acquired inputs are proportionally split in outputs
 * - The contract reads acquired balances, oracle manages them
 * - Spending is one-way (no recovery on withdrawals)
 */

import {
	bytesToHex,
	type CronPayload,
	cre,
	encodeCallMsg,
	getNetwork,
	hexToBase64,
	LAST_FINALIZED_BLOCK_NUMBER,
	Runner,
	type Runtime,
	TxStatus,
} from '@chainlink/cre-sdk'
import {
	type Address,
	decodeAbiParameters,
	decodeFunctionResult,
	encodeFunctionData,
	keccak256,
	toHex,
	zeroAddress,
} from 'viem'
import { z } from 'zod'
import { DeFiInteractorModule, OperationType } from '../contracts/abi'

// ============ Configuration Schema ============

const TokenSchema = z.object({
	address: z.string(),
	priceFeedAddress: z.string(),
	symbol: z.string(),
})

const configSchema = z.object({
	moduleAddress: z.string(),
	chainSelectorName: z.string(),
	gasLimit: z.string(),
	proxyAddress: z.string(),
	tokens: z.array(TokenSchema),
	// Cron schedule for periodic allowance refresh (e.g., "*/5 * * * *" for every 5 minutes)
	refreshSchedule: z.string(),
	// Window duration in seconds (default 24 hours)
	windowDurationSeconds: z.number(),
	// How many blocks to look back for events (approximate 24h worth)
	// Ethereum: ~7200 blocks/day, Arbitrum: ~300000 blocks/day
	blocksToLookBack: z.number(),
})

type Config = z.infer<typeof configSchema>

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
// Note: Events no longer include timestamp parameter - contract uses block.timestamp

const PROTOCOL_EXECUTION_EVENT_SIG = keccak256(
	toHex('ProtocolExecution(address,address,uint8,address,uint256,address,uint256,uint256)')
)

const TRANSFER_EXECUTED_EVENT_SIG = keccak256(
	toHex('TransferExecuted(address,address,address,uint256,uint256)')
)

const ACQUIRED_BALANCE_UPDATED_EVENT_SIG = keccak256(
	toHex('AcquiredBalanceUpdated(address,address,uint256,uint256)')
)

// ============ Helper Functions ============

/**
 * Get the network configuration
 */
const getNetworkConfig = (runtime: Runtime<Config>) => {
	const isTestnet = runtime.config.chainSelectorName.includes('testnet') ||
		runtime.config.chainSelectorName.includes('sepolia')

	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: runtime.config.chainSelectorName,
		isTestnet,
	})

	if (!network) {
		throw new Error(`Network not found for: ${runtime.config.chainSelectorName}`)
	}

	return network
}

/**
 * Create an EVM client for contract calls
 */
const createEvmClient = (runtime: Runtime<Config>) => {
	const network = getNetworkConfig(runtime)
	return new cre.capabilities.EVMClient(network.chainSelector.selector)
}

const getCurrentBlockTimestamp = (): bigint => {
	return BigInt(Math.floor(Date.now() / 1000))
}

/**
 * Get current acquired balance from contract
 * This is the source of truth for what's currently available
 */
const getContractAcquiredBalance = (
	runtime: Runtime<Config>,
	subAccount: Address,
	token: Address,
): bigint => {
	const evmClient = createEvmClient(runtime)

	const callData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'getAcquiredBalance',
		args: [subAccount, token],
	})

	try {
		const result = evmClient
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: runtime.config.moduleAddress as Address,
					data: callData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()

		if (!result.data || result.data.length === 0) {
			return 0n
		}

		return decodeFunctionResult({
			abi: DeFiInteractorModule,
			functionName: 'getAcquiredBalance',
			data: bytesToHex(result.data),
		})
	} catch (error) {
		runtime.log(`Error getting acquired balance: ${error}`)
		return 0n
	}
}

const getSubAccountLimits = (
	runtime: Runtime<Config>,
	subAccount: Address,
): { maxSpendingBps: bigint; windowDuration: bigint } => {
	const evmClient = createEvmClient(runtime)

	const callData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'getSubAccountLimits',
		args: [subAccount],
	})

	try {
		const result = evmClient
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: runtime.config.moduleAddress as Address,
					data: callData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()

		if (!result.data || result.data.length === 0) {
			return { maxSpendingBps: 500n, windowDuration: 86400n }
		}

		const [maxSpendingBps, windowDuration] = decodeFunctionResult({
			abi: DeFiInteractorModule,
			functionName: 'getSubAccountLimits',
			data: bytesToHex(result.data),
		})

		return { maxSpendingBps, windowDuration }
	} catch (error) {
		runtime.log(`Error getting subaccount limits: ${error}`)
		return { maxSpendingBps: 500n, windowDuration: 86400n }
	}
}

/**
 * Get Safe's total USD value from contract
 */
const getSafeValue = (runtime: Runtime<Config>): bigint => {
	const evmClient = createEvmClient(runtime)

	const callData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'getSafeValue',
	})

	try {
		const result = evmClient
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: runtime.config.moduleAddress as Address,
					data: callData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()

		if (!result.data || result.data.length === 0) {
			return 0n
		}

		const [totalValueUSD] = decodeFunctionResult({
			abi: DeFiInteractorModule,
			functionName: 'getSafeValue',
			data: bytesToHex(result.data),
		})

		return totalValueUSD
	} catch (error) {
		runtime.log(`Error getting safe value: ${error}`)
		return 0n
	}
}

/**
 * Get all subaccounts with DEFI_EXECUTE_ROLE
 */
const getActiveSubaccounts = (runtime: Runtime<Config>): Address[] => {
	const evmClient = createEvmClient(runtime)

	// DEFI_EXECUTE_ROLE = 1
	const callData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'getSubaccountsByRole',
		args: [1], // DEFI_EXECUTE_ROLE
	})

	try {
		const result = evmClient
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: runtime.config.moduleAddress as Address,
					data: callData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()

		if (!result.data || result.data.length === 0) {
			return []
		}

		return decodeFunctionResult({
			abi: DeFiInteractorModule,
			functionName: 'getSubaccountsByRole',
			data: bytesToHex(result.data),
		}) as Address[]
	} catch (error) {
		runtime.log(`Error getting subaccounts: ${error}`)
		return []
	}
}

/**
 * Convert SDK BigInt (Uint8Array absVal) to native bigint
 */
const sdkBigIntToBigInt = (sdkBigInt: { absVal: Uint8Array; sign: bigint }): bigint => {
	// absVal is big-endian bytes representing the absolute value
	let result = 0n
	for (const byte of sdkBigInt.absVal) {
		result = (result << 8n) | BigInt(byte)
	}
	// Apply sign (negative if sign < 0)
	return sdkBigInt.sign < 0n ? -result : result
}

/**
 * Get current finalized block number from the chain
 */
const getCurrentBlockNumber = (runtime: Runtime<Config>): bigint => {
	const evmClient = createEvmClient(runtime)

	try {
		const headerResult = evmClient
			.headerByNumber(runtime, {
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()

		if (headerResult.header?.blockNumber) {
			// blockNumber is SDK BigInt type with Uint8Array absVal
			return sdkBigIntToBigInt(headerResult.header.blockNumber)
		}
		return 0n
	} catch (error) {
		runtime.log(`Error getting current block number: ${error}`)
		return 0n
	}
}

/**
 * Convert address to padded 32-byte hex string for topic filtering
 */
const addressToTopicBytes = (address: Address): string => {
	return '0x' + address.slice(2).toLowerCase().padStart(64, '0')
}

/**
 * Query historical ProtocolExecution events from the past 24h
 */
const queryHistoricalEvents = (
	runtime: Runtime<Config>,
	subAccount?: Address,
): ProtocolExecutionEvent[] => {
	const evmClient = createEvmClient(runtime)
	const events: ProtocolExecutionEvent[] = []

	runtime.log(`Querying historical events (last ${runtime.config.blocksToLookBack} blocks)...`)

	try {
		// Get current finalized block number
		const currentBlock = getCurrentBlockNumber(runtime)
		if (currentBlock === 0n) {
			runtime.log('Could not determine current block number')
			return events
		}

		const fromBlock = currentBlock - BigInt(runtime.config.blocksToLookBack)
		runtime.log(`Block range: ${fromBlock} to ${currentBlock}`)

		// Build topics array for filterLogs
		// topics[0] = event signature, topics[1] = indexed subAccount (optional)
		const topics: Array<{ topic: string[] }> = [
			{ topic: [PROTOCOL_EXECUTION_EVENT_SIG] },
		]

		if (subAccount) {
			topics.push({ topic: [addressToTopicBytes(subAccount)] })
		}

		// Query logs using filterLogs with proper FilterLogsRequest structure
		const logsResult = evmClient
			.filterLogs(runtime, {
				filterQuery: {
					addresses: [runtime.config.moduleAddress],
					topics: topics,
					fromBlock: { absVal: fromBlock.toString(), sign: '' },
					toBlock: { absVal: currentBlock.toString(), sign: '' },
				},
			})
			.result()

		if (!logsResult.logs || logsResult.logs.length === 0) {
			runtime.log('No historical events found')
			return events
		}

		runtime.log(`Found ${logsResult.logs.length} historical events`)

		for (const log of logsResult.logs) {
			try {
				const event = parseProtocolExecutionEvent(log)
				events.push(event)
			} catch (error) {
				runtime.log(`Error parsing event: ${error}`)
			}
		}
	} catch (error) {
		runtime.log(`Error querying historical events: ${error}`)
	}

	return events
}

/**
 * Convert Uint8Array to hex string
 */
const uint8ArrayToHex = (arr: Uint8Array): `0x${string}` => {
	return ('0x' + Array.from(arr).map(b => b.toString(16).padStart(2, '0')).join('')) as `0x${string}`
}

/**
 * Extract address from 32-byte topic (last 20 bytes)
 */
const topicToAddress = (topic: Uint8Array | string): Address => {
	if (typeof topic === 'string') {
		// Handle string format (hex)
		return ('0x' + topic.slice(-40)) as Address
	}
	// Handle Uint8Array format (take last 20 bytes)
	const addressBytes = topic.slice(-20)
	return uint8ArrayToHex(addressBytes) as Address
}

/**
 * Parse ProtocolExecution event from log data
 * Handles both SDK Log type (Uint8Array) and JSON format (string)
 */
const parseProtocolExecutionEvent = (log: any): ProtocolExecutionEvent => {
	// Handle topics - SDK returns Uint8Array[], may also be string[]
	const topic1 = log.topics[1]
	const topic2 = log.topics[2]
	const subAccount = topicToAddress(topic1)
	const target = topicToAddress(topic2)

	// Handle data - SDK returns Uint8Array, may also be string
	const data = typeof log.data === 'string'
		? log.data as `0x${string}`
		: uint8ArrayToHex(log.data)

	const decoded = decodeAbiParameters(
		[
			{ name: 'opType', type: 'uint8' },
			{ name: 'tokenIn', type: 'address' },
			{ name: 'amountIn', type: 'uint256' },
			{ name: 'tokenOut', type: 'address' },
			{ name: 'amountOut', type: 'uint256' },
			{ name: 'spendingCost', type: 'uint256' },
		],
		data,
	)

	// Handle blockNumber - SDK returns BigInt type with Uint8Array absVal
	let blockNumber = 0n
	if (log.blockNumber) {
		if (typeof log.blockNumber === 'bigint' || typeof log.blockNumber === 'number') {
			blockNumber = BigInt(log.blockNumber)
		} else if (log.blockNumber.absVal) {
			blockNumber = sdkBigIntToBigInt(log.blockNumber)
		}
	}

	// Handle logIndex - SDK may return number, BigInt, or SDK BigInt type
	let logIndex = 0
	if (log.logIndex !== undefined) {
		if (typeof log.logIndex === 'number') {
			logIndex = log.logIndex
		} else if (typeof log.logIndex === 'bigint') {
			logIndex = Number(log.logIndex)
		} else if (log.logIndex.absVal) {
			logIndex = Number(sdkBigIntToBigInt(log.logIndex))
		}
	}

	return {
		subAccount,
		target,
		opType: decoded[0] as OperationType,
		tokenIn: decoded[1] as Address,
		amountIn: decoded[2],
		tokenOut: decoded[3] as Address,
		amountOut: decoded[4],
		spendingCost: decoded[5],
		// Use current timestamp as proxy since event doesn't include it
		timestamp: BigInt(Math.floor(Date.now() / 1000)),
		blockNumber,
		logIndex,
	}
}

/**
 * Parse TransferExecuted event from log data
 * Event: TransferExecuted(address indexed subAccount, address indexed token, address indexed recipient, uint256 amount, uint256 spendingCost)
 */
const parseTransferExecutedEvent = (log: any): TransferExecutedEvent => {
	// All 3 parameters are indexed (topics[1], topics[2], topics[3])
	const topic1 = log.topics[1]
	const topic2 = log.topics[2]
	const topic3 = log.topics[3]
	const subAccount = topicToAddress(topic1)
	const token = topicToAddress(topic2)
	const recipient = topicToAddress(topic3)

	// Handle data - contains amount, spendingCost (no timestamp)
	const data = typeof log.data === 'string'
		? log.data as `0x${string}`
		: uint8ArrayToHex(log.data)

	const decoded = decodeAbiParameters(
		[
			{ name: 'amount', type: 'uint256' },
			{ name: 'spendingCost', type: 'uint256' },
		],
		data,
	)

	// Handle blockNumber
	let blockNumber = 0n
	if (log.blockNumber) {
		if (typeof log.blockNumber === 'bigint' || typeof log.blockNumber === 'number') {
			blockNumber = BigInt(log.blockNumber)
		} else if (log.blockNumber.absVal) {
			blockNumber = sdkBigIntToBigInt(log.blockNumber)
		}
	}

	// Handle logIndex
	let logIndex = 0
	if (log.logIndex !== undefined) {
		if (typeof log.logIndex === 'number') {
			logIndex = log.logIndex
		} else if (typeof log.logIndex === 'bigint') {
			logIndex = Number(log.logIndex)
		} else if (log.logIndex.absVal) {
			logIndex = Number(sdkBigIntToBigInt(log.logIndex))
		}
	}

	return {
		subAccount,
		token,
		recipient,
		amount: decoded[0],
		spendingCost: decoded[1],
		// Use current timestamp as proxy since event doesn't include it
		timestamp: BigInt(Math.floor(Date.now() / 1000)),
		blockNumber,
		logIndex,
	}
}

/**
 * Query historical TransferExecuted events from the past 24h
 */
const queryTransferEvents = (
	runtime: Runtime<Config>,
	subAccount?: Address,
): TransferExecutedEvent[] => {
	const evmClient = createEvmClient(runtime)
	const events: TransferExecutedEvent[] = []

	runtime.log(`Querying transfer events (last ${runtime.config.blocksToLookBack} blocks)...`)

	try {
		const currentBlock = getCurrentBlockNumber(runtime)
		if (currentBlock === 0n) {
			runtime.log('Could not determine current block number')
			return events
		}

		const fromBlock = currentBlock - BigInt(runtime.config.blocksToLookBack)

		const topics: Array<{ topic: string[] }> = [
			{ topic: [TRANSFER_EXECUTED_EVENT_SIG] },
		]

		if (subAccount) {
			topics.push({ topic: [addressToTopicBytes(subAccount)] })
		}

		const logsResult = evmClient
			.filterLogs(runtime, {
				filterQuery: {
					addresses: [runtime.config.moduleAddress],
					topics: topics,
					fromBlock: { absVal: fromBlock.toString(), sign: '' },
					toBlock: { absVal: currentBlock.toString(), sign: '' },
				},
			})
			.result()

		if (!logsResult.logs || logsResult.logs.length === 0) {
			runtime.log('No transfer events found')
			return events
		}

		runtime.log(`Found ${logsResult.logs.length} transfer events`)

		for (const log of logsResult.logs) {
			try {
				const event = parseTransferExecutedEvent(log)
				events.push(event)
			} catch (error) {
				runtime.log(`Error parsing transfer event: ${error}`)
			}
		}
	} catch (error) {
		runtime.log(`Error querying transfer events: ${error}`)
	}

	return events
}

/**
 * Query historical AcquiredBalanceUpdated events to find all tokens
 * that have ever had acquired balance set for a subaccount.
 * This is used to detect and clear stale on-chain balances.
 */
const queryHistoricalAcquiredTokens = (
	runtime: Runtime<Config>,
	subAccount: Address,
): Set<Address> => {
	const tokens = new Set<Address>()
	const evmClient = createEvmClient(runtime)

	try {
		// Query from a reasonable lookback - use extended range to catch all historical tokens
		const currentBlock = getCurrentBlockNumber(runtime)
		const fromBlock = currentBlock - BigInt(runtime.config.blocksToLookBack * 2)

		const topics: Array<{ topic: string[] }> = [
			{ topic: [ACQUIRED_BALANCE_UPDATED_EVENT_SIG] },
			{ topic: [addressToTopicBytes(subAccount)] },
		]

		const logsResult = evmClient
			.filterLogs(runtime, {
				filterQuery: {
					addresses: [runtime.config.moduleAddress],
					topics: topics,
					fromBlock: { absVal: fromBlock.toString(), sign: '' },
					toBlock: { absVal: currentBlock.toString(), sign: '' },
				},
			})
			.result()

		if (logsResult.logs && logsResult.logs.length > 0) {
			for (const log of logsResult.logs) {
				// topics[2] is the token address (indexed)
				const topic2 = log.topics[2]
				const token = topicToAddress(topic2)
				if (token) {
					tokens.add(token.toLowerCase() as Address)
				}
			}
		}
	} catch (error) {
		runtime.log(`Error querying historical acquired tokens: ${error}`)
	}

	return tokens
}

// ============ FIFO Queue Helpers ============

/**
 * Consume tokens from a FIFO queue (oldest first)
 * Returns the entries consumed with their original timestamps
 * Only consumes non-expired entries based on the event timestamp
 */
const consumeFromQueue = (
	queue: AcquiredBalanceQueue,
	amount: bigint,
	eventTimestamp: bigint,
	windowDuration: bigint
): { consumed: AcquiredBalanceEntry[]; remaining: bigint } => {
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
const addToQueue = (
	queue: AcquiredBalanceQueue,
	amount: bigint,
	originalTimestamp: bigint
): void => {
	if (amount <= 0n) return
	queue.push({ amount, originalTimestamp })
}

/**
 * Get total amount in queue that hasn't expired
 */
const getValidQueueBalance = (
	queue: AcquiredBalanceQueue,
	currentTimestamp: bigint,
	windowDuration: bigint
): bigint => {
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
const pruneExpiredEntries = (
	queue: AcquiredBalanceQueue,
	currentTimestamp: bigint,
	windowDuration: bigint
): void => {
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

/**
 * Build state for a subaccount from historical events using FIFO queue model
 *
 * Key Design:
 * - FIFO queues track (amount, originalTimestamp) for each token
 * - When swapping/depositing, consumed acquired tokens' timestamps are inherited
 * - Mixed acquired/non-acquired inputs are proportionally split in outputs
 * - Deposits store originalAcquisitionTimestamp so withdrawals inherit correctly
 */
const buildSubAccountState = (
	runtime: Runtime<Config>,
	events: ProtocolExecutionEvent[],
	transferEvents: TransferExecutedEvent[],
	subAccount: Address,
	currentTimestamp: bigint,
	subAccountWindowDuration?: bigint,
): SubAccountState => {
	// Use per-subaccount window duration if provided, otherwise fall back to config
	const windowDuration = subAccountWindowDuration ?? BigInt(runtime.config.windowDurationSeconds)
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

	runtime.log(`Processing ${unifiedEvents.length} events for ${subAccount} (FIFO mode, ${filteredProtocol.length} protocol + ${filteredTransfers.length} transfers)`)

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
					runtime.log(`  DEPOSIT: storing original acquisition timestamp ${originalAcquisitionTimestamp} for future withdrawal`)
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
			// For SWAPs and DEPOSITs: proportionally split output between acquired (inherited timestamp) and new (current timestamp)
			// For WITHDRAW/CLAIM: output matched to deposits inherits their original acquisition timestamp

			if (event.opType === OperationType.SWAP || event.opType === OperationType.DEPOSIT) {
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

						const opName = OperationType[event.opType]
						runtime.log(`  ${opName}: mixed input - ${totalConsumed} acquired + ${fromNonAcquired} non-acquired`)
						runtime.log(`    ${outputFromAcquired} ${event.tokenOut} inherits timestamp ${oldestTimestamp}`)
						runtime.log(`    ${outputFromNonAcquired} ${event.tokenOut} newly acquired at ${event.timestamp}`)

						addToQueue(outputQueue, outputFromAcquired, oldestTimestamp)
						addToQueue(outputQueue, outputFromNonAcquired, event.timestamp)
					} else if (totalConsumed > 0n) {
						// Entire input was acquired - output inherits oldest timestamp
						const oldestTimestamp = consumedEntries.reduce(
							(oldest, entry) => entry.originalTimestamp < oldest ? entry.originalTimestamp : oldest,
							consumedEntries[0].originalTimestamp
						)
						const opName = OperationType[event.opType]
						runtime.log(`  ${opName}: ${event.amountOut} ${event.tokenOut} inherits timestamp ${oldestTimestamp} from consumed acquired tokens`)
						addToQueue(outputQueue, event.amountOut, oldestTimestamp)
					} else {
						// No acquired input - output is newly acquired
						const opName = OperationType[event.opType]
						runtime.log(`  ${opName}: ${event.amountOut} ${event.tokenOut} is newly acquired at ${event.timestamp}`)
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

							runtime.log(`  ${OperationType[event.opType]} consuming ${consumeAmount} from deposit (original acquisition: ${deposit.originalAcquisitionTimestamp})`)
						}
					}

					const matchedAmount = event.amountOut - remainingToMatch
					if (matchedAmount > 0n) {
						tokensWithAcquiredHistory.add(tokenOutLower)
						const outputQueue = getQueue(tokenOutLower)

						// Withdrawal inherits the original acquisition timestamp (not deposit timestamp)
						const outputTimestamp = matchedOriginalTimestamp || event.timestamp
						runtime.log(`  ${OperationType[event.opType]} matched: ${matchedAmount} inherits original timestamp ${outputTimestamp}`)
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
			runtime.log(`  Token ${token}: acquired balance = ${validBalance}`)
		}
	}

	// Store queues in state for potential debugging
	state.acquiredQueues = acquiredQueues

	runtime.log(`State built: spending=${state.totalSpendingInWindow}, acquired tokens=${state.acquiredBalances.size}`)

	return state
}

/**
 * Calculate new spending allowance for a subaccount
 */
const calculateSpendingAllowance = (
	runtime: Runtime<Config>,
	subAccount: Address,
	state: SubAccountState,
): bigint => {
	const safeValue = getSafeValue(runtime)
	const { maxSpendingBps } = getSubAccountLimits(runtime, subAccount)

	// maxSpending = safeValue * maxSpendingBps / 10000
	const maxSpending = (safeValue * maxSpendingBps) / 10000n

	// newAllowance = maxSpending - spendingUsed
	const newAllowance = maxSpending > state.totalSpendingInWindow
		? maxSpending - state.totalSpendingInWindow
		: 0n

	runtime.log(`Allowance: safeValue=${safeValue}, maxBps=${maxSpendingBps}, max=${maxSpending}, spent=${state.totalSpendingInWindow}, new=${newAllowance}`)

	return newAllowance
}

/**
 * Get current on-chain spending allowance
 */
const getOnChainSpendingAllowance = (
	runtime: Runtime<Config>,
	subAccount: Address,
): bigint => {
	const evmClient = createEvmClient(runtime)

	const callData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'getSpendingAllowance',
		args: [subAccount],
	})

	try {
		const result = evmClient
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: runtime.config.moduleAddress as Address,
					data: callData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()

		if (!result.data || result.data.length === 0) {
			return 0n
		}

		return decodeFunctionResult({
			abi: DeFiInteractorModule,
			functionName: 'getSpendingAllowance',
			data: bytesToHex(result.data),
		})
	} catch (error) {
		runtime.log(`Error getting on-chain spending allowance: ${error}`)
		return 0n
	}
}

// Threshold for considering allowance values "equal" (0% tolerance for allowances)
const ALLOWANCE_CHANGE_THRESHOLD_BPS = 0n // 0%

/**
 * Push batch update to contract (skips if no changes)
 */
const pushBatchUpdate = (
	runtime: Runtime<Config>,
	subAccount: Address,
	newAllowance: bigint,
	acquiredBalances: Map<Address, bigint>,
): string | null => {
	const evmClient = createEvmClient(runtime)

	// Get current on-chain allowance
	const onChainAllowance = getOnChainSpendingAllowance(runtime, subAccount)

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
		const onChainBalance = getContractAcquiredBalance(runtime, subAccount, token)
		if (newBalance !== onChainBalance) {
			acquiredChanged = true
		}
		tokens.push(token)
		balances.push(newBalance)
	}

	// Also check for tokens that have on-chain balance but aren't in calculated map
	// These need to be cleared to 0 (e.g., tokens that aged out or had incorrect matching)
	const historicalTokens = queryHistoricalAcquiredTokens(runtime, subAccount)
	for (const token of historicalTokens) {
		if (!acquiredBalances.has(token)) {
			const onChainBalance = getContractAcquiredBalance(runtime, subAccount, token)
			if (onChainBalance > 0n) {
				runtime.log(`  Clearing stale acquired balance for ${token}: ${onChainBalance} -> 0`)
				acquiredChanged = true
				tokens.push(token)
				balances.push(0n)
			}
		}
	}

	// Skip if no changes
	if (!allowanceChanged && !acquiredChanged) {
		runtime.log(`Skipping batch update - no changes (allowance: ${onChainAllowance} -> ${newAllowance}, tokens: ${tokens.length})`)
		return null
	}

	runtime.log(`Pushing batch update: subAccount=${subAccount}, allowance=${newAllowance} (was ${onChainAllowance}), tokens=${tokens.length}`)

	const callData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'batchUpdate',
		args: [subAccount, newAllowance, tokens, balances],
	})

	const reportResponse = runtime
		.report({
			encodedPayload: hexToBase64(callData),
			encoderName: 'evm',
			signingAlgo: 'ecdsa',
			hashingAlgo: 'keccak256',
		})
		.result()

	const resp = evmClient
		.writeReport(runtime, {
			receiver: runtime.config.proxyAddress,
			report: reportResponse,
			gasConfig: {
				gasLimit: runtime.config.gasLimit,
			},
		})
		.result()

	if (resp.txStatus !== TxStatus.SUCCESS) {
		throw new Error(`Failed to push batch update: ${resp.errorMessage || resp.txStatus}`)
	}

	const txHash = bytesToHex(resp.txHash || new Uint8Array(32))
	runtime.log(`Batch update complete. TxHash: ${txHash}`)
	return txHash
}

// ============ Event Handler ============

/**
 * Handle ProtocolExecution event
 * Triggered on each new protocol interaction
 */
const onProtocolExecution = (runtime: Runtime<Config>, payload: any): string => {
	runtime.log('=== Spending Oracle: ProtocolExecution Event ===')

	try {
		const log = payload.log
		if (!log || !log.topics || log.topics.length < 3) {
			runtime.log('Invalid event log format')
			return 'Invalid event'
		}

		const newEvent = parseProtocolExecutionEvent(log)
		const currentTimestamp = getCurrentBlockTimestamp()

		runtime.log(`New event: ${OperationType[newEvent.opType]} by ${newEvent.subAccount}`)
		runtime.log(`  TokenIn: ${newEvent.tokenIn}, AmountIn: ${newEvent.amountIn}`)
		runtime.log(`  TokenOut: ${newEvent.tokenOut}, AmountOut: ${newEvent.amountOut}`)
		runtime.log(`  SpendingCost: ${newEvent.spendingCost}`)

		// Query historical events (both protocol executions and transfers)
		const historicalEvents = queryHistoricalEvents(runtime, newEvent.subAccount)
		const transferEvents = queryTransferEvents(runtime, newEvent.subAccount)

		// Add the new event (deduplicate by blockNumber + logIndex which uniquely identifies each log)
		const allEvents = [...historicalEvents]
		const isDuplicate = allEvents.some(e =>
			e.blockNumber === newEvent.blockNumber &&
			e.logIndex === newEvent.logIndex
		)
		if (!isDuplicate) {
			allEvents.push(newEvent)
		}

		// Get per-subaccount window duration
		const { windowDuration } = getSubAccountLimits(runtime, newEvent.subAccount)

		// Build state from all events using per-subaccount window duration
		const state = buildSubAccountState(runtime, allEvents, transferEvents, newEvent.subAccount, currentTimestamp, windowDuration)

		// Calculate new spending allowance
		const newAllowance = calculateSpendingAllowance(runtime, newEvent.subAccount, state)

		// Push update to contract
		const txHash = pushBatchUpdate(runtime, newEvent.subAccount, newAllowance, state.acquiredBalances)

		runtime.log(`=== Event Processing Complete ===`)
		return txHash || 'Skipped - no changes'
	} catch (error) {
		runtime.log(`Error processing event: ${error}`)
		return `Error: ${error}`
	}
}

// ============ Cron Handler ============

/**
 * Periodic refresh of spending allowances
 * Runs every 5 minutes to update allowances as old spending expires
 */
const onCronRefresh = (runtime: Runtime<Config>, _payload: CronPayload): string => {
	runtime.log('=== Spending Oracle: Periodic Refresh ===')

	try {
		const currentTimestamp = getCurrentBlockTimestamp()

		// Get all active subaccounts
		const subaccounts = getActiveSubaccounts(runtime)
		runtime.log(`Found ${subaccounts.length} active subaccounts`)

		if (subaccounts.length === 0) {
			runtime.log('No active subaccounts, skipping refresh')
			return 'No subaccounts'
		}

		// Query all historical events once (both protocol executions and transfers)
		const allEvents = queryHistoricalEvents(runtime)
		const allTransfers = queryTransferEvents(runtime)

		const results: string[] = []

		// Process each subaccount
		for (const subAccount of subaccounts) {
			try {
				runtime.log(`Processing subaccount: ${subAccount}`)

				// Get per-subaccount window duration
				const { windowDuration } = getSubAccountLimits(runtime, subAccount)

				// Build state for this subaccount using per-subaccount window duration
				const state = buildSubAccountState(runtime, allEvents, allTransfers, subAccount, currentTimestamp, windowDuration)

				// Calculate new spending allowance
				const newAllowance = calculateSpendingAllowance(runtime, subAccount, state)

				// Push update to contract
				const txHash = pushBatchUpdate(runtime, subAccount, newAllowance, state.acquiredBalances)
				results.push(`${subAccount}: ${txHash || 'Skipped'}`)
			} catch (error) {
				runtime.log(`Error processing ${subAccount}: ${error}`)
				results.push(`${subAccount}: Error - ${error}`)
			}
		}

		runtime.log(`=== Periodic Refresh Complete ===`)
		return results.join('; ')
	} catch (error) {
		runtime.log(`Error in periodic refresh: ${error}`)
		return `Error: ${error}`
	}
}

// ============ Transfer Event Handler ============

/**
 * Handle TransferExecuted event
 * Triggered on each token transfer from the Safe
 */
const onTransferExecuted = (runtime: Runtime<Config>, payload: any): string => {
	runtime.log('=== Spending Oracle: TransferExecuted Event ===')

	try {
		const log = payload.log
		if (!log || !log.topics || log.topics.length < 4) {
			runtime.log('Invalid transfer event log format')
			return 'Invalid event'
		}

		const newTransfer = parseTransferExecutedEvent(log)
		const currentTimestamp = getCurrentBlockTimestamp()

		runtime.log(`New transfer: ${newTransfer.amount} of ${newTransfer.token} to ${newTransfer.recipient}`)
		runtime.log(`  SpendingCost: ${newTransfer.spendingCost}`)

		// Query historical events (both protocol executions and transfers)
		const historicalEvents = queryHistoricalEvents(runtime, newTransfer.subAccount)
		const transferEvents = queryTransferEvents(runtime, newTransfer.subAccount)

		// Add the new transfer event (deduplicate by blockNumber + logIndex)
		const allTransfers = [...transferEvents]
		const isDuplicate = allTransfers.some(e =>
			e.blockNumber === newTransfer.blockNumber &&
			e.logIndex === newTransfer.logIndex
		)
		if (!isDuplicate) {
			allTransfers.push(newTransfer)
		}

		// Get per-subaccount window duration
		const { windowDuration } = getSubAccountLimits(runtime, newTransfer.subAccount)

		// Build state from all events using per-subaccount window duration
		const state = buildSubAccountState(runtime, historicalEvents, allTransfers, newTransfer.subAccount, currentTimestamp, windowDuration)

		// Calculate new spending allowance
		const newAllowance = calculateSpendingAllowance(runtime, newTransfer.subAccount, state)

		// Push update to contract
		const txHash = pushBatchUpdate(runtime, newTransfer.subAccount, newAllowance, state.acquiredBalances)

		runtime.log(`=== Transfer Event Processing Complete ===`)
		return txHash || 'Skipped - no changes'
	} catch (error) {
		runtime.log(`Error processing transfer event: ${error}`)
		return `Error: ${error}`
	}
}

// ============ Workflow Initialization ============

const initWorkflow = (config: Config) => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: config.chainSelectorName,
		isTestnet: config.chainSelectorName.includes('testnet') || config.chainSelectorName.includes('sepolia'),
	})

	if (!network) {
		throw new Error(`Network not found: ${config.chainSelectorName}`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)
	const cronTrigger = new cre.capabilities.CronCapability()

	return [
		// Event trigger: Process each ProtocolExecution event
		// logTrigger uses topics array where topics[0] contains event signatures
		cre.handler(
			evmClient.logTrigger({
				addresses: [config.moduleAddress],
				topics: [{ values: [PROTOCOL_EXECUTION_EVENT_SIG] }],
			}),
			onProtocolExecution,
		),
		// Event trigger: Process each TransferExecuted event
		cre.handler(
			evmClient.logTrigger({
				addresses: [config.moduleAddress],
				topics: [{ values: [TRANSFER_EXECUTED_EVENT_SIG] }],
			}),
			onTransferExecuted,
		),
		// Cron trigger: Periodic refresh of spending allowances
		cre.handler(
			cronTrigger.trigger({
				schedule: config.refreshSchedule,
			}),
			onCronRefresh,
		),
	]
}

export async function main() {
	const runner = await Runner.newRunner<Config>({
		configSchema,
	})
	await runner.run(initWorkflow)
}

main()
