// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "../src/parsers/AaveV3Parser.sol";
import "../src/parsers/UniswapV3Parser.sol";
import "../src/parsers/UniswapV4Parser.sol";
import "../src/parsers/UniversalRouterParser.sol";
import "../src/parsers/MorphoParser.sol";
import "../src/parsers/MerklParser.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title ConfigureParsersAndSelectors
 * @notice Deploy all parsers, register them with protocols, and register all selectors
 * @dev Executes via Safe transaction since Safe is the module owner
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address (owner of the module)
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *
 * Usage:
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... \
 *   forge script script/ConfigureParsersAndSelectors.s.sol \
 *     --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract ConfigureParsersAndSelectors is Script, SafeTxHelper {
    // ============ Protocol Addresses (Sepolia) ============
    address constant AAVE_V3_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant AAVE_V3_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant UNISWAP_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant NONFUNGIBLE_POSITION_MANAGER = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address constant UNISWAP_V4_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address constant PANCAKESWAP_UNIVERSAL_ROUTER = 0x55D32fa7Da7290838347bc97cb7fAD4992672255;
    address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    // ============ Selectors ============
    bytes4 constant APPROVE_SELECTOR = 0x095ea7b3;
    bytes4 constant AAVE_SUPPLY = 0x617ba037;
    bytes4 constant AAVE_WITHDRAW = 0x69328dec;
    bytes4 constant AAVE_BORROW = 0xa415bcad;
    bytes4 constant AAVE_REPAY = 0x573ade81;
    bytes4 constant AAVE_CLAIM_REWARDS = 0x236300dc;            // claimRewards(address[],uint256,address,address)
    bytes4 constant AAVE_CLAIM_REWARDS_ON_BEHALF = 0x33028b99;  // claimRewardsOnBehalf(address[],uint256,address,address,address)
    bytes4 constant AAVE_CLAIM_ALL_REWARDS = 0xbb492bf5;        // claimAllRewards(address[],address)
    bytes4 constant AAVE_CLAIM_ALL_ON_BEHALF = 0x9ff55db9;      // claimAllRewardsOnBehalf(address[],address,address)
    bytes4 constant EXACT_INPUT_SINGLE = 0x414bf389;
    bytes4 constant EXACT_INPUT = 0xc04b8d59;
    bytes4 constant EXACT_OUTPUT_SINGLE = 0xdb3e2198;
    bytes4 constant EXACT_OUTPUT = 0xf28c0498;
    bytes4 constant EXACT_INPUT_SINGLE_V2 = 0x04e45aaf;
    bytes4 constant EXACT_INPUT_V2 = 0xb858183f;
    bytes4 constant EXACT_OUTPUT_SINGLE_V2 = 0x5023b4df;
    bytes4 constant EXACT_OUTPUT_V2 = 0x09b81346;
    bytes4 constant NPM_MINT = 0x88316456;
    bytes4 constant NPM_INCREASE_LIQUIDITY = 0x219f5d17;
    bytes4 constant NPM_DECREASE_LIQUIDITY = 0x0c49ccbe;
    bytes4 constant NPM_COLLECT = 0xfc6f7865;
    bytes4 constant MODIFY_LIQUIDITIES = 0xdd46508f;
    bytes4 constant UNIVERSAL_EXECUTE = 0x3593564c;
    bytes4 constant MORPHO_DEPOSIT = 0x6e553f65;
    bytes4 constant MORPHO_MINT = 0x94bf804d;
    bytes4 constant MORPHO_WITHDRAW = 0xb460af94;
    bytes4 constant MORPHO_REDEEM = 0xba087652;
    bytes4 constant MERKL_CLAIM = 0x71ee95c0;

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== Configure Parsers and Selectors ===");
        console.log("Safe:", safe);
        console.log("Module:", module);

        vm.startBroadcast(deployerPrivateKey);

        // ============ Deploy Parsers ============
        console.log("\n--- Deploying Parsers ---");

        AaveV3Parser aaveParser = new AaveV3Parser();
        console.log("AaveV3Parser:", address(aaveParser));

        UniswapV3Parser uniV3Parser = new UniswapV3Parser();
        console.log("UniswapV3Parser:", address(uniV3Parser));

        UniswapV4Parser uniV4Parser = new UniswapV4Parser();
        console.log("UniswapV4Parser:", address(uniV4Parser));

        UniversalRouterParser universalParser = new UniversalRouterParser();
        console.log("UniversalRouterParser:", address(universalParser));

        MorphoParser morphoParser = new MorphoParser();
        console.log("MorphoParser:", address(morphoParser));

        MerklParser merklParser = new MerklParser();
        console.log("MerklParser:", address(merklParser));

        // ============ Register Parsers via Safe ============
        console.log("\n--- Registering Parsers ---");

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", AAVE_V3_POOL, address(aaveParser)
        ), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", AAVE_V3_REWARDS, address(aaveParser)
        ), deployerPrivateKey);
        console.log("Aave V3 Pool & Rewards -> AaveV3Parser");

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", UNISWAP_V3_ROUTER, address(uniV3Parser)
        ), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", NONFUNGIBLE_POSITION_MANAGER, address(uniV3Parser)
        ), deployerPrivateKey);
        console.log("Uniswap V3 Router & NPM -> UniswapV3Parser");

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", UNISWAP_V4_POSITION_MANAGER, address(uniV4Parser)
        ), deployerPrivateKey);
        console.log("Uniswap V4 PositionManager -> UniswapV4Parser");

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", UNIVERSAL_ROUTER, address(universalParser)
        ), deployerPrivateKey);
        console.log("Uniswap Universal Router -> UniversalRouterParser");

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", PANCAKESWAP_UNIVERSAL_ROUTER, address(universalParser)
        ), deployerPrivateKey);
        console.log("PancakeSwap Universal Router -> UniversalRouterParser");

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", MERKL_DISTRIBUTOR, address(merklParser)
        ), deployerPrivateKey);
        console.log("Merkl Distributor -> MerklParser");

        // ============ Register Selectors via Safe ============
        console.log("\n--- Registering Selectors ---");

        // ERC20
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)", APPROVE_SELECTOR, uint8(5)
        ), deployerPrivateKey);
        console.log("approve -> APPROVE");

        // Aave V3 Pool
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_SUPPLY, uint8(2)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_WITHDRAW, uint8(3)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_BORROW, uint8(3)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_REPAY, uint8(2)), deployerPrivateKey);
        console.log("Aave supply/repay -> DEPOSIT, withdraw/borrow -> WITHDRAW");

        // Aave V3 Rewards
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_CLAIM_REWARDS, uint8(4)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_CLAIM_REWARDS_ON_BEHALF, uint8(4)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_CLAIM_ALL_REWARDS, uint8(4)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_CLAIM_ALL_ON_BEHALF, uint8(4)), deployerPrivateKey);
        console.log("Aave claim* -> CLAIM");

        // Uniswap V3 SwapRouter
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", EXACT_INPUT_SINGLE, uint8(1)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", EXACT_INPUT, uint8(1)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", EXACT_OUTPUT_SINGLE, uint8(1)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", EXACT_OUTPUT, uint8(1)), deployerPrivateKey);
        console.log("Uniswap V3 exactInput*/exactOutput* -> SWAP");

        // Uniswap V3 SwapRouter02 variants
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", EXACT_INPUT_SINGLE_V2, uint8(1)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", EXACT_INPUT_V2, uint8(1)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", EXACT_OUTPUT_SINGLE_V2, uint8(1)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", EXACT_OUTPUT_V2, uint8(1)), deployerPrivateKey);
        console.log("Uniswap V3 SwapRouter02 variants -> SWAP");

        // NonfungiblePositionManager
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", NPM_MINT, uint8(2)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", NPM_INCREASE_LIQUIDITY, uint8(2)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", NPM_DECREASE_LIQUIDITY, uint8(3)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", NPM_COLLECT, uint8(4)), deployerPrivateKey);
        console.log("NPM mint/increase -> DEPOSIT, decrease -> WITHDRAW, collect -> CLAIM");

        // Uniswap V4
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", MODIFY_LIQUIDITIES, uint8(2)), deployerPrivateKey);
        console.log("V4 modifyLiquidities -> DEPOSIT (parser handles dynamic classification)");

        // Universal Router
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", UNIVERSAL_EXECUTE, uint8(1)), deployerPrivateKey);
        console.log("Universal Router execute -> SWAP");

        // Morpho
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", MORPHO_DEPOSIT, uint8(2)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", MORPHO_MINT, uint8(2)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", MORPHO_WITHDRAW, uint8(3)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", MORPHO_REDEEM, uint8(3)), deployerPrivateKey);
        console.log("Morpho deposit/mint -> DEPOSIT, withdraw/redeem -> WITHDRAW");

        // Merkl
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", MERKL_CLAIM, uint8(4)), deployerPrivateKey);
        console.log("Merkl claim -> CLAIM");

        vm.stopBroadcast();

        console.log("\n=== Configuration Complete ===");
    }
}
