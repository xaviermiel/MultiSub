// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DeFiInteractorModule} from "../src/DeFiInteractorModule.sol";
import {AaveV3Parser} from "../src/parsers/AaveV3Parser.sol";
import {UniswapV3Parser} from "../src/parsers/UniswapV3Parser.sol";
import {MorphoParser} from "../src/parsers/MorphoParser.sol";

/**
 * @title ConfigureDeFiModule
 * @notice Script to configure selectors, parsers, and price feeds for supported protocols
 * @dev Run with: forge script script/ConfigureDeFiModule.s.sol --rpc-url $RPC_URL --broadcast
 */
contract ConfigureDeFiModule is Script {
    // ============ Protocol Addresses (Mainnet) ============

    // Aave V3
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_V3_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;

    // Uniswap V3
    address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant UNISWAP_V3_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    // Common tokens (Mainnet)
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant DAI = 0x6B175474E89094C44dA98B954EEDeeCb5BE3830E;

    // Chainlink Price Feeds (Mainnet)
    address constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant USDT_USD_FEED = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant BTC_USD_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant DAI_USD_FEED = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;

    // ============ Selectors ============

    // ERC20
    bytes4 constant APPROVE_SELECTOR = 0x095ea7b3; // approve(address,uint256)

    // Aave V3 Pool
    bytes4 constant AAVE_SUPPLY_SELECTOR = 0x617ba037;   // supply(address,uint256,address,uint16)
    bytes4 constant AAVE_WITHDRAW_SELECTOR = 0x69328dec; // withdraw(address,uint256,address)
    bytes4 constant AAVE_BORROW_SELECTOR = 0xa415bcad;   // borrow(address,uint256,uint256,uint16,address)
    bytes4 constant AAVE_REPAY_SELECTOR = 0x573ade81;    // repay(address,uint256,uint256,address)

    // Aave V3 Rewards (CLAIM)
    bytes4 constant AAVE_CLAIM_REWARDS = 0x3111e7b3;           // claimRewards(address[],uint256,address,address)
    bytes4 constant AAVE_CLAIM_REWARDS_ON_BEHALF = 0x9a99b4f0; // claimRewardsOnBehalf(...)
    bytes4 constant AAVE_CLAIM_ALL_REWARDS = 0x74d945ec;       // claimAllRewards(address[],address)
    bytes4 constant AAVE_CLAIM_ALL_ON_BEHALF = 0x0c3fea64;     // claimAllRewardsOnBehalf(...)

    // Uniswap V3
    bytes4 constant EXACT_INPUT_SINGLE_SELECTOR = 0x414bf389;
    bytes4 constant EXACT_INPUT_SELECTOR = 0xc04b8d59;
    bytes4 constant EXACT_OUTPUT_SINGLE_SELECTOR = 0xdb3e2198;
    bytes4 constant EXACT_OUTPUT_SELECTOR = 0xf28c0498;

    // Morpho (ERC4626)
    bytes4 constant MORPHO_DEPOSIT_SELECTOR = 0x6e553f65;   // deposit(uint256,address)
    bytes4 constant MORPHO_MINT_SELECTOR = 0x94bf804d;      // mint(uint256,address)
    bytes4 constant MORPHO_WITHDRAW_SELECTOR = 0xb460af94;  // withdraw(uint256,address,address)
    bytes4 constant MORPHO_REDEEM_SELECTOR = 0xba087652;    // redeem(uint256,address,address)

    DeFiInteractorModule public module;

    function run() external {
        address moduleAddress = vm.envAddress("DEFI_MODULE_ADDRESS");
        module = DeFiInteractorModule(moduleAddress);

        console.log("Configuring DeFiInteractorModule at:", moduleAddress);
        console.log("Owner:", module.owner());

        vm.startBroadcast();

        // 1. Deploy and register parsers
        _deployAndRegisterParsers();

        // 2. Register selectors
        _registerSelectors();

        // 3. Configure price feeds
        _configurePriceFeeds();

        vm.stopBroadcast();

        console.log("\n=== Configuration Complete ===");
    }

    function _deployAndRegisterParsers() internal {
        console.log("\n1. Deploying and registering parsers...");

        // Aave V3 Parser (handles Pool and RewardsController)
        AaveV3Parser aaveParser = new AaveV3Parser();
        module.registerParser(AAVE_V3_POOL, address(aaveParser));
        module.registerParser(AAVE_V3_REWARDS, address(aaveParser));
        console.log("   AaveV3Parser deployed at:", address(aaveParser));
        console.log("   Registered for Aave V3 Pool:", AAVE_V3_POOL);
        console.log("   Registered for Aave V3 Rewards:", AAVE_V3_REWARDS);

        // Uniswap V3 Parser
        UniswapV3Parser uniswapParser = new UniswapV3Parser();
        module.registerParser(UNISWAP_V3_ROUTER, address(uniswapParser));
        module.registerParser(UNISWAP_V3_ROUTER_02, address(uniswapParser));
        console.log("   UniswapV3Parser deployed at:", address(uniswapParser));
        console.log("   Registered for Uniswap V3 Router:", UNISWAP_V3_ROUTER);
        console.log("   Registered for Uniswap V3 Router02:", UNISWAP_V3_ROUTER_02);

        // Morpho Parser (for ERC4626 vaults)
        // Note: Register for specific Morpho vault addresses as needed
        MorphoParser morphoParser = new MorphoParser();
        console.log("   MorphoParser deployed at:", address(morphoParser));
        console.log("   Note: Register for specific Morpho vault addresses");
    }

    function _registerSelectors() internal {
        console.log("\n2. Registering selectors...");

        // ERC20 Approve
        module.registerSelector(APPROVE_SELECTOR, DeFiInteractorModule.OperationType.APPROVE);
        console.log("   APPROVE -> APPROVE");

        // ============ Aave V3 Pool ============
        module.registerSelector(AAVE_SUPPLY_SELECTOR, DeFiInteractorModule.OperationType.DEPOSIT);
        console.log("   AAVE_SUPPLY -> DEPOSIT");

        module.registerSelector(AAVE_WITHDRAW_SELECTOR, DeFiInteractorModule.OperationType.WITHDRAW);
        console.log("   AAVE_WITHDRAW -> WITHDRAW");

        module.registerSelector(AAVE_BORROW_SELECTOR, DeFiInteractorModule.OperationType.WITHDRAW);
        console.log("   AAVE_BORROW -> WITHDRAW");

        module.registerSelector(AAVE_REPAY_SELECTOR, DeFiInteractorModule.OperationType.DEPOSIT);
        console.log("   AAVE_REPAY -> DEPOSIT");

        // ============ Aave V3 Rewards (CLAIM) ============
        module.registerSelector(AAVE_CLAIM_REWARDS, DeFiInteractorModule.OperationType.CLAIM);
        console.log("   AAVE_CLAIM_REWARDS -> CLAIM");

        module.registerSelector(AAVE_CLAIM_REWARDS_ON_BEHALF, DeFiInteractorModule.OperationType.CLAIM);
        console.log("   AAVE_CLAIM_REWARDS_ON_BEHALF -> CLAIM");

        module.registerSelector(AAVE_CLAIM_ALL_REWARDS, DeFiInteractorModule.OperationType.CLAIM);
        console.log("   AAVE_CLAIM_ALL_REWARDS -> CLAIM");

        module.registerSelector(AAVE_CLAIM_ALL_ON_BEHALF, DeFiInteractorModule.OperationType.CLAIM);
        console.log("   AAVE_CLAIM_ALL_ON_BEHALF -> CLAIM");

        // ============ Uniswap V3 (SWAP) ============
        module.registerSelector(EXACT_INPUT_SINGLE_SELECTOR, DeFiInteractorModule.OperationType.SWAP);
        console.log("   EXACT_INPUT_SINGLE -> SWAP");

        module.registerSelector(EXACT_INPUT_SELECTOR, DeFiInteractorModule.OperationType.SWAP);
        console.log("   EXACT_INPUT -> SWAP");

        module.registerSelector(EXACT_OUTPUT_SINGLE_SELECTOR, DeFiInteractorModule.OperationType.SWAP);
        console.log("   EXACT_OUTPUT_SINGLE -> SWAP");

        module.registerSelector(EXACT_OUTPUT_SELECTOR, DeFiInteractorModule.OperationType.SWAP);
        console.log("   EXACT_OUTPUT -> SWAP");

        // ============ Morpho (ERC4626) ============
        module.registerSelector(MORPHO_DEPOSIT_SELECTOR, DeFiInteractorModule.OperationType.DEPOSIT);
        console.log("   MORPHO_DEPOSIT -> DEPOSIT");

        module.registerSelector(MORPHO_MINT_SELECTOR, DeFiInteractorModule.OperationType.DEPOSIT);
        console.log("   MORPHO_MINT -> DEPOSIT");

        module.registerSelector(MORPHO_WITHDRAW_SELECTOR, DeFiInteractorModule.OperationType.WITHDRAW);
        console.log("   MORPHO_WITHDRAW -> WITHDRAW");

        module.registerSelector(MORPHO_REDEEM_SELECTOR, DeFiInteractorModule.OperationType.WITHDRAW);
        console.log("   MORPHO_REDEEM -> WITHDRAW");
    }

    function _configurePriceFeeds() internal {
        console.log("\n3. Configuring price feeds...");

        address[] memory tokens = new address[](5);
        address[] memory feeds = new address[](5);

        tokens[0] = USDC;
        feeds[0] = USDC_USD_FEED;

        tokens[1] = USDT;
        feeds[1] = USDT_USD_FEED;

        tokens[2] = DAI;
        feeds[2] = DAI_USD_FEED;

        tokens[3] = WETH;
        feeds[3] = ETH_USD_FEED;

        tokens[4] = WBTC;
        feeds[4] = BTC_USD_FEED;

        module.setTokenPriceFeeds(tokens, feeds);

        console.log("   USDC, USDT, DAI, WETH, WBTC price feeds configured");
    }
}

/**
 * @title ConfigureSubAccount
 * @notice Script to configure a sub-account with roles and permissions
 * @dev Environment variables:
 *      - DEFI_MODULE_ADDRESS: The DeFiInteractorModule address
 *      - SUB_ACCOUNT_ADDRESS: The sub-account wallet address
 *      - MAX_SPENDING_BPS: Max spending in basis points (default: 500 = 5%)
 *      - WINDOW_DURATION: Time window in seconds (default: 86400 = 1 day)
 *      - GRANT_TRANSFER_ROLE: Whether to grant transfer role (default: false)
 *      - ALLOWED_ADDRESSES: Comma-separated list of allowed protocol addresses
 */
contract ConfigureSubAccount is Script {
    function run() external {
        address moduleAddress = vm.envAddress("DEFI_MODULE_ADDRESS");
        address subAccount = vm.envAddress("SUB_ACCOUNT_ADDRESS");
        uint256 maxSpendingBps = vm.envOr("MAX_SPENDING_BPS", uint256(500)); // Default 5%
        uint256 windowDuration = vm.envOr("WINDOW_DURATION", uint256(1 days));

        DeFiInteractorModule module = DeFiInteractorModule(moduleAddress);

        console.log("Configuring sub-account:", subAccount);
        console.log("  Max spending: %s bps", maxSpendingBps);
        console.log("  Window duration: %s seconds", windowDuration);

        vm.startBroadcast();

        // 1. Grant DEFI_EXECUTE_ROLE
        module.grantRole(subAccount, module.DEFI_EXECUTE_ROLE());
        console.log("1. Granted DEFI_EXECUTE_ROLE");

        // 2. Optionally grant DEFI_TRANSFER_ROLE
        bool grantTransfer = vm.envOr("GRANT_TRANSFER_ROLE", false);
        if (grantTransfer) {
            module.grantRole(subAccount, module.DEFI_TRANSFER_ROLE());
            console.log("2. Granted DEFI_TRANSFER_ROLE");
        }

        // 3. Set sub-account limits
        module.setSubAccountLimits(subAccount, maxSpendingBps, windowDuration);
        console.log("3. Set sub-account limits");

        // 4. Set allowed addresses
        string memory allowedStr = vm.envOr("ALLOWED_ADDRESSES", string(""));
        if (bytes(allowedStr).length > 0) {
            address[] memory allowed = _parseAddresses(allowedStr);
            module.setAllowedAddresses(subAccount, allowed, true);
            console.log("4. Set %s allowed addresses", allowed.length);
        } else {
            console.log("4. No ALLOWED_ADDRESSES set - skipping");
        }

        vm.stopBroadcast();

        console.log("\n=== Sub-account Configuration Complete ===");
    }

    /**
     * @notice Parse comma-separated addresses from string
     * @param input Comma-separated addresses (e.g., "0x123...,0x456...")
     * @return Array of parsed addresses
     */
    function _parseAddresses(string memory input) internal pure returns (address[] memory) {
        // Count commas to determine array size
        bytes memory inputBytes = bytes(input);
        uint256 count = 1;
        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == ",") count++;
        }

        address[] memory result = new address[](count);
        uint256 resultIndex = 0;
        uint256 start = 0;

        for (uint256 i = 0; i <= inputBytes.length; i++) {
            if (i == inputBytes.length || inputBytes[i] == ",") {
                // Extract substring from start to i
                bytes memory addrBytes = new bytes(i - start);
                uint256 writeIndex = 0;
                for (uint256 j = start; j < i; j++) {
                    // Skip spaces
                    if (inputBytes[j] != " ") {
                        addrBytes[writeIndex] = inputBytes[j];
                        writeIndex++;
                    }
                }
                // Trim to actual length
                bytes memory trimmed = new bytes(writeIndex);
                for (uint256 k = 0; k < writeIndex; k++) {
                    trimmed[k] = addrBytes[k];
                }

                if (trimmed.length > 0) {
                    result[resultIndex] = vm.parseAddress(string(trimmed));
                    resultIndex++;
                }
                start = i + 1;
            }
        }

        // Trim result array if needed
        if (resultIndex < count) {
            address[] memory trimmedResult = new address[](resultIndex);
            for (uint256 i = 0; i < resultIndex; i++) {
                trimmedResult[i] = result[i];
            }
            return trimmedResult;
        }

        return result;
    }
}

/**
 * @title ConfigureSubAccountPreset
 * @notice Script to configure a sub-account with preset protocol configurations
 * @dev Use PRESET env var: "aave", "uniswap", "all"
 */
contract ConfigureSubAccountPreset is Script {
    // Protocol addresses (Mainnet)
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_V3_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant UNISWAP_V3_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    function run() external {
        address moduleAddress = vm.envAddress("DEFI_MODULE_ADDRESS");
        address subAccount = vm.envAddress("SUB_ACCOUNT_ADDRESS");
        string memory preset = vm.envOr("PRESET", string("all"));
        uint256 maxSpendingBps = vm.envOr("MAX_SPENDING_BPS", uint256(500));
        uint256 windowDuration = vm.envOr("WINDOW_DURATION", uint256(1 days));

        DeFiInteractorModule module = DeFiInteractorModule(moduleAddress);

        console.log("Configuring sub-account with preset:", preset);

        vm.startBroadcast();

        // Grant role and set limits
        module.grantRole(subAccount, module.DEFI_EXECUTE_ROLE());
        module.setSubAccountLimits(subAccount, maxSpendingBps, windowDuration);

        // Set allowed addresses based on preset
        address[] memory allowed = _getPresetAddresses(preset);
        if (allowed.length > 0) {
            module.setAllowedAddresses(subAccount, allowed, true);
            console.log("Allowed %s protocol addresses", allowed.length);
        }

        vm.stopBroadcast();
    }

    function _getPresetAddresses(string memory preset) internal pure returns (address[] memory) {
        bytes32 presetHash = keccak256(bytes(preset));

        if (presetHash == keccak256("aave")) {
            address[] memory addrs = new address[](2);
            addrs[0] = AAVE_V3_POOL;
            addrs[1] = AAVE_V3_REWARDS;
            return addrs;
        } else if (presetHash == keccak256("uniswap")) {
            address[] memory addrs = new address[](2);
            addrs[0] = UNISWAP_V3_ROUTER;
            addrs[1] = UNISWAP_V3_ROUTER_02;
            return addrs;
        } else if (presetHash == keccak256("all")) {
            address[] memory addrs = new address[](4);
            addrs[0] = AAVE_V3_POOL;
            addrs[1] = AAVE_V3_REWARDS;
            addrs[2] = UNISWAP_V3_ROUTER;
            addrs[3] = UNISWAP_V3_ROUTER_02;
            return addrs;
        }

        // Empty array for unknown preset
        return new address[](0);
    }
}
