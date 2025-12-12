// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title WhitelistAddress
 * @notice Whitelist a protocol address for a specific sub-account
 * @dev Executes via Safe transaction since Safe is the module owner
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - SUB_ACCOUNT: The sub-account to whitelist for
 *   - TARGET_ADDRESS: The protocol address to whitelist
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *
 * Usage:
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... SUB_ACCOUNT=0x... TARGET_ADDRESS=0x... \
 *   forge script script/WhitelistAddress.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract WhitelistAddress is Script, SafeTxHelper {
    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        address subAccount = vm.envAddress("SUB_ACCOUNT");
        address target = vm.envAddress("TARGET_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== Whitelist Address ===");
        console.log("Safe:", safe);
        console.log("Module:", module);
        console.log("Sub-account:", subAccount);
        console.log("Target:", target);

        vm.startBroadcast(deployerPrivateKey);

        address[] memory targets = new address[](1);
        targets[0] = target;

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "setAllowedAddresses(address,address[],bool)",
            subAccount,
            targets,
            true
        ), deployerPrivateKey);

        vm.stopBroadcast();

        console.log("\n=== Whitelist Complete ===");
        console.log("Target", target, "whitelisted for", subAccount);
    }
}
