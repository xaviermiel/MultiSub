// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "../src/interfaces/ISafe.sol";
/**
 * @title EnableModuleDirect
 * @notice Enable a module on a 1-1 Safe by directly calling execTransaction with proper signature
 *
 * This works for a Safe with:
 * - Single owner (threshold = 1)
 * - You have the owner's private key
 *
 * The script signs the Safe transaction hash and calls execTransaction
 *
 * Usage:
 * SAFE_ADDRESS=0x... \
 * MODULE_ADDRESS=0x... \
 * forge script script/EnableModuleDirect.s.sol:EnableModuleDirect \
 *   --rpc-url <RPC_URL> \
 *   --broadcast \
 *   --private-key $DEPLOYER_PRIVATE_KEY
 */
contract EnableModuleDirect is Script {
    // Safe domain separator typehash
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");

    // Safe transaction typehash
    bytes32 private constant SAFE_TX_TYPEHASH =
        keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)");

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address moduleToEnable = vm.envAddress("MODULE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        DeFiInteractorModule module = DeFiInteractorModule(moduleToEnable);

        console.log("=== Enable Roles on 1-1 Safe ===");
        console.log("Safe:", safe);
        console.log("Signer:", deployer);
        console.log("");

        // Get Safe's nonce
        (bool success, bytes memory result) = safe.staticcall(
            abi.encodeWithSignature("nonce()")
        );
        require(success, "Failed to get nonce");
        uint256 nonce = abi.decode(result, (uint256));
        console.log("Safe nonce:", nonce);

        // Build enableModule calldata
        bytes memory enableModuleData = abi.encodeWithSignature(
            "grantRole(address, uint16)",
            deployer,
            module.DEFI_EXECUTE_ROLE()
        );

        // Build Safe transaction hash
        bytes32 safeTxHash = getSafeTxHash(
            safe,
            safe,           // to: Safe itself
            0,              // value
            enableModuleData,
            0,              // operation (CALL, will be delegatecall internally by Safe)
            0,              // safeTxGas
            0,              // baseGas
            0,              // gasPrice
            address(0),     // gasToken
            address(0),     // refundReceiver
            nonce
        );

        console.log("SafeTx hash:");
        console.logBytes32(safeTxHash);

        // Sign the transaction
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPrivateKey, safeTxHash);

        // Encode signature (r, s, v format for Safe)
        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("Signature generated");
        console.log("v:", uint256(v));
        console.log("r:");
        console.logBytes32(r);
        console.log("s:");
        console.logBytes32(s);

        vm.startBroadcast(deployerPrivateKey);

        // Execute transaction on Safe
        (bool execSuccess, bytes memory execResult) = safe.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                safe,               // to
                0,                  // value
                enableModuleData,   // data
                uint8(0),          // operation
                0,                  // safeTxGas
                0,                  // baseGas
                0,                  // gasPrice
                address(0),         // gasToken
                payable(address(0)), // refundReceiver
                signature           // signatures
            )
        );

        require(execSuccess, "execTransaction failed");

        vm.stopBroadcast();

        console.log("");
        console.log("SUCCESS!");
        console.log("");
    }

    function getSafeTxHash(
        address safe,
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) internal view returns (bytes32) {
        // Get domain separator
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                block.chainid,
                safe
            )
        );

        // Encode Safe transaction
        bytes32 safeTxHash = keccak256(
            abi.encode(
                SAFE_TX_TYPEHASH,
                to,
                value,
                keccak256(data),
                operation,
                safeTxGas,
                baseGas,
                gasPrice,
                gasToken,
                refundReceiver,
                nonce
            )
        );

        // Return EIP-712 hash
        return keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x01),
                domainSeparator,
                safeTxHash
            )
        );
    }
}
