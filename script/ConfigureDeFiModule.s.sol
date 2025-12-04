// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DeFiInteractorModule} from "../src/DeFiInteractorModule.sol";
import {AaveV3Parser} from "../src/parsers/AaveV3Parser.sol";
import {UniswapV3Parser} from "../src/parsers/UniswapV3Parser.sol";
import {MorphoParser} from "../src/parsers/MorphoParser.sol";

/**
 * @title ConfigureDeFiModule
 * @notice Comprehensive script to configure selectors, parsers, and price feeds
 * @dev Run with: forge script script/ConfigureDeFiModule.s.sol --rpc-url $RPC_URL --broadcast
 */
contract ConfigureDeFiModule is Script {
    // ============ Protocol Addresses (Mainnet) ============

    // Aave V3
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

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

    // Aave V3
    bytes4 constant AAVE_SUPPLY_SELECTOR = 0x617ba037;   // supply(address,uint256,address,uint16)
    bytes4 constant AAVE_WITHDRAW_SELECTOR = 0x69328dec; // withdraw(address,uint256,address)
    bytes4 constant AAVE_BORROW_SELECTOR = 0xa415bcad;   // borrow(address,uint256,uint256,uint16,address)
    bytes4 constant AAVE_REPAY_SELECTOR = 0x573ade81;    // repay(address,uint256,uint256,address)

    // Uniswap V3
    bytes4 constant EXACT_INPUT_SINGLE_SELECTOR = 0x414bf389;
    bytes4 constant EXACT_INPUT_SELECTOR = 0xc04b8d59;
    bytes4 constant EXACT_OUTPUT_SINGLE_SELECTOR = 0xdb3e2198;
    bytes4 constant EXACT_OUTPUT_SELECTOR = 0xf28c0498;

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

        // Aave V3 Parser
        AaveV3Parser aaveParser = new AaveV3Parser();
        module.registerParser(AAVE_V3_POOL, address(aaveParser));
        console.log("   AaveV3Parser deployed at:", address(aaveParser));
        console.log("   Registered for Aave V3 Pool:", AAVE_V3_POOL);

        // Uniswap V3 Parser
        UniswapV3Parser uniswapParser = new UniswapV3Parser();
        module.registerParser(UNISWAP_V3_ROUTER, address(uniswapParser));
        module.registerParser(UNISWAP_V3_ROUTER_02, address(uniswapParser));
        console.log("   UniswapV3Parser deployed at:", address(uniswapParser));
        console.log("   Registered for Uniswap V3 Router:", UNISWAP_V3_ROUTER);
        console.log("   Registered for Uniswap V3 Router02:", UNISWAP_V3_ROUTER_02);
    }

    function _registerSelectors() internal {
        console.log("\n2. Registering selectors...");

        // ERC20 Approve
        module.registerSelector(APPROVE_SELECTOR, DeFiInteractorModule.OperationType.APPROVE);
        console.log("   APPROVE (0x095ea7b3) -> APPROVE");

        // Aave V3
        module.registerSelector(AAVE_SUPPLY_SELECTOR, DeFiInteractorModule.OperationType.DEPOSIT);
        console.log("   AAVE_SUPPLY (0x617ba037) -> DEPOSIT");

        module.registerSelector(AAVE_WITHDRAW_SELECTOR, DeFiInteractorModule.OperationType.WITHDRAW);
        console.log("   AAVE_WITHDRAW (0x69328dec) -> WITHDRAW");

        module.registerSelector(AAVE_BORROW_SELECTOR, DeFiInteractorModule.OperationType.WITHDRAW);
        console.log("   AAVE_BORROW (0xa415bcad) -> WITHDRAW");

        module.registerSelector(AAVE_REPAY_SELECTOR, DeFiInteractorModule.OperationType.DEPOSIT);
        console.log("   AAVE_REPAY (0x573ade81) -> DEPOSIT");

        // Uniswap V3
        module.registerSelector(EXACT_INPUT_SINGLE_SELECTOR, DeFiInteractorModule.OperationType.SWAP);
        console.log("   EXACT_INPUT_SINGLE (0x414bf389) -> SWAP");

        module.registerSelector(EXACT_INPUT_SELECTOR, DeFiInteractorModule.OperationType.SWAP);
        console.log("   EXACT_INPUT (0xc04b8d59) -> SWAP");

        module.registerSelector(EXACT_OUTPUT_SINGLE_SELECTOR, DeFiInteractorModule.OperationType.SWAP);
        console.log("   EXACT_OUTPUT_SINGLE (0xdb3e2198) -> SWAP");

        module.registerSelector(EXACT_OUTPUT_SELECTOR, DeFiInteractorModule.OperationType.SWAP);
        console.log("   EXACT_OUTPUT (0xf28c0498) -> SWAP");
    }

    function _configurePriceFeeds() internal {
        console.log("\n3. Configuring price feeds...");

        address[] memory tokens = new address[](5);
        address[] memory feeds = new address[](5);

        tokens[0] = USDC;
        feeds[0] = USDC_USD_FEED;

        tokens[1] = USDT;
        feeds[1] = USDT_USD_FEED;

        tokens[2] = WETH;
        feeds[2] = ETH_USD_FEED;

        tokens[3] = WBTC;
        feeds[3] = BTC_USD_FEED;

        tokens[4] = DAI;
        feeds[4] = DAI_USD_FEED;

        module.setTokenPriceFeeds(tokens, feeds);

        console.log("   USDC -> ", USDC_USD_FEED);
        console.log("   USDT -> ", USDT_USD_FEED);
        console.log("   WETH -> ", ETH_USD_FEED);
        console.log("   WBTC -> ", BTC_USD_FEED);
        console.log("   DAI  -> ", DAI_USD_FEED);
    }
}

/**
 * @title ConfigureSubAccount
 * @notice Script to configure a sub-account with roles and permissions
 */
contract ConfigureSubAccount is Script {
    function run() external {
        address moduleAddress = vm.envAddress("DEFI_MODULE_ADDRESS");
        address subAccount = vm.envAddress("SUB_ACCOUNT_ADDRESS");
        uint256 maxSpendingBps = vm.envOr("MAX_SPENDING_BPS", uint256(500)); // Default 5%
        uint256 windowDuration = vm.envOr("WINDOW_DURATION", uint256(1 days));

        DeFiInteractorModule module = DeFiInteractorModule(moduleAddress);

        console.log("Configuring sub-account:", subAccount);
        console.log("  Max spending: %s bps (%s%%)", maxSpendingBps, maxSpendingBps / 100);
        console.log("  Window duration: %s seconds", windowDuration);

        vm.startBroadcast();

        // 1. Grant DEFI_EXECUTE_ROLE
        module.grantRole(subAccount, module.DEFI_EXECUTE_ROLE());
        console.log("\n1. Granted DEFI_EXECUTE_ROLE");

        // 2. Optionally grant DEFI_TRANSFER_ROLE
        bool grantTransfer = vm.envOr("GRANT_TRANSFER_ROLE", false);
        if (grantTransfer) {
            module.grantRole(subAccount, module.DEFI_TRANSFER_ROLE());
            console.log("2. Granted DEFI_TRANSFER_ROLE");
        }

        // 3. Set sub-account limits
        module.setSubAccountLimits(subAccount, maxSpendingBps, windowDuration);
        console.log("3. Set sub-account limits");

        // 4. Set allowed addresses from environment (comma-separated)
        string memory allowedStr = vm.envOr("ALLOWED_ADDRESSES", string(""));
        if (bytes(allowedStr).length > 0) {
            // Parse comma-separated addresses
            address[] memory allowed = _parseAddresses(allowedStr);
            module.setAllowedAddresses(subAccount, allowed, true);
            console.log("4. Set %s allowed addresses", allowed.length);
        }

        vm.stopBroadcast();

        console.log("\n=== Sub-account Configuration Complete ===");
    }

    function _parseAddresses(string memory input) internal pure returns (address[] memory) {
        // Simple implementation - assumes max 10 addresses
        address[] memory temp = new address[](10);
        uint256 count = 0;

        bytes memory inputBytes = bytes(input);
        bytes memory current = new bytes(42);
        uint256 currentLen = 0;

        for (uint256 i = 0; i <= inputBytes.length; i++) {
            if (i == inputBytes.length || inputBytes[i] == ",") {
                if (currentLen > 0) {
                    // Convert bytes to address
                    string memory addrStr = string(current);
                    temp[count] = vm.parseAddress(addrStr);
                    count++;
                    currentLen = 0;
                }
            } else if (inputBytes[i] != " ") {
                current[currentLen] = inputBytes[i];
                currentLen++;
            }
        }

        // Trim array
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }
}
