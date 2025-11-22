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
	moduleAddress: string
	chainSelectorName: string
	gasLimit: string
	proxyAddress: string
	tokens: Array<z.infer<typeof TokenSchema>>
}

const configSchema = z.object({
	moduleAddress: z.string(),
	chainSelectorName: z.string(),
	gasLimit: z.string(),
	proxyAddress: z.string(),
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

// Common DeFi protocol ABIs for withdrawal detection
const AavePoolABI = [
	{
		inputs: [
			{ name: 'asset', type: 'address' },
			{ name: 'amount', type: 'uint256' },
			{ name: 'to', type: 'address' },
		],
		name: 'withdraw',
		outputs: [{ name: '', type: 'uint256' }],
		stateMutability: 'nonpayable',
		type: 'function',
	},
] as const

const MorphoVaultABI = [
	{
		inputs: [
			{ name: 'assets', type: 'uint256' },
			{ name: 'receiver', type: 'address' },
			{ name: 'owner', type: 'address' },
		],
		name: 'withdraw',
		outputs: [{ name: 'shares', type: 'uint256' }],
		stateMutability: 'nonpayable',
		type: 'function',
	},
	{
		inputs: [
			{ name: 'shares', type: 'uint256' },
			{ name: 'receiver', type: 'address' },
			{ name: 'owner', type: 'address' },
		],
		name: 'redeem',
		outputs: [{ name: 'assets', type: 'uint256' }],
		stateMutability: 'nonpayable',
		type: 'function',
	},
] as const

/**
 * Try to decode withdrawal data from transaction
 * Returns the amount in token's native decimals, or null if not a withdrawal
 */
const decodeWithdrawalAmount = (
	runtime: Runtime<Config>,
	txData: string,
): { amount: bigint; token: Address } | null => {
	try {
		// Get function selector (first 4 bytes)
		const selector = txData.slice(0, 10)

		runtime.log(`Transaction selector: ${selector}`)

		// Try Aave withdraw(address,uint256,address)
		if (selector === '0x69328dec') {
			runtime.log('Detected Aave withdraw function')
			// Decode the input parameters
			const params = txData.slice(10) // Remove selector
			const asset = ('0x' + params.slice(24, 64)) as Address
			const amount = BigInt('0x' + params.slice(64, 128))
			runtime.log(`Aave withdrawal: ${amount} of token ${asset}`)
			return { amount, token: asset }
		}

		// Try Morpho withdraw(uint256,address,address)
		if (selector === '0xb460af94') {
			runtime.log('Detected Morpho withdraw function')
			const params = txData.slice(10)
			const amount = BigInt('0x' + params.slice(0, 64))
			runtime.log(`Morpho withdrawal: ${amount}`)
			// For Morpho, we'd need to know which token the vault holds
			// This would come from config or a registry
			return null // TODO: Add vault token mapping
		}

		// Try Morpho redeem(uint256,address,address)
		if (selector === '0xba087652') {
			runtime.log('Detected Morpho redeem function')
			const params = txData.slice(10)
			const shares = BigInt('0x' + params.slice(0, 64))
			runtime.log(`Morpho redeem: ${shares} shares`)
			// Would need to convert shares to assets
			return null // TODO: Add shares conversion
		}

		runtime.log(`Unknown function selector: ${selector}`)
		return null
	} catch (error) {
		runtime.log(`Error decoding withdrawal: ${error}`)
		return null
	}
}

/**
 * Process a ProtocolExecuted event
 */
const onProtocolExecuted = (runtime: Runtime<Config>, payload: any): string => {
	runtime.log('ProtocolExecuted event received')

	try {
		// Decode the event log
		const log = payload.log
		const tx = payload.transaction // Get transaction data from payload

		if (!log || !log.topics || log.topics.length < 3) {
			runtime.log('Invalid event log format')
			return 'Invalid event log'
		}

		// Extract subAccount and target from indexed parameters
		const subAccount = ('0x' + log.topics[1].slice(-40)) as Address
		const target = ('0x' + log.topics[2].slice(-40)) as Address

		runtime.log(`Processing transaction for subAccount=${subAccount}, target=${target}`)

		// Get transaction data (the executeOnProtocol call contains the protocol call as a parameter)
		if (!tx || !tx.data) {
			runtime.log('No transaction data available')
			return 'No transaction data'
		}

		runtime.log(`Transaction data: ${tx.data}`)

		// The tx.data contains executeOnProtocol(target, data)
		// We need to extract the nested 'data' parameter which contains the actual withdrawal call
		// executeOnProtocol signature: executeOnProtocol(address,bytes)
		// Selector: first 4 bytes, then address (32 bytes), then bytes offset (32 bytes), then bytes length, then bytes data

		const txDataHex = tx.data as string
		if (txDataHex.length < 10) {
			runtime.log('Transaction data too short')
			return 'Invalid transaction'
		}

		// Skip executeOnProtocol selector (4 bytes = 8 hex chars + 0x)
		// Skip target address (32 bytes = 64 hex chars)
		// Skip bytes offset (32 bytes = 64 hex chars)
		// Skip bytes length (32 bytes = 64 hex chars)
		// Get the actual protocol calldata
		const dataOffset = 2 + 8 + 64 + 64 // 0x + selector + address + offset
		const lengthHex = txDataHex.slice(dataOffset, dataOffset + 64)
		const dataLength = Number.parseInt(lengthHex, 16) * 2 // Convert to hex chars

		const protocolCalldata = '0x' + txDataHex.slice(dataOffset + 64, dataOffset + 64 + dataLength)

		runtime.log(`Extracted protocol calldata: ${protocolCalldata}`)

		// Try to decode withdrawal
		const withdrawal = decodeWithdrawalAmount(runtime, protocolCalldata)

		if (!withdrawal) {
			runtime.log('Not a recognized withdrawal transaction')
			return 'Not a withdrawal'
		}

		runtime.log(`Detected withdrawal: ${withdrawal.amount} of token ${withdrawal.token}`)

		// Convert token amount to USD value
		const tokenConfig = runtime.config.tokens.find((t) => t.address.toLowerCase() === withdrawal.token.toLowerCase())

		if (!tokenConfig) {
			runtime.log(`Token ${withdrawal.token} not in config, cannot calculate USD value`)
			return 'Token not configured'
		}

		// Get price from Chainlink
		const { price, decimals: priceDecimals } = getPriceFromFeed(runtime, tokenConfig.priceFeedAddress)

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
					to: withdrawal.token,
					data: decimalsCallData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()

		if (!decimalsCall.data || decimalsCall.data.length === 0) {
			throw new Error(`Failed to get decimals for token ${withdrawal.token}`)
		}

		const tokenDecimals = decodeFunctionResult({
			abi: ERC20ABI,
			functionName: 'decimals',
			data: bytesToHex(decimalsCall.data),
		})

		// Calculate USD value: (amount * price * 10^18) / (10^tokenDecimals * 10^priceDecimals)
		const balanceChange = (withdrawal.amount * price * BigInt(10 ** 18)) / BigInt(10 ** (tokenDecimals + priceDecimals))

		runtime.log(`Withdrawal value in USD: ${balanceChange} (${Number(balanceChange) / 1e18} USD)`)

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
			return `Failed: ${resp.errorMessage || txStatus}`
		} else {
			const txHash = resp.txHash || new Uint8Array(32)
			runtime.log(`Successfully updated allowances for ${subAccount}. TxHash: ${bytesToHex(txHash)}`)
			return `Success: Updated allowances for ${subAccount}, amount: ${balanceChange}`
		}
	} catch (error) {
		runtime.log(`Error processing event: ${error}`)
		return `Error: ${error}`
	}
}

const initWorkflow = (config: Config) => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: config.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chain selector name: ${config.chainSelectorName}`)
	}

	// TODO: EVM Log Trigger for TypeScript SDK (No EVMLogTriggerCapability) 
	// the Go documentation: https://docs.chain.link/cre/guides/workflow/using-triggers/evm-log-trigger-go
	//
	// const logTrigger = new cre.capabilities.EVMLogTriggerCapability({
	//   chainSelector: network.chainSelector.selector,
	//   addresses: [config.moduleAddress],
	//   topics: [keccak256(toHex('ProtocolExecuted(address,address,uint256)'))],
	// })
	// return [cre.handler(logTrigger.trigger({}), onProtocolExecuted)]

	throw new Error('EVMLogTriggerCapability not yet available in TypeScript CRE SDK. Please check Chainlink documentation for updates.')
}

export async function main() {
	const runner = await Runner.newRunner<Config>({
		configSchema,
	})
	await runner.run(initWorkflow)
}

main()
