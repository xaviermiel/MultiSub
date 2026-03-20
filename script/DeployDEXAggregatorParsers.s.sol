// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "./utils/SafeTxHelper.sol";
import {OneInchParser} from "../src/parsers/OneInchParser.sol";
import {ParaswapParser} from "../src/parsers/ParaswapParser.sol";
import {KyberSwapParser} from "../src/parsers/KyberSwapParser.sol";

/**
 * @title DeployDEXAggregatorParsers
 * @notice Deploy and register DEX aggregator parsers for 1inch, Paraswap, and KyberSwap
 * @dev Deploys parsers, registers them with the module, and whitelists aggregator addresses
 */
contract DeployDEXAggregatorParsers is Script, SafeTxHelper {
    // ============ Configuration ============

    address constant SAFE = 0x6E7692fFE42ca2A3FA2b08611AA7e79A2AaA8e8C;
    address constant MODULE = 0xDFF3cBa01F63152446E442133B664baE5A42bf39;

    // DEX Aggregator addresses (Mainnet - adjust for other networks)
    // Sepolia might have different addresses or no deployments

    // 1inch AggregationRouterV6
    address constant ONE_INCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    // Paraswap AugustusSwapper V6
    address constant PARASWAP_ROUTER = 0x6A000F20005980200259B80c5102003040001068;

    // KyberSwap MetaAggregationRouterV2
    address constant KYBERSWAP_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    // Subaccounts to whitelist aggregators for
    address[5] SUBACCOUNTS = [
        0x962aCEB4C3C53f09110106D08364A8B40eA54568,
        0xA08F4D9d1046d4fD32E3a38b2e5F07E9aacf5F42,
        0x4573A0C9428e56B0d4EEfcb43DCd99299BBD2e6c,
        0xF12F793128Ee3B7FddA6B73fC505EA252894B859,
        0x7edA8eE795988aC0FfC5C6A50B2C6798613900BB
    ];

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== Deploy DEX Aggregator Parsers ===");
        console.log("Safe:", SAFE);
        console.log("Module:", MODULE);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============ Deploy Parsers ============

        console.log("Deploying parsers...");

        OneInchParser oneInchParser = new OneInchParser();
        console.log("OneInchParser deployed at:", address(oneInchParser));

        ParaswapParser paraswapParser = new ParaswapParser();
        console.log("ParaswapParser deployed at:", address(paraswapParser));

        KyberSwapParser kyberSwapParser = new KyberSwapParser();
        console.log("KyberSwapParser deployed at:", address(kyberSwapParser));

        console.log("");

        // ============ Register Parsers with Module ============

        console.log("Registering parsers with module...");

        // Register 1inch parser
        _executeSafeTx(
            SAFE,
            MODULE,
            abi.encodeWithSignature("registerParser(address,address)", ONE_INCH_ROUTER, address(oneInchParser)),
            deployerPrivateKey
        );
        console.log("Registered OneInchParser for", ONE_INCH_ROUTER);

        // Register Paraswap parser
        _executeSafeTx(
            SAFE,
            MODULE,
            abi.encodeWithSignature("registerParser(address,address)", PARASWAP_ROUTER, address(paraswapParser)),
            deployerPrivateKey
        );
        console.log("Registered ParaswapParser for", PARASWAP_ROUTER);

        // Register KyberSwap parser
        _executeSafeTx(
            SAFE,
            MODULE,
            abi.encodeWithSignature("registerParser(address,address)", KYBERSWAP_ROUTER, address(kyberSwapParser)),
            deployerPrivateKey
        );
        console.log("Registered KyberSwapParser for", KYBERSWAP_ROUTER);

        console.log("");

        // ============ Register Swap Selectors ============

        console.log("Registering swap selectors...");

        // 1inch selectors
        bytes4[] memory oneInchSelectors = new bytes4[](4);
        oneInchSelectors[0] = 0x12aa3caf; // swap
        oneInchSelectors[1] = 0xf78dc253; // unoswapTo
        oneInchSelectors[2] = 0xbc80f1a8; // uniswapV3SwapTo
        oneInchSelectors[3] = 0x093d4fa5; // clipperSwapTo

        for (uint256 i = 0; i < oneInchSelectors.length; i++) {
            _executeSafeTx(
                SAFE,
                MODULE,
                abi.encodeWithSignature(
                    "registerSelector(bytes4,uint8)",
                    oneInchSelectors[i],
                    uint8(1) // SWAP
                ),
                deployerPrivateKey
            );
        }
        console.log("Registered 1inch selectors:", oneInchSelectors.length);

        // Paraswap selectors
        bytes4[] memory paraswapSelectors = new bytes4[](7);
        paraswapSelectors[0] = 0xe3ead59e; // swapExactAmountIn
        paraswapSelectors[1] = 0x4c1ca4e9; // swapExactAmountOut
        paraswapSelectors[2] = 0x54840d1a; // swapExactAmountInOnUniswapV2
        paraswapSelectors[3] = 0x876a02f6; // swapExactAmountInOnUniswapV3
        paraswapSelectors[4] = 0x54e3f31b; // simpleSwap
        paraswapSelectors[5] = 0xa94e78ef; // multiSwap
        paraswapSelectors[6] = 0x46c67b6d; // megaSwap

        for (uint256 i = 0; i < paraswapSelectors.length; i++) {
            _executeSafeTx(
                SAFE,
                MODULE,
                abi.encodeWithSignature(
                    "registerSelector(bytes4,uint8)",
                    paraswapSelectors[i],
                    uint8(1) // SWAP
                ),
                deployerPrivateKey
            );
        }
        console.log("Registered Paraswap selectors:", paraswapSelectors.length);

        // KyberSwap selectors
        bytes4[] memory kyberSwapSelectors = new bytes4[](3);
        kyberSwapSelectors[0] = 0xe21fd0e9; // swap
        kyberSwapSelectors[1] = 0x8af033fb; // swapSimpleMode
        kyberSwapSelectors[2] = 0x59e50fed; // swapGeneric

        for (uint256 i = 0; i < kyberSwapSelectors.length; i++) {
            _executeSafeTx(
                SAFE,
                MODULE,
                abi.encodeWithSignature(
                    "registerSelector(bytes4,uint8)",
                    kyberSwapSelectors[i],
                    uint8(1) // SWAP
                ),
                deployerPrivateKey
            );
        }
        console.log("Registered KyberSwap selectors:", kyberSwapSelectors.length);

        console.log("");

        // ============ Whitelist Aggregators for Subaccounts ============

        console.log("Whitelisting aggregators for subaccounts...");

        address[] memory aggregators = new address[](3);
        aggregators[0] = ONE_INCH_ROUTER;
        aggregators[1] = PARASWAP_ROUTER;
        aggregators[2] = KYBERSWAP_ROUTER;

        for (uint256 i = 0; i < SUBACCOUNTS.length; i++) {
            _executeSafeTx(
                SAFE,
                MODULE,
                abi.encodeWithSignature(
                    "setAllowedAddresses(address,address[],bool)", SUBACCOUNTS[i], aggregators, true
                ),
                deployerPrivateKey
            );
            console.log("Whitelisted aggregators for subaccount", i + 1);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("OneInchParser:", address(oneInchParser));
        console.log("ParaswapParser:", address(paraswapParser));
        console.log("KyberSwapParser:", address(kyberSwapParser));
    }
}
