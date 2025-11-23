// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MultiSubPaymaster} from "../src/MultiSubPaymaster.sol";
import {SafeERC4337Account} from "../src/SafeERC4337Account.sol";
import {DeFiInteractorModule} from "../src/DeFiInteractorModule.sol";
import {IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

/**
 * @title DeployPaymaster
 * @notice Deploy script for MultiSub ERC-4337 Paymaster infrastructure
 *
 * This script deploys:
 * 1. SafeERC4337Account - Adapter to make Safe compatible with ERC-4337
 * 2. MultiSubPaymaster - Paymaster to sponsor gas for sub-accounts
 *
 * Prerequisites:
 * - Safe must be deployed
 * - DeFiInteractorModule must be deployed and enabled on Safe
 * - Backend signer address must be available
 *
 * Environment Variables:
 * - SAFE_ADDRESS: Address of the Safe multisig
 * - DEFI_MODULE_ADDRESS: Address of deployed DeFiInteractorModule
 * - PAYMASTER_SIGNER: Address of backend signer for paymaster authorization
 * - PAYMASTER_OWNER: Owner of the paymaster (can withdraw funds)
 * - INITIAL_DEPOSIT: Initial ETH to deposit to paymaster (in wei)
 *
 * Usage:
 * forge script script/DeployPaymaster.s.sol:DeployPaymaster --rpc-url sepolia --broadcast --verify
 */
contract DeployPaymaster is Script {
    // ERC-4337 EntryPoint v0.8.0 (canonical address)
    address constant ENTRYPOINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;

    // Configuration (can be overridden by environment variables)
    uint256 constant MAX_GAS_PER_OPERATION = 1_000_000; // 1M gas

    function run() external {
        // Load configuration from environment
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address defiModuleAddress = vm.envAddress("DEFI_MODULE_ADDRESS");
        address paymasterSigner = vm.envAddress("PAYMASTER_SIGNER");
        address paymasterOwner = vm.envAddress("PAYMASTER_OWNER");
        uint256 initialDeposit = vm.envOr("INITIAL_DEPOSIT", uint256(0.1 ether));

        console.log("=== MultiSub ERC-4337 Paymaster Deployment ===");
        console.log("Safe Address:", safeAddress);
        console.log("DeFi Module Address:", defiModuleAddress);
        console.log("EntryPoint:", ENTRYPOINT_V08);
        console.log("Paymaster Signer:", paymasterSigner);
        console.log("Paymaster Owner:", paymasterOwner);
        console.log("Initial Deposit:", initialDeposit);
        console.log("Max Gas Per Operation:", MAX_GAS_PER_OPERATION);

        vm.startBroadcast();

        // 1. Deploy SafeERC4337Account
        console.log("\n1. Deploying SafeERC4337Account...");
        SafeERC4337Account safeAccount = new SafeERC4337Account(
            safeAddress,
            ENTRYPOINT_V08
        );
        console.log("SafeERC4337Account deployed at:", address(safeAccount));

        // 2. Deploy MultiSubPaymaster
        console.log("\n2. Deploying MultiSubPaymaster...");
        MultiSubPaymaster paymaster = new MultiSubPaymaster(
            ENTRYPOINT_V08,
            defiModuleAddress,
            paymasterSigner,
            paymasterOwner,
            MAX_GAS_PER_OPERATION
        );
        console.log("MultiSubPaymaster deployed at:", address(paymaster));

        // 3. Fund the paymaster if initial deposit is provided
        if (initialDeposit > 0) {
            console.log("\n3. Funding paymaster with", initialDeposit, "wei");
            paymaster.deposit{value: initialDeposit}();
            console.log("Paymaster funded. Balance:", paymaster.getBalance());
        }

        vm.stopBroadcast();

        // Print deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("SafeERC4337Account:", address(safeAccount));
        console.log("MultiSubPaymaster:", address(paymaster));
        console.log("\n=== Next Steps ===");
        console.log("1. Enable SafeERC4337Account as a Safe module:");
        console.log("   cast send", safeAddress, '"enableModule(address)"', address(safeAccount));
        console.log("\n2. Verify SafeERC4337Account is enabled:");
        console.log("   cast call", address(safeAccount), '"isModuleEnabled()(bool)"');
        console.log("\n3. Fund paymaster if not already funded:");
        console.log("   cast send", address(paymaster), '"deposit()" --value 0.5ether');
        console.log("\n4. Check paymaster balance:");
        console.log("   cast call", address(paymaster), '"getBalance()(uint256)"');
    }
}
