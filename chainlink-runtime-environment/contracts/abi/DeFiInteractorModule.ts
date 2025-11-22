export const DeFiInteractorModule = [
	{
		type: 'function',
		name: 'updateSafeValue',
		inputs: [{ name: 'totalValueUSD', type: 'uint256', internalType: 'uint256' }],
		outputs: [],
		stateMutability: 'nonpayable',
	},
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
		name: 'isValueStale',
		inputs: [{ name: 'maxAge', type: 'uint256', internalType: 'uint256' }],
		outputs: [{ name: 'isStale', type: 'bool', internalType: 'bool' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'authorizedUpdater',
		inputs: [],
		outputs: [{ name: '', type: 'address', internalType: 'address' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'setAuthorizedUpdater',
		inputs: [{ name: 'newUpdater', type: 'address', internalType: 'address' }],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'avatar',
		inputs: [],
		outputs: [{ name: '', type: 'address', internalType: 'address' }],
		stateMutability: 'view',
	},
	{
		type: 'event',
		name: 'SafeValueUpdated',
		inputs: [
			{ name: 'totalValueUSD', type: 'uint256', indexed: false, internalType: 'uint256' },
			{ name: 'timestamp', type: 'uint256', indexed: false, internalType: 'uint256' },
			{ name: 'updateCount', type: 'uint256', indexed: false, internalType: 'uint256' },
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'AuthorizedUpdaterChanged',
		inputs: [
			{ name: 'oldUpdater', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'newUpdater', type: 'address', indexed: true, internalType: 'address' },
		],
		anonymous: false,
	},
] as const
