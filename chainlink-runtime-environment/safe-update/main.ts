import {
	bytesToHex,
	cre,
	encodeCallMsg,
	getNetwork,
	hexToBase64,
	LAST_FINALIZED_BLOCK_NUMBER,
	Runner,
	type Runtime,
	TxStatus,
} from '@chainlink/cre-sdk'
import { type Address, decodeFunctionResult, encodeFunctionData, keccak256, toHex, zeroAddress } from 'viem'
import { z } from 'zod'
import { DeFiInteractorModule } from '../contracts/abi'

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

// ERC20 ABI
const ERC20ABI = [
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

const TokenSchema = z.object({
	address: z.string(),
	priceFeedAddress: z.string(),
	symbol: z.string(),
	type: z.enum(['erc20', 'aave', 'morpho']),
})

type Config = {
	schedule: string
	moduleAddress: string
	chainSelectorName: string
	gasLimit: string
	proxyAddress: string
	lookbackBlocks: string
	tokens: Array<z.infer<typeof TokenSchema>>
}

const configSchema = z.object({
	schedule: z.string(),
	moduleAddress: z.string(),
	chainSelectorName: z.string(),
	gasLimit: z.string(),
	proxyAddress: z.string(),
	lookbackBlocks: z.string(),
	tokens: z.array(TokenSchema),
})

/**
 * Get price from Chainlink price feed
 */
const getPriceFromFeed = (
	runtime: Runtime<Config>,
	priceFeedAddress: string,
): { price: bigint; decimals: number } => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: runtime.config.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	// Get latest price
	const priceCallData = encodeFunctionData({
		abi: ChainlinkPriceFeedABI,
		functionName: 'latestRoundData',
	})

	let priceCall
	try {
		priceCall = evmClient
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: priceFeedAddress as Address,
					data: priceCallData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()
	} catch (error) {
		runtime.log(`Error calling latestRoundData() on price feed ${priceFeedAddress}: ${error}`)
		throw new Error(`Failed to get price from feed ${priceFeedAddress}: ${error}`)
	}

	if (!priceCall.data || priceCall.data.length === 0) {
		throw new Error(`Empty response when calling latestRoundData() on price feed ${priceFeedAddress}`)
	}

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

	let decimalsCall
	try {
		decimalsCall = evmClient
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: priceFeedAddress as Address,
					data: decimalsCallData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()
	} catch (error) {
		runtime.log(`Error calling decimals() on price feed ${priceFeedAddress}: ${error}`)
		throw new Error(`Failed to get decimals from price feed ${priceFeedAddress}: ${error}`)
	}

	if (!decimalsCall.data || decimalsCall.data.length === 0) {
		throw new Error(`Empty response when calling decimals() on price feed ${priceFeedAddress}`)
	}

	const decimals = decodeFunctionResult({
		abi: ChainlinkPriceFeedABI,
		functionName: 'decimals',
		data: bytesToHex(decimalsCall.data),
	})

	return { price: BigInt(answer), decimals }
}

/**
 * Get Safe's token balance
 */
const getTokenBalance = (runtime: Runtime<Config>, tokenAddress: string, safeAddress: string): bigint => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: runtime.config.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	const balanceCallData = encodeFunctionData({
		abi: ERC20ABI,
		functionName: 'balanceOf',
		args: [safeAddress as Address],
	})

	const balanceCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: tokenAddress as Address,
				data: balanceCallData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	if (!balanceCall.data || balanceCall.data.length === 0) {
		throw new Error(`Empty response when calling balanceOf() on token ${tokenAddress}`)
	}

	const balance = decodeFunctionResult({
		abi: ERC20ABI,
		functionName: 'balanceOf',
		data: bytesToHex(balanceCall.data),
	})

	return balance
}

/**
 * Calculate total Safe value in USD
 */
const calculateSafeValueUSD = (runtime: Runtime<Config>, safeAddress: string): bigint => {
	let totalValueUSD = 0n

	for (const token of runtime.config.tokens) {
		try {
			// Get token balance
			const balance = getTokenBalance(runtime, token.address, safeAddress)

			if (balance === 0n) {
				continue
			}

			// Get price from Chainlink
			const { price, decimals: priceDecimals } = getPriceFromFeed(runtime, token.priceFeedAddress)

			// Get token decimals
			const network = getNetwork({
				chainFamily: 'evm',
				chainSelectorName: runtime.config.chainSelectorName,
				isTestnet: true,
			})

			if (!network) {
				throw new Error(`Network not found`)
			}

			const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

			const decimalsCallData = encodeFunctionData({
				abi: ERC20ABI,
				functionName: 'decimals',
			})

			const decimalsCall = evmClient
				.callContract(runtime, {
					call: encodeCallMsg({
						from: zeroAddress,
						to: token.address as Address,
						data: decimalsCallData,
					}),
					blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
				})
				.result()

			if (!decimalsCall.data || decimalsCall.data.length === 0) {
				throw new Error(`Empty response when calling decimals() on token ${token.address}`)
			}

			const tokenDecimals = decodeFunctionResult({
				abi: ERC20ABI,
				functionName: 'decimals',
				data: bytesToHex(decimalsCall.data),
			})

			// Calculate USD value: (balance * price * 10^18) / (10^tokenDecimals * 10^priceDecimals)
			const valueUSD = (balance * price * BigInt(10 ** 18)) / BigInt(10 ** (tokenDecimals + priceDecimals))

			totalValueUSD += valueUSD

			runtime.log(
				`Token ${token.symbol}: balance=${balance}, price=${price}, decimals=${tokenDecimals}, value=${valueUSD}`,
			)
		} catch (error) {
			runtime.log(`Error calculating value for token ${token.symbol}: ${error}`)
		}
	}

	return totalValueUSD
}

/**
 * Check for ProtocolExecuted events and process withdrawals
 */
const processProtocolExecutions = (runtime: Runtime<Config>): void => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: runtime.config.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	// For now, we'll use a simpler approach - check recent blocks
	// The actual block number will be determined by LAST_FINALIZED_BLOCK_NUMBER
	const fromBlock = BigInt(0) // We'll fetch all historical events for now
	const currentBlock = LAST_FINALIZED_BLOCK_NUMBER

	runtime.log(`Checking for ProtocolExecuted events from block ${fromBlock} to ${currentBlock}`)

	// Get the Safe address
	const avatarCallData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'avatar',
	})

	const avatarCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: runtime.config.moduleAddress as Address,
				data: avatarCallData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	if (!avatarCall.data || avatarCall.data.length === 0) {
		throw new Error(`Failed to get Safe address from module`)
	}

	const safeAddress = decodeFunctionResult({
		abi: DeFiInteractorModule,
		functionName: 'avatar',
		data: bytesToHex(avatarCall.data),
	})

	runtime.log(`Safe address: ${safeAddress}`)

	// Calculate the event signature for ProtocolExecuted
	const eventSignature = keccak256(toHex('ProtocolExecuted(address,address,uint256)'))

	runtime.log(`Event signature: ${eventSignature}`)

	// TODO: The CRE SDK may not have getLogs exposed yet
	// For now, we'll implement a simplified version that processes all recent events
	// In production, you'll need to use the proper CRE SDK method to fetch logs

	// Placeholder: assume we got some logs
	const logs: any[] = []

	runtime.log(`Found ${logs.length} ProtocolExecuted events`)

	if (logs.length === 0) {
		runtime.log('No withdrawals detected')
		return
	}

	// Process each event
	for (const log of logs) {
		try {
			// Decode the event data
			if (!log.topics || log.topics.length < 3) {
				runtime.log('Invalid log topics')
				continue
			}

			const subAccount = ('0x' + log.topics[1].slice(-40)) as Address
			const target = ('0x' + log.topics[2].slice(-40)) as Address

			runtime.log(`Processing ProtocolExecuted event: subAccount=${subAccount}, target=${target}`)

			// Calculate the Safe's current value
			const currentSafeValue = calculateSafeValueUSD(runtime, safeAddress)

			runtime.log(`Current Safe value: ${currentSafeValue}`)

			// Get previous Safe value from the module
			const getSafeValueCallData = encodeFunctionData({
				abi: DeFiInteractorModule,
				functionName: 'getSafeValue',
			})

			const getSafeValueCall = evmClient
				.callContract(runtime, {
					call: encodeCallMsg({
						from: zeroAddress,
						to: runtime.config.moduleAddress as Address,
						data: getSafeValueCallData,
					}),
					blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
				})
				.result()

			if (!getSafeValueCall.data || getSafeValueCall.data.length === 0) {
				runtime.log('Failed to get previous Safe value')
				continue
			}

			const [previousSafeValue] = decodeFunctionResult({
				abi: DeFiInteractorModule,
				functionName: 'getSafeValue',
				data: bytesToHex(getSafeValueCall.data),
			})

			runtime.log(`Previous Safe value: ${previousSafeValue}`)

			// Check if this is a withdrawal (Safe value increased)
			if (currentSafeValue > previousSafeValue) {
				const balanceChange = currentSafeValue - previousSafeValue

				runtime.log(`Detected withdrawal! Balance change: +${balanceChange}`)

				// Call updateSubaccountAllowances
				const callData = encodeFunctionData({
					abi: DeFiInteractorModule,
					functionName: 'updateSubaccountAllowances',
					args: [subAccount, balanceChange],
				})

				runtime.log(`Calling updateSubaccountAllowances for ${subAccount} with balanceChange=${balanceChange}`)

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
						receiver: runtime.config.proxyAddress,
						report: reportResponse,
						gasConfig: {
							gasLimit: runtime.config.gasLimit,
						},
					})
					.result()

				const txStatus = resp.txStatus

				if (txStatus !== TxStatus.SUCCESS) {
					runtime.log(`Failed to update allowances: ${resp.errorMessage || txStatus}`)
				} else {
					const txHash = resp.txHash || new Uint8Array(32)
					runtime.log(`Successfully updated allowances for ${subAccount}. TxHash: ${bytesToHex(txHash)}`)
				}
			} else {
				runtime.log(`No withdrawal detected (value decreased or stayed same)`)
			}
		} catch (error) {
			runtime.log(`Error processing event: ${error}`)
		}
	}
}

const onCronTrigger = (runtime: Runtime<Config>): string => {
	runtime.log('Safe withdrawal monitor triggered')

	try {
		processProtocolExecutions(runtime)
		return 'Withdrawal monitoring completed'
	} catch (error) {
		runtime.log(`Error in workflow: ${error}`)
		return `Workflow failed: ${error}`
	}
}

const initWorkflow = (config: Config) => {
	const cron = new cre.capabilities.CronCapability()

	return [cre.handler(cron.trigger({ schedule: config.schedule }), onCronTrigger)]
}

export async function main() {
	const runner = await Runner.newRunner<Config>({
		configSchema,
	})
	await runner.run(initWorkflow)
}

main()
