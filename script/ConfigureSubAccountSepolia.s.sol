// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";

/**
 * @title ConfigureSubAccountSepolia
 * @notice Configure a sub-account with DEFI_EXECUTE_ROLE and whitelist Aave/Uniswap on Sepolia
 * @dev For 1-1 Safe where deployer is the owner. Executes multiple Safe transactions.
 *
 * Usage:
 * SAFE_ADDRESS=0x6E7692fFE42ca2A3FA2b08611AA7e79A2AaA8e8C \
 * DEFI_MODULE_ADDRESS=0x70778aD876eE8964218149b93f521E681C3CB90f \
 * SUB_ACCOUNT_ADDRESS=0x962aCEB4C3C53f09110106D08364A8B40eA54568 \
 * forge script script/ConfigureSubAccountSepolia.s.sol:ConfigureSubAccountSepolia \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --private-key $DEPLOYER_PRIVATE_KEY
 */
contract ConfigureSubAccountSepolia is Script {
    // Safe EIP-712 typehashes
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");

    bytes32 private constant SAFE_TX_TYPEHASH =
        keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)");

    // ============ Sepolia Protocol Addresses ============
    // Aave V3 Sepolia
    address constant AAVE_V3_POOL_SEPOLIA = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant AAVE_V3_REWARDS_SEPOLIA = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb; // Note: May differ on Sepolia

    // Uniswap V3 Sepolia
    address constant UNISWAP_V3_ROUTER_SEPOLIA = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant UNISWAP_V3_ROUTER_02_SEPOLIA = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E; // SwapRouter02

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        address subAccount = vm.envAddress("SUB_ACCOUNT_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Optional: spending limits (default 10% over 24h)
        uint256 maxSpendingBps = vm.envOr("MAX_SPENDING_BPS", uint256(1000)); // 10%
        uint256 windowDuration = vm.envOr("WINDOW_DURATION", uint256(1 days));

        DeFiInteractorModule defiModule = DeFiInteractorModule(module);

        console.log("=== Configure Sub-Account on Sepolia ===");
        console.log("Safe:", safe);
        console.log("Module:", module);
        console.log("Sub-account:", subAccount);
        console.log("Signer:", deployer);
        console.log("Max spending: %s bps", maxSpendingBps);
        console.log("Window duration: %s seconds", windowDuration);
        console.log("");

        // Check if already has role
        bool hasRole = defiModule.hasRole(subAccount, defiModule.DEFI_EXECUTE_ROLE());
        console.log("Already has DEFI_EXECUTE_ROLE:", hasRole);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Grant DEFI_EXECUTE_ROLE
        if (!hasRole) {
            console.log("\n1. Granting DEFI_EXECUTE_ROLE...");
            _executeSafeTx(
                safe,
                module,
                abi.encodeWithSignature(
                    "grantRole(address,uint16)",
                    subAccount,
                    defiModule.DEFI_EXECUTE_ROLE()
                ),
                deployerPrivateKey
            );
            console.log("   DONE: Granted DEFI_EXECUTE_ROLE");
        } else {
            console.log("\n1. SKIPPED: Already has DEFI_EXECUTE_ROLE");
        }

        // 2. Set sub-account spending limits
        console.log("\n2. Setting sub-account limits...");
        _executeSafeTx(
            safe,
            module,
            abi.encodeWithSignature(
                "setSubAccountLimits(address,uint256,uint256)",
                subAccount,
                maxSpendingBps,
                windowDuration
            ),
            deployerPrivateKey
        );
        console.log("   DONE: Set limits (%s bps, %s seconds)", maxSpendingBps, windowDuration);

        // 3. Whitelist Aave V3 Pool
        console.log("\n3. Whitelisting Aave V3 Pool...");
        address[] memory aaveAddresses = new address[](1);
        aaveAddresses[0] = AAVE_V3_POOL_SEPOLIA;
        _executeSafeTx(
            safe,
            module,
            abi.encodeWithSignature(
                "setAllowedAddresses(address,address[],bool)",
                subAccount,
                aaveAddresses,
                true
            ),
            deployerPrivateKey
        );
        console.log("   DONE: Whitelisted Aave V3 Pool (%s)", AAVE_V3_POOL_SEPOLIA);

        // 4. Whitelist Uniswap V3 Router
        console.log("\n4. Whitelisting Uniswap V3 Router...");
        address[] memory uniswapAddresses = new address[](1);
        uniswapAddresses[0] = UNISWAP_V3_ROUTER_SEPOLIA;
        _executeSafeTx(
            safe,
            module,
            abi.encodeWithSignature(
                "setAllowedAddresses(address,address[],bool)",
                subAccount,
                uniswapAddresses,
                true
            ),
            deployerPrivateKey
        );
        console.log("   DONE: Whitelisted Uniswap V3 Router (%s)", UNISWAP_V3_ROUTER_SEPOLIA);

        vm.stopBroadcast();

        console.log("\n=== Configuration Complete ===");
        console.log("Sub-account %s can now:", subAccount);
        console.log("  - Execute DeFi operations via the module");
        console.log("  - Interact with Aave V3 Pool: %s", AAVE_V3_POOL_SEPOLIA);
        console.log("  - Interact with Uniswap V3 Router: %s", UNISWAP_V3_ROUTER_SEPOLIA);
        console.log("  - Spend up to %s bps of Safe value per %s second window", maxSpendingBps, windowDuration);
    }

    function _executeSafeTx(
        address safe,
        address to,
        bytes memory data,
        uint256 signerKey
    ) internal {
        // Get Safe's current nonce
        (bool success, bytes memory result) = safe.staticcall(
            abi.encodeWithSignature("nonce()")
        );
        require(success, "Failed to get nonce");
        uint256 nonce = abi.decode(result, (uint256));

        // Build Safe transaction hash
        bytes32 safeTxHash = _getSafeTxHash(
            safe,
            to,
            0,       // value
            data,
            0,       // operation (CALL)
            0,       // safeTxGas
            0,       // baseGas
            0,       // gasPrice
            address(0), // gasToken
            address(0), // refundReceiver
            nonce
        );

        // Sign the transaction
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, safeTxHash);
        bytes memory signature = abi.encodePacked(r, s, v);

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

        require(execSuccess, "execTransaction call failed");
        bool txSuccess = abi.decode(execResult, (bool));
        require(txSuccess, "Safe transaction returned false");
    }

    function _getSafeTxHash(
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
