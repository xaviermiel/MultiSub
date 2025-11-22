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
import { type Address, decodeFunctionResult, encodeFunctionData, zeroAddress } from 'viem'
import { z } from 'zod'
import { DeFiInteractorModule } from '../contracts/abi'

// ERC20 with decimals
const ERC20WithDecimals = [
	{
		inputs: [{ name: 'account', type: 'address', internalType: 'address' }],
		name: 'balanceOf',
		outputs: [{ name: '', type: 'uint256', internalType: 'uint256' }],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'decimals',
		outputs: [{ name: '', type: 'uint8', internalType: 'uint8' }],
		stateMutability: 'view',
		type: 'function',
	},
] as const

// Chainlink Price Feed ABI (minimal)
const ChainlinkPriceFeedABI = [
	{
		inputs: [],
		name: 'latestRoundData',
		outputs: [
			{ name: 'roundId', type: 'uint80' },
			{ name: 'answer', type: 'int256' },
			{ name: 'startedAt', type: 'uint256' },
			{ name: 'updatedAt', type: 'uint256' },
			{ name: 'answeredInRound', type: 'uint80' },
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'decimals',
		outputs: [{ name: '', type: 'uint8' }],
		stateMutability: 'view',
		type: 'function',
	},
] as const

const configSchema = z.object({
	schedule: z.string(), // Cron schedule (e.g., "*/30 * * * * *" for every 30 seconds)
	moduleAddress: z.string(), // DeFiInteractorModule contract address (which monitors its avatar Safe)
	chainSelectorName: z.string(), // e.g., "ethereum-testnet-sepolia"
	gasLimit: z.string(),
	proxyAddress: z.string(), // Chainlink CRE proxy for signed reports
	tokens: z.array(
		z.object({
			address: z.string(), // Token contract address
			priceFeedAddress: z.string(), // Chainlink price feed for this token
			symbol: z.string(), // Token symbol for logging
		}),
	),
})

type Config = z.infer<typeof configSchema>

interface TokenBalance {
	tokenAddress: string
	symbol: string
	balance: bigint
	priceUSD: bigint // Price with 8 decimals from Chainlink
	decimals: number
}

interface SafeValueData {
	totalValueUSD: bigint // Total value with 18 decimals
	tokens: TokenBalance[]
	timestamp: number
}

// Utility function to safely stringify objects with bigints
const safeJsonStringify = (obj: any): string =>
	JSON.stringify(obj, (_, value) => (typeof value === 'bigint' ? value.toString() : value), 2)

/**
 * Get the Safe address from the DeFiInteractorModule's avatar() function
 */
const getSafeAddress = (runtime: Runtime<Config>): string => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: runtime.config.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chain selector name: ${runtime.config.chainSelectorName}`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	const callData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'avatar',
	})

	const contractCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: runtime.config.moduleAddress as Address,
				data: callData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	const safeAddress = decodeFunctionResult({
		abi: DeFiInteractorModule,
		functionName: 'avatar',
		data: bytesToHex(contractCall.data),
	})

	return safeAddress
}

/**
 * Get the balance of a specific token for an address
 */
const getTokenBalance = (
	runtime: Runtime<Config>,
	tokenAddress: string,
	holderAddress: string,
	chainSelectorName: string,
): bigint => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chain selector name: ${chainSelectorName}`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	const callData = encodeFunctionData({
		abi: ERC20WithDecimals,
		functionName: 'balanceOf',
		args: [holderAddress as Address],
	})

	const contractCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: tokenAddress as Address,
				data: callData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	const balance = decodeFunctionResult({
		abi: ERC20WithDecimals,
		functionName: 'balanceOf',
		data: bytesToHex(contractCall.data),
	})

	return balance
}

/**
 * Get the number of decimals for a token
 */
const getTokenDecimals = (
	runtime: Runtime<Config>,
	tokenAddress: string,
	chainSelectorName: string,
): number => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chain selector name: ${chainSelectorName}`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	const callData = encodeFunctionData({
		abi: ERC20WithDecimals,
		functionName: 'decimals',
	})

	const contractCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: tokenAddress as Address,
				data: callData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	const decimals = decodeFunctionResult({
		abi: ERC20WithDecimals,
		functionName: 'decimals',
		data: bytesToHex(contractCall.data),
	})

	return Number(decimals)
}

/**
 * Get the USD price from a Chainlink price feed
 */
const getChainlinkPrice = (
	runtime: Runtime<Config>,
	priceFeedAddress: string,
	chainSelectorName: string,
): { price: bigint; decimals: number } => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chain selector name: ${chainSelectorName}`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	// Get price
	const priceCallData = encodeFunctionData({
		abi: ChainlinkPriceFeedABI,
		functionName: 'latestRoundData',
	})

	const priceCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: priceFeedAddress as Address,
				data: priceCallData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	const [, answer] = decodeFunctionResult({
		abi: ChainlinkPriceFeedABI,
		functionName: 'latestRoundData',
		data: bytesToHex(priceCall.data),
	})

	// Get decimals
	const decimalsCallData = encodeFunctionData({
		abi: ChainlinkPriceFeedABI,
		functionName: 'decimals',
	})

	const decimalsCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: priceFeedAddress as Address,
				data: decimalsCallData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	const decimals = decodeFunctionResult({
		abi: ChainlinkPriceFeedABI,
		functionName: 'decimals',
		data: bytesToHex(decimalsCall.data),
	})

	return { price: BigInt(answer), decimals }
}

/**
 * Calculate the total USD value of all tokens in the Safe
 */
const calculateSafeValue = (runtime: Runtime<Config>): SafeValueData => {
	const config = runtime.config
	const tokens: TokenBalance[] = []
	let totalValueUSD = 0n

	// Get the Safe address from the module
	const safeAddress = getSafeAddress(runtime)
	runtime.log(`Monitoring Safe: ${safeAddress}`)

	for (const tokenConfig of config.tokens) {
		runtime.log(`Processing token: ${tokenConfig.symbol} (${tokenConfig.address})`)

		// Get token balance
		const balance = getTokenBalance(
			runtime,
			tokenConfig.address,
			safeAddress,
			config.chainSelectorName,
		)

		// Get token decimals
		const decimals = getTokenDecimals(runtime, tokenConfig.address, config.chainSelectorName)

		// Get USD price from Chainlink
		const { price: priceUSD, decimals: priceDecimals } = getChainlinkPrice(
			runtime,
			tokenConfig.priceFeedAddress,
			config.chainSelectorName,
		)

		runtime.log(
			`${tokenConfig.symbol}: balance=${balance.toString()}, decimals=${decimals}, price=${priceUSD.toString()} (${priceDecimals} decimals)`,
		)

		// Calculate USD value for this token
		// Formula: (balance * priceUSD) / (10^tokenDecimals) * (10^18) / (10^priceDecimals)
		// Simplify to: (balance * priceUSD * 10^18) / (10^tokenDecimals * 10^priceDecimals)
		const valueUSD = (balance * priceUSD * BigInt(10 ** 18)) / BigInt(10 ** decimals) / BigInt(10 ** priceDecimals)

		totalValueUSD += valueUSD

		tokens.push({
			tokenAddress: tokenConfig.address,
			symbol: tokenConfig.symbol,
			balance,
			priceUSD,
			decimals,
		})
	}

	return {
		totalValueUSD,
		tokens,
		timestamp: Date.now(),
	}
}

/**
 * Write the Safe value to the on-chain storage contract
 */
const writeSafeValueToChain = (runtime: Runtime<Config>, safeValueData: SafeValueData): string => {
	const config = runtime.config
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: config.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chain selector name: ${config.chainSelectorName}`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	runtime.log(
		`Writing Safe value to chain: ${safeValueData.totalValueUSD.toString()} (${(Number(safeValueData.totalValueUSD) / 1e18).toFixed(2)} USD)`,
	)

	// Encode the contract call data for updateSafeValue (no safeAddress needed, module knows its own Safe)
	const callData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'updateSafeValue',
		args: [safeValueData.totalValueUSD],
	})

	// Generate report using consensus capability
	const reportResponse = runtime
		.report({
			encodedPayload: hexToBase64(callData),
			encoderName: 'evm',
			signingAlgo: 'ecdsa',
			hashingAlgo: 'keccak256',
		})
		.result()

	// Write report to chain
	const resp = evmClient
		.writeReport(runtime, {
			receiver: config.proxyAddress,
			report: reportResponse,
			gasConfig: {
				gasLimit: config.gasLimit,
			},
		})
		.result()

	const txStatus = resp.txStatus

	if (txStatus !== TxStatus.SUCCESS) {
		throw new Error(`Failed to write report: ${resp.errorMessage || txStatus}`)
	}

	const txHash = resp.txHash || new Uint8Array(32)

	runtime.log(`Safe value updated on-chain. TxHash: ${bytesToHex(txHash)}`)

	return bytesToHex(txHash)
}

/**
 * Main cron handler - runs every 30 seconds
 */
const onCronTrigger = (runtime: Runtime<Config>, payload: CronPayload): string => {
	if (!payload.scheduledExecutionTime) {
		throw new Error('Scheduled execution time is required')
	}

	runtime.log('=== Safe Value Monitor: Starting check ===')
	runtime.log(`Module Address: ${runtime.config.moduleAddress}`)
	runtime.log(`Timestamp: ${new Date().toISOString()}`)

	// Calculate Safe value
	const safeValueData = calculateSafeValue(runtime)

	runtime.log('=== Safe Value Calculation ===')
	runtime.log(safeJsonStringify(safeValueData))
	runtime.log(`Total USD Value: $${(Number(safeValueData.totalValueUSD) / 1e18).toFixed(2)}`)

	// Write to chain
	const txHash = writeSafeValueToChain(runtime, safeValueData)

	runtime.log('=== Safe Value Monitor: Complete ===')

	return txHash
}

/**
 * Initialize the workflow
 */
const initWorkflow = (config: Config) => {
	const cronTrigger = new cre.capabilities.CronCapability()

	return [
		cre.handler(
			cronTrigger.trigger({
				schedule: config.schedule,
			}),
			onCronTrigger,
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
