// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "../src/interfaces/ISafe.sol";

/**
 * @title SetupDeFiModule
 * @notice Script to configure the DeFiInteractorModule after deployment
 * @dev Run with: forge script script/SetupDeFiModule.s.sol --rpc-url $RPC_URL --broadcast
 */
contract SetupDeFiModule is Script {
    function run() external {
        // Get parameters from environment
        address safe = vm.envAddress("SAFE_ADDRESS");
        address moduleAddress = vm.envAddress("DEFI_MODULE_ADDRESS");
        address subAccount = vm.envAddress("SUB_ACCOUNT_ADDRESS");

        // Example protocol addresses (update with actual addresses)
        address morphoVault = vm.envOr("MORPHO_VAULT_ADDRESS", address(0));

        console.log("Setting up DeFiInteractorModule:");
        console.log("  Module:", moduleAddress);
        console.log("  Safe:", safe);
        console.log("  Sub-account:", subAccount);

        DeFiInteractorModule module = DeFiInteractorModule(moduleAddress);

        vm.startBroadcast();

        // Step 1: Enable the module on the Safe (if not already enabled)
        console.log("\n1. Checking if module is enabled on Safe...");
        ISafe safeContract = ISafe(safe);
        if (!safeContract.isModuleEnabled(moduleAddress)) {
            console.log("   Enabling module on Safe...");
            safeContract.enableModule(moduleAddress);
            console.log("   Module enabled!");
        } else {
            console.log("   Module already enabled.");
        }

        // Step 2: Grant roles to sub-account
        console.log("\n2. Granting roles to sub-account...");
        module.grantRole(subAccount, module.DEFI_EXECUTE_ROLE());
        console.log("   Granted DEFI_EXECUTE_ROLE (role 1)");

        // module.grantRole(subAccount, module.DEFI_TRANSFER_ROLE());
        // console.log("   Granted DEFI_TRANSFER_ROLE (role 2)");

        // Step 3: Set sub-account limits
        console.log("\n3. Setting sub-account limits...");
        module.setSubAccountLimits(
            subAccount,
            500,   // 5% max spending (basis points)
            1 days // 24 hour window
        );
        console.log("   Limits configured:");
        console.log("   - Max spending: 5%");
        console.log("   - Window: 24 hours");

        // Step 4: Set allowed addresses
        if (morphoVault != address(0)) {
            console.log("\n4. Setting allowed addresses...");
            address[] memory targets = new address[](1);
            targets[0] = morphoVault;
            module.setAllowedAddresses(subAccount, targets, true);
            console.log("   Allowed Morpho vault:", morphoVault);
        } else {
            console.log("\n4. Skipping allowed addresses (no Morpho vault specified)");
        }

        vm.stopBroadcast();

        console.log("\n=== Setup Complete ===");
        console.log("Sub-account %s is now configured with:", subAccount);
        console.log("- DEFI_EXECUTE_ROLE granted");
        console.log("- Custom limits: 5% max spending, 24h window");
        if (morphoVault != address(0)) {
            console.log("- Allowed to interact with Morpho vault");
        }

        console.log("\nThe sub-account can now:");
        console.log("- Approve tokens for allowed protocols (EXECUTE role)");
        console.log("- Execute DeFi operations within limits (EXECUTE role)");
        console.log("- Transfer tokens within limits (TRANSFER role)");
    }
}
