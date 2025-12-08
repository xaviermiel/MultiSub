// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/**
 * @title SetAuthorizedOracle
 * @notice Set the authorized oracle address via Safe transaction
 * @dev For 1-1 Safe where deployer is the owner
 */
contract SetAuthorizedOracle is Script {
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");

    bytes32 private constant SAFE_TX_TYPEHASH =
        keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)");

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        address newOracle = vm.envAddress("SUB_ACCOUNT_ADDRESS"); // Use SUB_ACCOUNT as oracle
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Set Authorized Oracle via Safe ===");
        console.log("Safe:", safe);
        console.log("Module:", module);
        console.log("New Oracle:", newOracle);
        console.log("Signer:", deployer);

        // Get Safe's nonce
        (bool success, bytes memory result) = safe.staticcall(
            abi.encodeWithSignature("nonce()")
        );
        require(success, "Failed to get nonce");
        uint256 nonce = abi.decode(result, (uint256));
        console.log("Safe nonce:", nonce);

        // Build setAuthorizedOracle calldata
        bytes memory data = abi.encodeWithSignature(
            "setAuthorizedOracle(address)",
            newOracle
        );

        // Build Safe transaction hash
        bytes32 safeTxHash = getSafeTxHash(
            safe,
            module,  // to: module
            0,       // value
            data,
            0,       // operation
            0,       // safeTxGas
            0,       // baseGas
            0,       // gasPrice
            address(0), // gasToken
            address(0), // refundReceiver
            nonce
        );

        // Sign the transaction
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPrivateKey, safeTxHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startBroadcast(deployerPrivateKey);

        // Execute transaction on Safe
        (bool execSuccess, bytes memory execResult) = safe.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                module,
                0,
                data,
                uint8(0),
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                signature
            )
        );

        require(execSuccess, "execTransaction failed");
        bool txSuccess = abi.decode(execResult, (bool));
        require(txSuccess, "Safe transaction returned false");

        vm.stopBroadcast();

        console.log("");
        console.log("SUCCESS! Authorized oracle updated to:", newOracle);
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
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_SEPARATOR_TYPEHASH, block.chainid, safe)
        );

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

        return keccak256(
            abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, safeTxHash)
        );
    }
}
