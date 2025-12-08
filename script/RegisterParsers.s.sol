// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/**
 * @title RegisterParsers
 * @notice Register parsers on DeFiInteractorModule via Safe transaction
 * @dev For 1-1 Safe where deployer is the owner
 */
contract RegisterParsers is Script {
    // Safe domain separator typehash
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");

    // Safe transaction typehash
    bytes32 private constant SAFE_TX_TYPEHASH =
        keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)");

    // Sepolia protocol addresses
    address constant AAVE_V3_POOL_SEPOLIA = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant UNISWAP_V3_ROUTER_SEPOLIA = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;

    // Deployed parser addresses
    address constant AAVE_PARSER = 0xF01eEF519FEf0EEf74DbD61EF403D36Fc9862BC4;
    address constant UNISWAP_PARSER = 0xf5248372F8be8b08D89dF092146e3a340a135B88;

    // Module address
    address constant MODULE = 0x70778aD876eE8964218149b93f521E681C3CB90f;

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Register Parsers via Safe ===");
        console.log("Safe:", safe);
        console.log("Module:", MODULE);
        console.log("Signer:", deployer);

        // Register Aave parser
        console.log("\n--- Registering AaveV3Parser ---");
        executeSafeTx(
            safe,
            deployerPrivateKey,
            MODULE,
            abi.encodeWithSignature("registerParser(address,address)", AAVE_V3_POOL_SEPOLIA, AAVE_PARSER)
        );
        console.log("AaveV3Parser registered for:", AAVE_V3_POOL_SEPOLIA);

        // Register Uniswap parser
        console.log("\n--- Registering UniswapV3Parser ---");
        executeSafeTx(
            safe,
            deployerPrivateKey,
            MODULE,
            abi.encodeWithSignature("registerParser(address,address)", UNISWAP_V3_ROUTER_SEPOLIA, UNISWAP_PARSER)
        );
        console.log("UniswapV3Parser registered for:", UNISWAP_V3_ROUTER_SEPOLIA);

        console.log("\n=== All Parsers Registered ===");
    }

    function executeSafeTx(
        address safe,
        uint256 signerKey,
        address to,
        bytes memory data
    ) internal {
        // Get Safe's nonce
        (bool success, bytes memory result) = safe.staticcall(
            abi.encodeWithSignature("nonce()")
        );
        require(success, "Failed to get nonce");
        uint256 nonce = abi.decode(result, (uint256));
        console.log("Safe nonce:", nonce);

        // Build Safe transaction hash
        bytes32 safeTxHash = getSafeTxHash(
            safe,
            to,
            0,
            data,
            0,
            0,
            0,
            0,
            address(0),
            address(0),
            nonce
        );

        // Sign the transaction
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, safeTxHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startBroadcast(signerKey);

        // Execute transaction on Safe
        (bool execSuccess, bytes memory execResult) = safe.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                to,
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
