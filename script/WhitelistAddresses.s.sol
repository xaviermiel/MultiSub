// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title WhitelistAddresses
 * @notice Add or remove allowed addresses (tokens, protocols) for a subaccount
 * @dev Executes via Safe transaction since Safe is the module owner
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address (owner of the module)
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - SUB_ACCOUNT_ADDRESS: The sub-account wallet address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *   - ADDRESSES: Comma-separated list of addresses to whitelist/blacklist
 *   - ALLOW: true to whitelist, false to remove (default: true)
 *
 * Usage:
 *   # Whitelist addresses
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... SUB_ACCOUNT_ADDRESS=0x... \
 *   ADDRESSES=0xToken1,0xToken2,0xProtocol \
 *   forge script script/WhitelistAddresses.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 *
 *   # Remove addresses from whitelist
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... SUB_ACCOUNT_ADDRESS=0x... \
 *   ADDRESSES=0xToken1,0xToken2 ALLOW=false \
 *   forge script script/WhitelistAddresses.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract WhitelistAddresses is Script, SafeTxHelper {
    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        address subAccount = vm.envAddress("SUB_ACCOUNT_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory addressesStr = vm.envString("ADDRESSES");
        bool allow = vm.envOr("ALLOW", true);

        console.log("=== Whitelist Addresses ===");
        console.log("Safe:", safe);
        console.log("Module:", module);
        console.log("Sub-account:", subAccount);
        console.log("Action:", allow ? "WHITELIST" : "REMOVE");

        // Parse addresses
        address[] memory addresses = _parseAddresses(addressesStr);
        require(addresses.length > 0, "No addresses provided");

        console.log("Addresses to process:", addresses.length);
        for (uint256 i = 0; i < addresses.length; i++) {
            console.log("  -", addresses[i]);
        }

        vm.startBroadcast(deployerPrivateKey);

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "setAllowedAddresses(address,address[],bool)",
            subAccount,
            addresses,
            allow
        ), deployerPrivateKey);

        vm.stopBroadcast();

        console.log("\n=== Done ===");
        console.log(allow ? "Whitelisted" : "Removed", addresses.length, "addresses");
    }

    function _parseAddresses(string memory input) internal pure returns (address[] memory) {
        bytes memory inputBytes = bytes(input);
        if (inputBytes.length == 0) {
            return new address[](0);
        }

        // Count addresses (commas + 1)
        uint256 count = 1;
        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == ",") count++;
        }

        address[] memory result = new address[](count);
        uint256 resultIndex = 0;
        uint256 start = 0;

        for (uint256 i = 0; i <= inputBytes.length; i++) {
            if (i == inputBytes.length || inputBytes[i] == ",") {
                // Extract address string
                bytes memory addrBytes = new bytes(i - start);
                uint256 writeIndex = 0;
                for (uint256 j = start; j < i; j++) {
                    // Skip spaces
                    if (inputBytes[j] != " ") {
                        addrBytes[writeIndex++] = inputBytes[j];
                    }
                }

                // Trim to actual length
                bytes memory trimmed = new bytes(writeIndex);
                for (uint256 k = 0; k < writeIndex; k++) {
                    trimmed[k] = addrBytes[k];
                }

                if (trimmed.length > 0) {
                    result[resultIndex++] = vm.parseAddress(string(trimmed));
                }
                start = i + 1;
            }
        }

        // Trim result if needed
        if (resultIndex < count) {
            address[] memory trimmedResult = new address[](resultIndex);
            for (uint256 i = 0; i < resultIndex; i++) {
                trimmedResult[i] = result[i];
            }
            return trimmedResult;
        }

        return result;
    }
}
