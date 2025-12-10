/**
 * Local Safe Value Oracle
 *
 * Calculates the total USD value of all tokens in the Safe and updates the contract.
 * Runs on a cron schedule (default: every 30 minutes).
 *
 * This is a local version that doesn't require Chainlink CRE infrastructure.
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  formatUnits,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import cron from 'node-cron'
import { config, validateConfig, type TokenConfig } from './config.js'
import {
  DeFiInteractorModuleABI,
  ERC20ABI,
  ChainlinkPriceFeedABI,
  MorphoVaultABI,
  UniswapV2PairABI,
} from './abi.js'

// Initialize clients
const publicClient = createPublicClient({
  chain: config.chain,
  transport: http(config.rpcUrl),
})

let walletClient: ReturnType<typeof createWalletClient>
let account: ReturnType<typeof privateKeyToAccount>

function initWalletClient() {
  account = privateKeyToAccount(config.privateKey)
  walletClient = createWalletClient({
    chain: config.chain,
    transport: http(config.rpcUrl),
    account,
  })
}

// ============ Helper Functions ============

function log(message: string) {
  console.log(`[SafeValue ${new Date().toISOString()}] ${message}`)
}

/**
 * Get the Safe address from the module
 */
async function getSafeAddress(): Promise<Address> {
  const safeAddress = await publicClient.readContract({
    address: config.moduleAddress,
    abi: DeFiInteractorModuleABI,
    functionName: 'avatar',
  })
  return safeAddress as Address
}

/**
 * Get token balance for an address
 */
async function getTokenBalance(tokenAddress: Address, holderAddress: Address): Promise<bigint> {
  try {
    const balance = await publicClient.readContract({
      address: tokenAddress,
      abi: ERC20ABI,
      functionName: 'balanceOf',
      args: [holderAddress],
    })
    return balance
  } catch (error) {
    log(`Error getting balance for ${tokenAddress}: ${error}`)
    return 0n
  }
}

/**
 * Get token decimals
 */
async function getTokenDecimals(tokenAddress: Address): Promise<number> {
  try {
    const decimals = await publicClient.readContract({
      address: tokenAddress,
      abi: ERC20ABI,
      functionName: 'decimals',
    })
    return decimals
  } catch (error) {
    log(`Error getting decimals for ${tokenAddress}: ${error}`)
    return 18 // Default to 18
  }
}

/**
 * Get price from Chainlink price feed
 */
async function getChainlinkPrice(priceFeedAddress: Address): Promise<{ price: bigint; decimals: number }> {
  try {
    const [, answer] = await publicClient.readContract({
      address: priceFeedAddress,
      abi: ChainlinkPriceFeedABI,
      functionName: 'latestRoundData',
    })

    const decimals = await publicClient.readContract({
      address: priceFeedAddress,
      abi: ChainlinkPriceFeedABI,
      functionName: 'decimals',
    })

    return { price: BigInt(answer), decimals }
  } catch (error) {
    log(`Error getting price from ${priceFeedAddress}: ${error}`)
    return { price: 0n, decimals: 8 }
  }
}

/**
 * Calculate value for Morpho vault shares
 */
async function calculateMorphoValue(
  tokenConfig: TokenConfig,
  sharesBalance: bigint,
): Promise<bigint> {
  if (!tokenConfig.underlyingAsset) {
    log(`Morpho vault ${tokenConfig.symbol} missing underlyingAsset config`)
    return 0n
  }

  try {
    // Convert shares to underlying assets
    const underlyingAmount = await publicClient.readContract({
      address: tokenConfig.address as Address,
      abi: MorphoVaultABI,
      functionName: 'convertToAssets',
      args: [sharesBalance],
    })

    log(`  Morpho: ${sharesBalance} shares = ${underlyingAmount} underlying assets`)

    // Get underlying asset price
    const underlyingDecimals = await getTokenDecimals(tokenConfig.underlyingAsset as Address)
    const { price: underlyingPrice, decimals: priceDecimals } = await getChainlinkPrice(
      tokenConfig.priceFeedAddress as Address
    )

    // Calculate USD value
    return (underlyingAmount * underlyingPrice * BigInt(10 ** 18)) / BigInt(10 ** underlyingDecimals) / BigInt(10 ** priceDecimals)
  } catch (error) {
    log(`Error calculating Morpho value: ${error}`)
    return 0n
  }
}

/**
 * Calculate value for Uniswap V2 LP tokens
 */
async function calculateUniswapV2LPValue(
  tokenConfig: TokenConfig,
  lpBalance: bigint,
): Promise<bigint> {
  if (!tokenConfig.token0 || !tokenConfig.token1 || !tokenConfig.priceFeed0 || !tokenConfig.priceFeed1) {
    log(`Uniswap V2 LP ${tokenConfig.symbol} missing token/priceFeed config`)
    return 0n
  }

  try {
    const pairAddress = tokenConfig.address as Address

    // Get total supply
    const totalSupply = await publicClient.readContract({
      address: pairAddress,
      abi: UniswapV2PairABI,
      functionName: 'totalSupply',
    })

    // Get reserves
    const [reserve0, reserve1] = await publicClient.readContract({
      address: pairAddress,
      abi: UniswapV2PairABI,
      functionName: 'getReserves',
    })

    // Calculate owned amounts
    const ownedToken0 = (BigInt(reserve0) * lpBalance) / totalSupply
    const ownedToken1 = (BigInt(reserve1) * lpBalance) / totalSupply

    log(`  Uniswap V2 LP: owns ${ownedToken0} token0, ${ownedToken1} token1`)

    // Get prices for both tokens
    const decimals0 = await getTokenDecimals(tokenConfig.token0 as Address)
    const decimals1 = await getTokenDecimals(tokenConfig.token1 as Address)

    const { price: price0, decimals: priceDecimals0 } = await getChainlinkPrice(tokenConfig.priceFeed0 as Address)
    const { price: price1, decimals: priceDecimals1 } = await getChainlinkPrice(tokenConfig.priceFeed1 as Address)

    // Calculate USD value for each token
    const value0 = (ownedToken0 * price0 * BigInt(10 ** 18)) / BigInt(10 ** decimals0) / BigInt(10 ** priceDecimals0)
    const value1 = (ownedToken1 * price1 * BigInt(10 ** 18)) / BigInt(10 ** decimals1) / BigInt(10 ** priceDecimals1)

    return value0 + value1
  } catch (error) {
    log(`Error calculating Uniswap V2 LP value: ${error}`)
    return 0n
  }
}

/**
 * Batch fetch all token balances from the Safe
 */
async function getBatchTokenBalances(tokenAddresses: Address[]): Promise<Map<string, bigint>> {
  try {
    const balances = await publicClient.readContract({
      address: config.moduleAddress,
      abi: DeFiInteractorModuleABI,
      functionName: 'getTokenBalances',
      args: [tokenAddresses],
    })

    const balanceMap = new Map<string, bigint>()
    for (let i = 0; i < tokenAddresses.length; i++) {
      balanceMap.set(tokenAddresses[i].toLowerCase(), balances[i])
    }

    return balanceMap
  } catch (error) {
    log(`Error batch fetching balances: ${error}`)
    return new Map()
  }
}

/**
 * Get native ETH balance for an address
 */
async function getNativeEthBalance(address: Address): Promise<bigint> {
  try {
    return await publicClient.getBalance({ address })
  } catch (error) {
    log(`Error getting native ETH balance: ${error}`)
    return 0n
  }
}

/**
 * Calculate total Safe value
 */
async function calculateSafeValue(): Promise<bigint> {
  const tokens = config.tokens
  let totalValueUSD = 0n

  // Get Safe address
  const safeAddress = await getSafeAddress()
  log(`Monitoring Safe: ${safeAddress}`)

  // First, calculate native ETH value
  const ethBalance = await getNativeEthBalance(safeAddress)
  if (ethBalance > 0n) {
    log(`Processing native ETH`)
    const { price: ethPrice, decimals: priceDecimals } = await getChainlinkPrice(
      '0x694AA1769357215DE4FAC081bf1f309aDC325306' as Address // ETH/USD Sepolia
    )
    const ethValueUSD = (ethBalance * ethPrice * BigInt(10 ** 18)) / BigInt(10 ** 18) / BigInt(10 ** priceDecimals)
    log(`  ETH: balance=${formatUnits(ethBalance, 18)}, price=${formatUnits(ethPrice, priceDecimals)} USD`)
    log(`  Value: $${formatUnits(ethValueUSD, 18)} USD`)
    totalValueUSD += ethValueUSD
  }

  if (tokens.length === 0) {
    log('No ERC20 tokens configured for safe value calculation')
    return totalValueUSD
  }

  // Batch fetch all ERC20 balances
  const tokenAddresses = tokens.map(t => t.address as Address)
  const balanceMap = await getBatchTokenBalances(tokenAddresses)

  for (const tokenConfig of tokens) {
    const tokenType = tokenConfig.type || 'erc20'
    log(`Processing ${tokenType}: ${tokenConfig.symbol} (${tokenConfig.address})`)

    let valueUSD = 0n
    const balance = balanceMap.get(tokenConfig.address.toLowerCase()) || 0n

    if (balance === 0n) {
      log(`  Balance: 0, skipping`)
      continue
    }

    if (tokenType === 'morpho-vault') {
      valueUSD = await calculateMorphoValue(tokenConfig, balance)
    } else if (tokenType === 'uniswap-v2-lp') {
      valueUSD = await calculateUniswapV2LPValue(tokenConfig, balance)
    } else {
      // Standard ERC20, aTokens (1:1 with underlying)
      const decimals = await getTokenDecimals(tokenConfig.address as Address)
      const { price, decimals: priceDecimals } = await getChainlinkPrice(tokenConfig.priceFeedAddress as Address)

      log(`  ${tokenConfig.symbol}: balance=${formatUnits(balance, decimals)}, price=${formatUnits(price, priceDecimals)} USD`)

      valueUSD = (balance * price * BigInt(10 ** 18)) / BigInt(10 ** decimals) / BigInt(10 ** priceDecimals)
    }

    log(`  Value: $${formatUnits(valueUSD, 18)} USD`)
    totalValueUSD += valueUSD
  }

  return totalValueUSD
}

/**
 * Write safe value to the contract
 */
async function writeSafeValueToChain(totalValueUSD: bigint): Promise<string> {
  log(`Writing Safe value to chain: ${totalValueUSD} ($${formatUnits(totalValueUSD, 18)} USD)`)

  try {
    const hash = await walletClient.writeContract({
      chain: config.chain,
      account,
      address: config.moduleAddress,
      abi: DeFiInteractorModuleABI,
      functionName: 'updateSafeValue',
      args: [totalValueUSD],
      gas: config.gasLimit,
    })

    log(`Transaction submitted: ${hash}`)

    // Wait for confirmation
    const receipt = await publicClient.waitForTransactionReceipt({ hash })
    log(`Transaction confirmed in block ${receipt.blockNumber}`)

    return hash
  } catch (error) {
    log(`Error writing safe value: ${error}`)
    throw error
  }
}

/**
 * Main cron job handler
 */
async function onCronTrigger() {
  log('=== Safe Value Monitor: Starting check ===')

  try {
    const totalValueUSD = await calculateSafeValue()
    log(`Total USD Value: $${formatUnits(totalValueUSD, 18)}`)

    if (totalValueUSD > 0n) {
      await writeSafeValueToChain(totalValueUSD)
    } else {
      log('Skipping write - total value is 0')
    }

    log('=== Safe Value Monitor: Complete ===')
  } catch (error) {
    log(`Error in safe value update: ${error}`)
  }
}

/**
 * Run a single update (for testing)
 */
export async function runOnce() {
  validateConfig()
  initWalletClient()
  await onCronTrigger()
}

/**
 * Start the cron scheduler
 */
export function startCron() {
  validateConfig()
  initWalletClient()

  log(`Starting Safe Value Oracle with cron: ${config.safeValueCron}`)
  log(`Module address: ${config.moduleAddress}`)
  log(`Updater address: ${account.address}`)

  cron.schedule(config.safeValueCron, onCronTrigger)

  // Run immediately on start
  onCronTrigger()
}

// Run if called directly
if (import.meta.url === `file://${process.argv[1]}`) {
  startCron()
}
