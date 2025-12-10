// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title ConfigureSubaccount
 * @notice Configure a sub-account with role, spending limits, and whitelisted addresses
 * @dev Executes via Safe transaction since Safe is the module owner
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address (owner of the module)
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - SUB_ACCOUNT_ADDRESS: The sub-account wallet address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *   - MAX_SPENDING_BPS: Max spending in basis points (default: 500 = 5%)
 *   - WINDOW_DURATION: Time window in seconds (default: 86400 = 1 day)
 *   - GRANT_TRANSFER_ROLE: Whether to grant transfer role (default: false)
 *
 * Usage:
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... SUB_ACCOUNT_ADDRESS=0x... \
 *   forge script script/ConfigureSubaccount.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract ConfigureSubaccount is Script, SafeTxHelper {
    // ============ Protocol Addresses (Sepolia) ============
    address constant AAVE_V3_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant AAVE_V3_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant UNISWAP_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant NONFUNGIBLE_POSITION_MANAGER = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address constant UNISWAP_V4_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        address subAccount = vm.envAddress("SUB_ACCOUNT_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 maxSpendingBps = vm.envOr("MAX_SPENDING_BPS", uint256(500));
        uint256 windowDuration = vm.envOr("WINDOW_DURATION", uint256(1 days));
        bool grantTransfer = vm.envOr("GRANT_TRANSFER_ROLE", false);

        DeFiInteractorModule defiModule = DeFiInteractorModule(module);

        console.log("=== Configure Sub-Account ===");
        console.log("Safe:", safe);
        console.log("Module:", module);
        console.log("Sub-account:", subAccount);
        console.log("Max spending:", maxSpendingBps, "bps");
        console.log("Window duration:", windowDuration, "seconds");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Grant DEFI_EXECUTE_ROLE
        console.log("\n1. Granting DEFI_EXECUTE_ROLE...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "grantRole(address,uint16)",
            subAccount,
            defiModule.DEFI_EXECUTE_ROLE()
        ), deployerPrivateKey);
        console.log("   Done");

        // 2. Optionally grant DEFI_TRANSFER_ROLE
        if (grantTransfer) {
            console.log("\n2. Granting DEFI_TRANSFER_ROLE...");
            _executeSafeTx(safe, module, abi.encodeWithSignature(
                "grantRole(address,uint16)",
                subAccount,
                defiModule.DEFI_TRANSFER_ROLE()
            ), deployerPrivateKey);
            console.log("   Done");
        } else {
            console.log("\n2. Skipping DEFI_TRANSFER_ROLE (not requested)");
        }

        // 3. Set spending limits
        console.log("\n3. Setting spending limits...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "setSubAccountLimits(address,uint256,uint256)",
            subAccount,
            maxSpendingBps,
            windowDuration
        ), deployerPrivateKey);
        console.log("   Done");

        // 4. Whitelist protocol addresses
        console.log("\n4. Whitelisting protocol addresses...");
        address[] memory protocols = new address[](7);
        protocols[0] = AAVE_V3_POOL;
        protocols[1] = AAVE_V3_REWARDS;
        protocols[2] = UNISWAP_V3_ROUTER;
        protocols[3] = NONFUNGIBLE_POSITION_MANAGER;
        protocols[4] = UNISWAP_V4_POSITION_MANAGER;
        protocols[5] = UNIVERSAL_ROUTER;
        protocols[6] = MERKL_DISTRIBUTOR;

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "setAllowedAddresses(address,address[],bool)",
            subAccount,
            protocols,
            true
        ), deployerPrivateKey);
        console.log("   Whitelisted:", protocols.length, "protocols");

        vm.stopBroadcast();

        console.log("\n=== Configuration Complete ===");
        console.log("Sub-account:", subAccount);
    }
}
