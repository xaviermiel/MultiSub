// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title RegisterParser
 * @notice Register a parser for a specific protocol address
 * @dev Executes via Safe transaction since Safe is the module owner
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address (owner of the module)
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *   - PROTOCOL_ADDRESS: The protocol contract address to register the parser for
 *   - PARSER_ADDRESS: The parser contract address
 *
 * Usage:
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... \
 *   PROTOCOL_ADDRESS=0xProtocol PARSER_ADDRESS=0xParser \
 *   forge script script/RegisterParser.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract RegisterParser is Script, SafeTxHelper {
    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address protocol = vm.envAddress("PROTOCOL_ADDRESS");
        address parser = vm.envAddress("PARSER_ADDRESS");

        console.log("=== Register Parser ===");
        console.log("Safe:", safe);
        console.log("Module:", module);
        console.log("Protocol:", protocol);
        console.log("Parser:", parser);

        vm.startBroadcast(deployerPrivateKey);

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)",
            protocol,
            parser
        ), deployerPrivateKey);

        vm.stopBroadcast();

        console.log("\n=== Parser Registered ===");
        console.log("Protocol", protocol, "-> Parser", parser);
    }
}
