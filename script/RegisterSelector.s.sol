// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title RegisterSelector
 * @notice Register a single function selector with its operation type
 * @dev Executes via Safe transaction since Safe is the module owner
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address (owner of the module)
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *   - SELECTOR: The 4-byte function selector (e.g., 0x095ea7b3 for approve)
 *   - OPERATION_TYPE: The operation type (1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE)
 *
 * Usage:
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... SELECTOR=0x095ea7b3 OPERATION_TYPE=5 \
 *   forge script script/RegisterSelector.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract RegisterSelector is Script, SafeTxHelper {
    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        bytes4 selector = bytes4(vm.envBytes32("SELECTOR"));
        uint8 operationType = uint8(vm.envUint("OPERATION_TYPE"));

        string memory opName;
        if (operationType == 1) opName = "SWAP";
        else if (operationType == 2) opName = "DEPOSIT";
        else if (operationType == 3) opName = "WITHDRAW";
        else if (operationType == 4) opName = "CLAIM";
        else if (operationType == 5) opName = "APPROVE";
        else opName = "UNKNOWN";

        console.log("=== Register Selector ===");
        console.log("Safe:", safe);
        console.log("Module:", module);
        console.logBytes4(selector);
        console.log("Operation type:", operationType, opName);

        vm.startBroadcast(deployerPrivateKey);

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)",
            selector,
            operationType
        ), deployerPrivateKey);

        vm.stopBroadcast();

        console.log("\n=== Selector Registered ===");
    }
}
