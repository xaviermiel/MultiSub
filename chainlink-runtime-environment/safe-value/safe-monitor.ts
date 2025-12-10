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

// Aave aToken ABI (inherits ERC20 but has exchangeRate functionality)
const AaveATokenABI = [
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

// Morpho Vault ABI
const MorphoVaultABI = [
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
	{
		inputs: [{ name: 'shares', type: 'uint256', internalType: 'uint256' }],
		name: 'convertToAssets',
		outputs: [{ name: '', type: 'uint256', internalType: 'uint256' }],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'asset',
		outputs: [{ name: '', type: 'address', internalType: 'address' }],
		stateMutability: 'view',
		type: 'function',
	},
] as const

// Uniswap V2 Pair ABI
const UniswapV2PairABI = [
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
	{
		inputs: [],
		name: 'totalSupply',
		outputs: [{ name: '', type: 'uint256', internalType: 'uint256' }],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'getReserves',
		outputs: [
			{ name: 'reserve0', type: 'uint112', internalType: 'uint112' },
			{ name: 'reserve1', type: 'uint112', internalType: 'uint112' },
			{ name: 'blockTimestampLast', type: 'uint32', internalType: 'uint32' },
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'token0',
		outputs: [{ name: '', type: 'address', internalType: 'address' }],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'token1',
		outputs: [{ name: '', type: 'address', internalType: 'address' }],
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
			type: z.enum(['erc20', 'aave-atoken', 'morpho-vault', 'uniswap-v2-lp', 'uniswap-v3-position']).optional(), // Token type
			// Optional fields for DeFi protocol tokens
			underlyingAsset: z.string().optional(), // For aTokens and Morpho - the underlying asset
			token0: z.string().optional(), // For Uniswap V2 LP - first token
			token1: z.string().optional(), // For Uniswap V2 LP - second token
			priceFeed0: z.string().optional(), // Price feed for token0
			priceFeed1: z.string().optional(), // Price feed for token1
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

	runtime.log('0')

	if (!network) {
		throw new Error(`Network not found for chain selector name: ${runtime.config.chainSelectorName}`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	try {
		const testCallData = encodeFunctionData({
			abi: DeFiInteractorModule,
			functionName: 'getTokenBalances',
			args: [[]],
		})
		const testCall = evmClient
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: runtime.config.moduleAddress as Address,
					data: testCallData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()
	} catch (testError) {
		runtime.log(`Contract test failed: ${testError}`)
	}

	const callData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'avatar',
	})

	let contractCall
	try {
		contractCall = evmClient
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: runtime.config.moduleAddress as Address,
					data: callData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()
	} catch (error) {
		runtime.log(`Error calling avatar(): ${error}`)
		runtime.log(`Error details: ${JSON.stringify(error, null, 2)}`)
		throw error
	}

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

	let contractCall
	try {
		contractCall = evmClient
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: tokenAddress as Address,
					data: callData,
				}),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()
	} catch (error) {
		runtime.log(`Error calling decimals() on token ${tokenAddress}: ${error}`)
		throw new Error(`Failed to get decimals for token ${tokenAddress}: ${error}`)
	}

	if (!contractCall.data || contractCall.data.length === 0) {
		throw new Error(`Empty response when calling decimals() on token ${tokenAddress}`)
	}

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
 * Calculate value for Morpho vault shares
 */
const calculateMorphoValue = (
	runtime: Runtime<Config>,
	tokenConfig: Config['tokens'][0],
	sharesBalance: bigint,
): bigint => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: runtime.config.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	// Convert shares to underlying assets
	const convertCallData = encodeFunctionData({
		abi: MorphoVaultABI,
		functionName: 'convertToAssets',
		args: [sharesBalance],
	})

	const convertCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: tokenConfig.address as Address,
				data: convertCallData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	const underlyingAmount = decodeFunctionResult({
		abi: MorphoVaultABI,
		functionName: 'convertToAssets',
		data: bytesToHex(convertCall.data),
	})

	runtime.log(`  Morpho: ${sharesBalance.toString()} shares = ${underlyingAmount.toString()} underlying assets`)

	// Get underlying asset price
	const underlyingDecimals = getTokenDecimals(runtime, tokenConfig.underlyingAsset!, runtime.config.chainSelectorName)
	const { price: underlyingPrice, decimals: priceDecimals } = getChainlinkPrice(
		runtime,
		tokenConfig.priceFeedAddress,
		runtime.config.chainSelectorName,
	)

	// Calculate USD value
	return (underlyingAmount * underlyingPrice * BigInt(10 ** 18)) / BigInt(10 ** underlyingDecimals) / BigInt(10 ** priceDecimals)
}

/**
 * Calculate value for Uniswap V2 LP tokens
 */
const calculateUniswapV2LPValue = (
	runtime: Runtime<Config>,
	tokenConfig: Config['tokens'][0],
	lpBalance: bigint,
): bigint => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: runtime.config.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	// Get total supply
	const totalSupplyCallData = encodeFunctionData({
		abi: UniswapV2PairABI,
		functionName: 'totalSupply',
	})

	const totalSupplyCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: tokenConfig.address as Address,
				data: totalSupplyCallData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	const totalSupply = decodeFunctionResult({
		abi: UniswapV2PairABI,
		functionName: 'totalSupply',
		data: bytesToHex(totalSupplyCall.data),
	})

	// Get reserves
	const reservesCallData = encodeFunctionData({
		abi: UniswapV2PairABI,
		functionName: 'getReserves',
	})

	const reservesCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: tokenConfig.address as Address,
				data: reservesCallData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	const [reserve0, reserve1] = decodeFunctionResult({
		abi: UniswapV2PairABI,
		functionName: 'getReserves',
		data: bytesToHex(reservesCall.data),
	})

	// Calculate owned amounts of each token directly to avoid precision loss
	// ownedToken = (reserve * lpBalance) / totalSupply
	const ownedToken0 = (BigInt(reserve0) * lpBalance) / totalSupply
	const ownedToken1 = (BigInt(reserve1) * lpBalance) / totalSupply

	runtime.log(`  Uniswap V2 LP: owns ${ownedToken0.toString()} token0, ${ownedToken1.toString()} token1`)

	// Get prices for both tokens
	const decimals0 = getTokenDecimals(runtime, tokenConfig.token0!, runtime.config.chainSelectorName)
	const decimals1 = getTokenDecimals(runtime, tokenConfig.token1!, runtime.config.chainSelectorName)

	const { price: price0, decimals: priceDecimals0 } = getChainlinkPrice(
		runtime,
		tokenConfig.priceFeed0!,
		runtime.config.chainSelectorName,
	)

	const { price: price1, decimals: priceDecimals1 } = getChainlinkPrice(
		runtime,
		tokenConfig.priceFeed1!,
		runtime.config.chainSelectorName,
	)

	// Calculate USD value for each token
	const value0 = (ownedToken0 * price0 * BigInt(10 ** 18)) / BigInt(10 ** decimals0) / BigInt(10 ** priceDecimals0)
	const value1 = (ownedToken1 * price1 * BigInt(10 ** 18)) / BigInt(10 ** decimals1) / BigInt(10 ** priceDecimals1)

	return value0 + value1
}

/**
 * Batch fetch all token balances from the Safe using getTokenBalances
 */
const getBatchTokenBalances = (runtime: Runtime<Config>): Map<string, bigint> => {
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

	// Extract all token addresses from config
	const tokenAddresses = config.tokens.map((t) => t.address as Address)

	// Call getTokenBalances on the module
	const callData = encodeFunctionData({
		abi: DeFiInteractorModule,
		functionName: 'getTokenBalances',
		args: [tokenAddresses],
	})

	const contractCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: config.moduleAddress as Address,
				data: callData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	const balances = decodeFunctionResult({
		abi: DeFiInteractorModule,
		functionName: 'getTokenBalances',
		data: bytesToHex(contractCall.data),
	})

	// Create a map of token address to balance
	const balanceMap = new Map<string, bigint>()
	for (let i = 0; i < tokenAddresses.length; i++) {
		balanceMap.set(tokenAddresses[i].toLowerCase(), balances[i])
	}

	return balanceMap
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

	// Batch fetch all token balances in a single call
	runtime.log('Fetching all token balances in batch...')
	const balanceMap = getBatchTokenBalances(runtime)

	for (const tokenConfig of config.tokens) {
		const tokenType = tokenConfig.type || 'erc20'
		runtime.log(`Processing ${tokenType}: ${tokenConfig.symbol} (${tokenConfig.address})`)

		let valueUSD = 0n
		let balance = 0n
		let decimals = 0
		let priceUSD = 0n

		// Get balance from batch result
		balance = balanceMap.get(tokenConfig.address.toLowerCase()) || 0n

		if (tokenType === 'morpho-vault') {
			// Morpho vault shares
			valueUSD = calculateMorphoValue(runtime, tokenConfig, balance)
			decimals = getTokenDecimals(runtime, tokenConfig.address, config.chainSelectorName)
			const { price } = getChainlinkPrice(runtime, tokenConfig.priceFeedAddress, config.chainSelectorName)
			priceUSD = price
		} else if (tokenType === 'uniswap-v2-lp') {
			// Uniswap V2 LP tokens
			valueUSD = calculateUniswapV2LPValue(runtime, tokenConfig, balance)
			decimals = getTokenDecimals(runtime, tokenConfig.address, config.chainSelectorName)
			priceUSD = 0n // Not directly applicable for LP tokens
		} else {
			// Standard ERC20, aTokens (they're 1:1 with underlying)
			decimals = getTokenDecimals(runtime, tokenConfig.address, config.chainSelectorName)

			const { price, decimals: priceDecimals } = getChainlinkPrice(
				runtime,
				tokenConfig.priceFeedAddress,
				config.chainSelectorName,
			)
			priceUSD = price

			runtime.log(
				`  ${tokenConfig.symbol}: balance=${balance.toString()}, decimals=${decimals}, price=${priceUSD.toString()} (${priceDecimals} decimals)`,
			)

			// Calculate USD value
			valueUSD = (balance * priceUSD * BigInt(10 ** 18)) / BigInt(10 ** decimals) / BigInt(10 ** priceDecimals)
		}

		runtime.log(`  Value: $${(Number(valueUSD) / 1e18).toFixed(2)} USD`)

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
 * Get current on-chain safe value
 */
const getOnChainSafeValue = (runtime: Runtime<Config>): bigint => {
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
		runtime.log(`Error reading on-chain safe value: ${error}`)
		return 0n
	}
}

// Threshold for considering values "equal" (0.1% tolerance to avoid tx for tiny changes)
const VALUE_CHANGE_THRESHOLD_BPS = 10n // 0.1%

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
 * Main cron handler - runs every 30 minutes
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

	// Get current on-chain value
	const onChainValue = getOnChainSafeValue(runtime)

	runtime.log('=== Safe Value Calculation ===')
	runtime.log(safeJsonStringify(safeValueData))
	runtime.log(`Total USD Value: $${(Number(safeValueData.totalValueUSD) / 1e18).toFixed(2)} (on-chain: $${(Number(onChainValue) / 1e18).toFixed(2)})`)

	if (safeValueData.totalValueUSD === 0n) {
		runtime.log('Skipping write - total value is 0')
		runtime.log('=== Safe Value Monitor: Complete ===')
		return 'Skipped - value is 0'
	}

	// Check if change is significant (more than 0.1% difference)
	const diff = safeValueData.totalValueUSD > onChainValue
		? safeValueData.totalValueUSD - onChainValue
		: onChainValue - safeValueData.totalValueUSD
	const threshold = (onChainValue * VALUE_CHANGE_THRESHOLD_BPS) / 10000n

	if (diff <= threshold) {
		runtime.log(`Skipping write - value change below threshold`)
		runtime.log('=== Safe Value Monitor: Complete ===')
		return 'Skipped - no significant change'
	}

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
