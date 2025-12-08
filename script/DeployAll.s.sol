// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "../src/parsers/AaveV3Parser.sol";
import "../src/parsers/UniswapV3Parser.sol";

/**
 * @title DeployAll
 * @notice Deploy DeFiInteractorModule and parsers
 * @dev Run with: forge script script/DeployAll.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
 *
 * NOTE: Parser registration must be done via Safe transaction since the Safe is the owner
 */
contract DeployAll is Script {
    // Sepolia Aave V3 addresses
    address constant AAVE_V3_POOL_SEPOLIA = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;

    // Sepolia Uniswap V3 addresses
    address constant UNISWAP_V3_ROUTER_SEPOLIA = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;

    function run() external {
        // Get deployment parameters from environment
        address safe = vm.envAddress("SAFE_ADDRESS");
        address authorizedUpdater = vm.envAddress("AUTHORIZED_UPDATER");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== Deployment Parameters ===");
        console.log("Safe (Avatar/Owner):", safe);
        console.log("Authorized Updater:", authorizedUpdater);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy DeFiInteractorModule
        console.log("\n=== Deploying DeFiInteractorModule ===");
        DeFiInteractorModule module = new DeFiInteractorModule(safe, safe, authorizedUpdater);
        console.log("DeFiInteractorModule deployed at:", address(module));

        // 2. Deploy AaveV3Parser
        console.log("\n=== Deploying AaveV3Parser ===");
        AaveV3Parser aaveParser = new AaveV3Parser();
        console.log("AaveV3Parser deployed at:", address(aaveParser));

        // 3. Deploy UniswapV3Parser
        console.log("\n=== Deploying UniswapV3Parser ===");
        UniswapV3Parser uniswapParser = new UniswapV3Parser();
        console.log("UniswapV3Parser deployed at:", address(uniswapParser));

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("DeFiInteractorModule:", address(module));
        console.log("AaveV3Parser:", address(aaveParser));
        console.log("UniswapV3Parser:", address(uniswapParser));

        console.log("\n=== Next Steps (via Safe transactions) ===");
        console.log("1. Update .env with DEFI_MODULE_ADDRESS=%s", address(module));
        console.log("2. Enable module on Safe: safe.enableModule(%s)", address(module));
        console.log("3. Register Aave parser: module.registerParser(%s, %s)", AAVE_V3_POOL_SEPOLIA, address(aaveParser));
        console.log("4. Register Uniswap parser: module.registerParser(%s, %s)", UNISWAP_V3_ROUTER_SEPOLIA, address(uniswapParser));
        console.log("5. Configure sub-accounts with roles and limits");
    }
}
