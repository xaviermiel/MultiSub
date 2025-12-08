import { z } from 'zod'
import dotenv from 'dotenv'
import { sepolia } from 'viem/chains'

dotenv.config()

// Token configuration for safe-value calculation
export const TokenConfigSchema = z.object({
  address: z.string(),
  priceFeedAddress: z.string(),
  symbol: z.string(),
  type: z.enum(['erc20', 'aave-atoken', 'morpho-vault', 'uniswap-v2-lp']).optional().default('erc20'),
  underlyingAsset: z.string().optional(),
  token0: z.string().optional(),
  token1: z.string().optional(),
  priceFeed0: z.string().optional(),
  priceFeed1: z.string().optional(),
})

export type TokenConfig = z.infer<typeof TokenConfigSchema>

// Main configuration
export const config = {
  rpcUrl: process.env.RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com',
  privateKey: process.env.PRIVATE_KEY as `0x${string}`,
  moduleAddress: process.env.MODULE_ADDRESS as `0x${string}`,

  // Cron schedules
  safeValueCron: process.env.SAFE_VALUE_CRON || '*/30 * * * * *', // Every 30 seconds
  spendingOracleCron: process.env.SPENDING_ORACLE_CRON || '*/5 * * * *', // Every 5 minutes

  // Polling
  pollIntervalMs: parseInt(process.env.POLL_INTERVAL_MS || '10000'),
  blocksToLookBack: parseInt(process.env.BLOCKS_TO_LOOK_BACK || '7200'),
  windowDurationSeconds: parseInt(process.env.WINDOW_DURATION_SECONDS || '86400'),

  // Gas
  gasLimit: BigInt(process.env.GAS_LIMIT || '500000'),

  // Chain
  chain: sepolia,

  // Tokens to track for safe value calculation
  // Configure this based on what tokens the Safe holds
  tokens: [] as TokenConfig[],
}

// Validate required config
export function validateConfig() {
  if (!config.privateKey) {
    throw new Error('PRIVATE_KEY environment variable is required')
  }
  if (!config.moduleAddress) {
    throw new Error('MODULE_ADDRESS environment variable is required')
  }
}
