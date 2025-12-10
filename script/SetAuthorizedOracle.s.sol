// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title SetAuthorizedOracle
 * @notice Set the authorized oracle address via Safe transaction
 * @dev Executes via Safe transaction since Safe is the module owner
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address (owner of the module)
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *   - ORACLE_ADDRESS: The new oracle address to authorize
 *
 * Usage:
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... ORACLE_ADDRESS=0x... \
 *   forge script script/SetAuthorizedOracle.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract SetAuthorizedOracle is Script, SafeTxHelper {
    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        address newOracle = vm.envAddress("ORACLE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Set Authorized Oracle via Safe ===");
        console.log("Safe:", safe);
        console.log("Module:", module);
        console.log("New Oracle:", newOracle);
        console.log("Signer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "setAuthorizedOracle(address)",
            newOracle
        ), deployerPrivateKey);

        vm.stopBroadcast();

        console.log("");
        console.log("SUCCESS! Authorized oracle updated to:", newOracle);
    }
}
