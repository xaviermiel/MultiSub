// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";

/**
 * @title DeployDeFiModule
 * @notice Script to deploy the DeFiInteractorModule as a Zodiac module
 * @dev Run with: forge script script/DeployDeFiModule.s.sol --rpc-url $RPC_URL --broadcast
 */
contract DeployDeFiModule is Script {
    function run() external {
        // Get deployment parameters from environment
        address safe = vm.envAddress("SAFE_ADDRESS");
        address authorizedUpdater = vm.envAddress("AUTHORIZED_UPDATER");

        console.log("Deploying DeFiInteractorModule with:");
        console.log("  Safe (Avatar/Owner):", safe);
        console.log("  Authorized Updater:", authorizedUpdater);

        vm.startBroadcast();

        // Deploy DeFiInteractorModule
        // Avatar = Safe, Owner = Safe (for configuration), AuthorizedUpdater = Chainlink CRE Proxy
        DeFiInteractorModule module = new DeFiInteractorModule(safe, safe, authorizedUpdater);
        console.log("DeFiInteractorModule deployed at:", address(module));

        vm.stopBroadcast();

        // Log deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("DeFiInteractorModule:", address(module));
        console.log("Avatar (Safe):", module.avatar());
        console.log("Target (Safe):", module.target());
        console.log("Owner (Safe):", module.owner());

        console.log("\n=== Next Steps ===");
        console.log("1. Enable the module on the Safe:");
        console.log("   Safe.enableModule(%s)", address(module));
        console.log("\n2. Configure sub-accounts and roles:");
        console.log("   module.grantRole(subAccountAddress, ROLE_ID)");
        console.log("   module.setSubAccountLimits(...)");
        console.log("   module.setAllowedAddresses(...)");
        console.log("\n3. Sub-accounts can now execute DeFi operations:");
        console.log("   module.approveProtocol(token, protocol, amount)");
        console.log("   module.executeOnProtocol(protocol, calldata)");
        console.log("   module.transferToken(token, recipient, amount)");
    }
}
