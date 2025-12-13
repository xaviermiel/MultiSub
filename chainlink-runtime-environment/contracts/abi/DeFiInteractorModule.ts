export const DeFiInteractorModule = [
	// ============ Oracle Functions ============
	{
		type: 'function',
		name: 'updateSafeValue',
		inputs: [{ name: 'totalValueUSD', type: 'uint256', internalType: 'uint256' }],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'updateSpendingAllowance',
		inputs: [
			{ name: 'subAccount', type: 'address', internalType: 'address' },
			{ name: 'newAllowance', type: 'uint256', internalType: 'uint256' },
		],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'updateAcquiredBalance',
		inputs: [
			{ name: 'subAccount', type: 'address', internalType: 'address' },
			{ name: 'token', type: 'address', internalType: 'address' },
			{ name: 'newBalance', type: 'uint256', internalType: 'uint256' },
		],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'batchUpdate',
		inputs: [
			{ name: 'subAccount', type: 'address', internalType: 'address' },
			{ name: 'newAllowance', type: 'uint256', internalType: 'uint256' },
			{ name: 'tokens', type: 'address[]', internalType: 'address[]' },
			{ name: 'balances', type: 'uint256[]', internalType: 'uint256[]' },
		],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	// ============ View Functions ============
	{
		type: 'function',
		name: 'getSafeValue',
		inputs: [],
		outputs: [
			{ name: 'totalValueUSD', type: 'uint256', internalType: 'uint256' },
			{ name: 'lastUpdated', type: 'uint256', internalType: 'uint256' },
			{ name: 'updateCount', type: 'uint256', internalType: 'uint256' },
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'getSpendingAllowance',
		inputs: [{ name: 'subAccount', type: 'address', internalType: 'address' }],
		outputs: [{ name: '', type: 'uint256', internalType: 'uint256' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'getAcquiredBalance',
		inputs: [
			{ name: 'subAccount', type: 'address', internalType: 'address' },
			{ name: 'token', type: 'address', internalType: 'address' },
		],
		outputs: [{ name: '', type: 'uint256', internalType: 'uint256' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'avatar',
		inputs: [],
		outputs: [{ name: '', type: 'address', internalType: 'address' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'getTokenBalances',
		inputs: [{ name: 'tokens', type: 'address[]', internalType: 'address[]' }],
		outputs: [{ name: 'balances', type: 'uint256[]', internalType: 'uint256[]' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'safeValue',
		inputs: [],
		outputs: [
			{ name: 'totalValueUSD', type: 'uint256', internalType: 'uint256' },
			{ name: 'lastUpdated', type: 'uint256', internalType: 'uint256' },
			{ name: 'updateCount', type: 'uint256', internalType: 'uint256' },
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'absoluteMaxSpendingBps',
		inputs: [],
		outputs: [{ name: '', type: 'uint256', internalType: 'uint256' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'subAccountLimits',
		inputs: [{ name: 'subAccount', type: 'address', internalType: 'address' }],
		outputs: [
			{ name: 'maxSpendingBps', type: 'uint256', internalType: 'uint256' },
			{ name: 'windowDuration', type: 'uint256', internalType: 'uint256' },
			{ name: 'isConfigured', type: 'bool', internalType: 'bool' },
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'getSubAccountLimits',
		inputs: [{ name: 'subAccount', type: 'address', internalType: 'address' }],
		outputs: [
			{ name: 'maxSpendingBps', type: 'uint256', internalType: 'uint256' },
			{ name: 'windowDuration', type: 'uint256', internalType: 'uint256' },
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'getSubaccountsByRole',
		inputs: [{ name: 'roleId', type: 'uint16', internalType: 'uint16' }],
		outputs: [{ name: '', type: 'address[]', internalType: 'address[]' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'DEFI_EXECUTE_ROLE',
		inputs: [],
		outputs: [{ name: '', type: 'uint16', internalType: 'uint16' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'DEFI_TRANSFER_ROLE',
		inputs: [],
		outputs: [{ name: '', type: 'uint16', internalType: 'uint16' }],
		stateMutability: 'view',
	},
	// ============ Events ============
	// Note: Events no longer include timestamp - contract uses block.timestamp internally
	{
		type: 'event',
		name: 'ProtocolExecution',
		inputs: [
			{ name: 'subAccount', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'target', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'opType', type: 'uint8', indexed: false, internalType: 'uint8' },
			{ name: 'tokensIn', type: 'address[]', indexed: false, internalType: 'address[]' },
			{ name: 'amountsIn', type: 'uint256[]', indexed: false, internalType: 'uint256[]' },
			{ name: 'tokensOut', type: 'address[]', indexed: false, internalType: 'address[]' },
			{ name: 'amountsOut', type: 'uint256[]', indexed: false, internalType: 'uint256[]' },
			{ name: 'spendingCost', type: 'uint256', indexed: false, internalType: 'uint256' },
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'TransferExecuted',
		inputs: [
			{ name: 'subAccount', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'token', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'recipient', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'amount', type: 'uint256', indexed: false, internalType: 'uint256' },
			{ name: 'spendingCost', type: 'uint256', indexed: false, internalType: 'uint256' },
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'SafeValueUpdated',
		inputs: [
			{ name: 'totalValueUSD', type: 'uint256', indexed: false, internalType: 'uint256' },
			{ name: 'updateCount', type: 'uint256', indexed: false, internalType: 'uint256' },
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'SpendingAllowanceUpdated',
		inputs: [
			{ name: 'subAccount', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'newAllowance', type: 'uint256', indexed: false, internalType: 'uint256' },
			{ name: 'timestamp', type: 'uint256', indexed: false, internalType: 'uint256' },
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'AcquiredBalanceUpdated',
		inputs: [
			{ name: 'subAccount', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'token', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'newBalance', type: 'uint256', indexed: false, internalType: 'uint256' },
		],
		anonymous: false,
	},
] as const

// Operation types enum (matches contract)
export enum OperationType {
	UNKNOWN = 0,
	SWAP = 1,
	DEPOSIT = 2,
	WITHDRAW = 3,
	CLAIM = 4,
	APPROVE = 5,
}

// Event signature hashes for log filtering
// Note: These are raw signatures, not keccak256 hashed - hash them before use
export const EVENT_SIGNATURES = {
	ProtocolExecution: 'ProtocolExecution(address,address,uint8,address[],uint256[],address[],uint256[],uint256)',
	TransferExecuted: 'TransferExecuted(address,address,address,uint256,uint256)',
	SafeValueUpdated: 'SafeValueUpdated(uint256,uint256)',
	AcquiredBalanceUpdated: 'AcquiredBalanceUpdated(address,address,uint256)',
}
