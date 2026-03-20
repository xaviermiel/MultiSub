// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ModuleFactory.sol";
import "../src/ModuleRegistry.sol";
import "../src/interfaces/ISafe.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title DeployModuleViaFactory
 * @notice Deploy a DeFiInteractorModule for a Safe using the Factory
 * @dev Uses CREATE2 for deterministic addresses across chains
 *      The module is automatically registered in the Registry (if auto-register is enabled)
 *
 * Environment variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key of Factory owner AND Safe owner (for enableModule)
 *   - FACTORY_ADDRESS: Address of the deployed ModuleFactory
 *   - SAFE_ADDRESS: The Safe multisig address
 *   - AUTHORIZED_UPDATER: Address authorized to update safe value (e.g., Chainlink CRE proxy)
 *   - NONCE: (Optional) Nonce for CREATE2 salt, defaults to current nonce in factory
 *
 * Usage:
 *   FACTORY_ADDRESS=0x... SAFE_ADDRESS=0x... AUTHORIZED_UPDATER=0x... \
 *   forge script script/DeployModuleViaFactory.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract DeployModuleViaFactory is Script, SafeTxHelper {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address safe = vm.envAddress("SAFE_ADDRESS");
        address authorizedUpdater = vm.envAddress("AUTHORIZED_UPDATER");

        ModuleFactory factory = ModuleFactory(factoryAddress);
        uint256 nonce = vm.envOr("NONCE", factory.getNonce(safe));

        console.log("=== Deploy Module via Factory ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Factory:", factoryAddress);
        console.log("Safe:", safe);
        console.log("Authorized Updater:", authorizedUpdater);
        console.log("Nonce:", nonce);

        // Verify deployer is factory owner
        require(factory.owner() == deployer, "Deployer must be factory owner");

        // Predict the module address
        address predictedAddress = factory.computeModuleAddress(safe, authorizedUpdater, nonce);
        console.log("\nPredicted module address:", predictedAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the module via factory
        address module;
        if (nonce == factory.getNonce(safe)) {
            module = factory.deployModule(safe, authorizedUpdater);
        } else {
            module = factory.deployModuleWithNonce(safe, authorizedUpdater, nonce);
        }
        console.log("\n1. Module deployed at:", module);
        require(module == predictedAddress, "Module address mismatch");

        // 2. Enable module on Safe via execTransaction
        console.log("\n2. Enabling module on Safe...");
        _executeSafeTx(safe, safe, abi.encodeWithSignature("enableModule(address)", module), deployerPrivateKey);
        console.log("   Module enabled");

        vm.stopBroadcast();

        // Verify
        require(ISafe(safe).isModuleEnabled(module), "Module not enabled");

        // Check registry if auto-register is enabled
        if (factory.autoRegister()) {
            IModuleRegistry registry = factory.registry();
            require(registry.isRegistered(module), "Module not registered");
            console.log("\n3. Module registered in registry");
        }

        console.log("\n=== Deployment Complete ===");
        console.log("DeFiInteractorModule:", module);
        console.log("\nNext steps:");
        console.log("1. Run ConfigureParsersAndSelectors.s.sol with DEFI_MODULE_ADDRESS set to:", module);
        console.log("2. Run SetPriceFeeds.s.sol to configure Chainlink oracles");
        console.log("3. Run ConfigureSubaccount.s.sol to set up sub-accounts");
    }
}
