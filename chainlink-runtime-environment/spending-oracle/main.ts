/**
 * Spending Oracle for DeFiInteractorModule
 *
 * Implements the Acquired Balance Model with:
 * - Rolling 24h window tracking for spending
 * - Deposit/withdrawal matching for acquired status
 * - 24h expiry for acquired balances
 * - Periodic allowance refresh via cron trigger
 *
 * State Management:
 * Since CRE workflows are stateless, we query historical events from the chain
 * to reconstruct state on each invocation. This ensures verifiable, decentralized
 * state derivation.
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
	decodeEventLog,
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
	refreshSchedule: z.string().default('*/5 * * * *'),
	// Window duration in seconds (default 24 hours)
	windowDurationSeconds: z.number().default(86400),
	// How many blocks to look back for events (approximate 24h worth)
	// Ethereum: ~7200 blocks/day, Arbitrum: ~300000 blocks/day
	blocksToLookBack: z.number().default(7200),
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
}

interface DepositRecord {
	subAccount: Address
	target: Address
	tokenIn: Address
	amountIn: bigint
	timestamp: bigint
}

interface AcquiredRecord {
	token: Address
	amount: bigint
	timestamp: bigint
}

interface SpendingRecord {
	amount: bigint // USD value
	timestamp: bigint
}

interface SubAccountState {
	spendingRecords: SpendingRecord[]
	depositRecords: DepositRecord[]
	acquiredRecords: Map<Address, AcquiredRecord[]>
	totalSpendingInWindow: bigint
	acquiredBalances: Map<Address, bigint>
}

// ============ Event Signature ============

const PROTOCOL_EXECUTION_EVENT_SIG = keccak256(
	toHex('ProtocolExecution(address,address,uint8,address,uint256,address,uint256,uint256,uint256)')
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

/**
 * Get current block timestamp
 */
const getCurrentBlockTimestamp = (runtime: Runtime<Config>): bigint => {
	// Use current time as approximation
	return BigInt(Math.floor(Date.now() / 1000))
}

/**
 * Get subaccount's spending limits from contract
 */
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
		// Query logs from the module address
		const logsResult = evmClient
			.getLogs(runtime, {
				address: runtime.config.moduleAddress as Address,
				topics: subAccount
					? [PROTOCOL_EXECUTION_EVENT_SIG, `0x000000000000000000000000${subAccount.slice(2)}`]
					: [PROTOCOL_EXECUTION_EVENT_SIG],
				fromBlock: `0x${(BigInt(LAST_FINALIZED_BLOCK_NUMBER) - BigInt(runtime.config.blocksToLookBack)).toString(16)}`,
				toBlock: LAST_FINALIZED_BLOCK_NUMBER,
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
 * Parse ProtocolExecution event from log data
 */
const parseProtocolExecutionEvent = (log: any): ProtocolExecutionEvent => {
	const subAccount = ('0x' + log.topics[1].slice(-40)) as Address
	const target = ('0x' + log.topics[2].slice(-40)) as Address

	const decoded = decodeAbiParameters(
		[
			{ name: 'opType', type: 'uint8' },
			{ name: 'tokenIn', type: 'address' },
			{ name: 'amountIn', type: 'uint256' },
			{ name: 'tokenOut', type: 'address' },
			{ name: 'amountOut', type: 'uint256' },
			{ name: 'spendingCost', type: 'uint256' },
			{ name: 'timestamp', type: 'uint256' },
		],
		log.data as `0x${string}`,
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
		timestamp: decoded[6],
		blockNumber: BigInt(log.blockNumber || 0),
	}
}

/**
 * Build state for a subaccount from historical events
 */
const buildSubAccountState = (
	runtime: Runtime<Config>,
	events: ProtocolExecutionEvent[],
	subAccount: Address,
	currentTimestamp: bigint,
): SubAccountState => {
	const windowDuration = BigInt(runtime.config.windowDurationSeconds)
	const windowStart = currentTimestamp - windowDuration

	const state: SubAccountState = {
		spendingRecords: [],
		depositRecords: [],
		acquiredRecords: new Map(),
		totalSpendingInWindow: 0n,
		acquiredBalances: new Map(),
	}

	// Filter events for this subaccount within the window
	const relevantEvents = events
		.filter(e => e.subAccount.toLowerCase() === subAccount.toLowerCase())
		.filter(e => e.timestamp >= windowStart)
		.sort((a, b) => Number(a.timestamp - b.timestamp))

	runtime.log(`Processing ${relevantEvents.length} events for ${subAccount} in window`)

	for (const event of relevantEvents) {
		// Track spending (SWAP and DEPOSIT cost spending)
		if (event.opType === OperationType.SWAP || event.opType === OperationType.DEPOSIT) {
			if (event.spendingCost > 0n) {
				state.spendingRecords.push({
					amount: event.spendingCost,
					timestamp: event.timestamp,
				})
				state.totalSpendingInWindow += event.spendingCost
			}
		}

		// Track deposits for withdrawal matching
		if (event.opType === OperationType.DEPOSIT) {
			state.depositRecords.push({
				subAccount: event.subAccount,
				target: event.target,
				tokenIn: event.tokenIn,
				amountIn: event.amountIn,
				timestamp: event.timestamp,
			})
		}

		// Track acquired balances
		let acquiredAmount = 0n
		let acquiredToken: Address | null = null

		if (event.opType === OperationType.SWAP) {
			// SWAP: Output token becomes acquired
			if (event.tokenOut !== zeroAddress && event.amountOut > 0n) {
				acquiredToken = event.tokenOut
				acquiredAmount = event.amountOut
			}
		} else if (event.opType === OperationType.WITHDRAW) {
			// WITHDRAW: Only acquired if matched to deposit by same subaccount
			if (event.tokenOut !== zeroAddress && event.amountOut > 0n) {
				const hasMatchingDeposit = state.depositRecords.some(
					d => d.target.toLowerCase() === event.target.toLowerCase() &&
						d.subAccount.toLowerCase() === event.subAccount.toLowerCase()
				)

				if (hasMatchingDeposit) {
					acquiredToken = event.tokenOut
					acquiredAmount = event.amountOut
					runtime.log(`Withdrawal matched to deposit: ${event.amountOut} of ${event.tokenOut}`)
				} else {
					runtime.log(`Withdrawal NOT matched (no deposit found): ${event.amountOut} of ${event.tokenOut}`)
				}
			}
		} else if (event.opType === OperationType.CLAIM) {
			// CLAIM: Acquired if from subaccount's transaction in window
			// Since we're only processing this subaccount's events, claims are acquired
			if (event.tokenOut !== zeroAddress && event.amountOut > 0n) {
				acquiredToken = event.tokenOut
				acquiredAmount = event.amountOut
			}
		}

		// Add to acquired records
		if (acquiredToken && acquiredAmount > 0n) {
			if (!state.acquiredRecords.has(acquiredToken)) {
				state.acquiredRecords.set(acquiredToken, [])
			}
			state.acquiredRecords.get(acquiredToken)!.push({
				token: acquiredToken,
				amount: acquiredAmount,
				timestamp: event.timestamp,
			})
		}
	}

	// Calculate total acquired balances (sum of all records still in window)
	for (const [token, records] of state.acquiredRecords) {
		const validRecords = records.filter(r => r.timestamp >= windowStart)
		const total = validRecords.reduce((sum, r) => sum + r.amount, 0n)
		state.acquiredBalances.set(token, total)
	}

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

	runtime.log(`Allowance calculation: safeValue=${safeValue}, maxBps=${maxSpendingBps}, maxSpending=${maxSpending}, spent=${state.totalSpendingInWindow}, newAllowance=${newAllowance}`)

	return newAllowance
}

/**
 * Push batch update to contract
 */
const pushBatchUpdate = (
	runtime: Runtime<Config>,
	subAccount: Address,
	newAllowance: bigint,
	acquiredBalances: Map<Address, bigint>,
): string => {
	const evmClient = createEvmClient(runtime)

	const tokens: Address[] = []
	const balances: bigint[] = []

	for (const [token, balance] of acquiredBalances) {
		tokens.push(token)
		balances.push(balance)
	}

	runtime.log(`Pushing batch update: subAccount=${subAccount}, allowance=${newAllowance}, tokens=${tokens.length}`)

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

		// Parse the new event
		const newEvent = parseProtocolExecutionEvent(log)
		const currentTimestamp = getCurrentBlockTimestamp(runtime)

		runtime.log(`New event: ${OperationType[newEvent.opType]} by ${newEvent.subAccount}`)
		runtime.log(`  TokenIn: ${newEvent.tokenIn}, AmountIn: ${newEvent.amountIn}`)
		runtime.log(`  TokenOut: ${newEvent.tokenOut}, AmountOut: ${newEvent.amountOut}`)
		runtime.log(`  SpendingCost: ${newEvent.spendingCost}`)

		// Query historical events
		const historicalEvents = queryHistoricalEvents(runtime, newEvent.subAccount)

		// Add the new event (it may not be in historical query yet)
		const allEvents = [...historicalEvents]
		if (!allEvents.some(e => e.timestamp === newEvent.timestamp && e.target === newEvent.target)) {
			allEvents.push(newEvent)
		}

		// Build state from all events
		const state = buildSubAccountState(runtime, allEvents, newEvent.subAccount, currentTimestamp)

		// Calculate new spending allowance
		const newAllowance = calculateSpendingAllowance(runtime, newEvent.subAccount, state)

		// Push update to contract
		const txHash = pushBatchUpdate(runtime, newEvent.subAccount, newAllowance, state.acquiredBalances)

		runtime.log(`=== Event Processing Complete ===`)
		return txHash
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
const onCronRefresh = (runtime: Runtime<Config>, payload: CronPayload): string => {
	runtime.log('=== Spending Oracle: Periodic Refresh ===')

	try {
		const currentTimestamp = getCurrentBlockTimestamp(runtime)

		// Get all active subaccounts
		const subaccounts = getActiveSubaccounts(runtime)
		runtime.log(`Found ${subaccounts.length} active subaccounts`)

		if (subaccounts.length === 0) {
			runtime.log('No active subaccounts, skipping refresh')
			return 'No subaccounts'
		}

		// Query all historical events once
		const allEvents = queryHistoricalEvents(runtime)

		const results: string[] = []

		// Process each subaccount
		for (const subAccount of subaccounts) {
			try {
				runtime.log(`Processing subaccount: ${subAccount}`)

				// Build state for this subaccount
				const state = buildSubAccountState(runtime, allEvents, subAccount, currentTimestamp)

				// Calculate new spending allowance
				const newAllowance = calculateSpendingAllowance(runtime, subAccount, state)

				// Push update to contract
				const txHash = pushBatchUpdate(runtime, subAccount, newAllowance, state.acquiredBalances)
				results.push(`${subAccount}: ${txHash}`)
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
		cre.handler(
			evmClient.logTrigger({
				addresses: [config.moduleAddress],
				eventSignatures: [PROTOCOL_EXECUTION_EVENT_SIG],
			}),
			onProtocolExecution,
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
