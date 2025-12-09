// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";

/**
 * @title RegisterSelectors
 * @notice Register function selectors for Aave and Uniswap operations
 * @dev Must be executed via Safe transaction since Safe is the owner
 */
contract RegisterSelectors is Script {
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");

    bytes32 private constant SAFE_TX_TYPEHASH =
        keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)");

    // ERC20
    bytes4 constant APPROVE_SELECTOR = 0x095ea7b3; // approve(address,uint256)

    // Aave V3 Pool
    bytes4 constant AAVE_SUPPLY_SELECTOR = 0x617ba037;   // supply(address,uint256,address,uint16)
    bytes4 constant AAVE_WITHDRAW_SELECTOR = 0x69328dec; // withdraw(address,uint256,address)
    bytes4 constant AAVE_BORROW_SELECTOR = 0xa415bcad;   // borrow(address,uint256,uint256,uint16,address)
    bytes4 constant AAVE_REPAY_SELECTOR = 0x573ade81;    // repay(address,uint256,uint256,address)

    // Uniswap V3
    bytes4 constant EXACT_INPUT_SINGLE_SELECTOR = 0x414bf389;
    bytes4 constant EXACT_INPUT_SELECTOR = 0xc04b8d59;
    bytes4 constant EXACT_OUTPUT_SINGLE_SELECTOR = 0xdb3e2198;
    bytes4 constant EXACT_OUTPUT_SELECTOR = 0xf28c0498;

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== Register Selectors ===");
        console.log("Module:", module);

        vm.startBroadcast(deployerPrivateKey);

        // Register APPROVE
        console.log("\n1. Registering APPROVE selector...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)",
            APPROVE_SELECTOR,
            uint8(DeFiInteractorModule.OperationType.APPROVE)
        ), deployerPrivateKey);

        // Register Aave selectors
        console.log("2. Registering AAVE_SUPPLY selector...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)",
            AAVE_SUPPLY_SELECTOR,
            uint8(DeFiInteractorModule.OperationType.DEPOSIT)
        ), deployerPrivateKey);

        console.log("3. Registering AAVE_WITHDRAW selector...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)",
            AAVE_WITHDRAW_SELECTOR,
            uint8(DeFiInteractorModule.OperationType.WITHDRAW)
        ), deployerPrivateKey);

        console.log("4. Registering AAVE_BORROW selector...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)",
            AAVE_BORROW_SELECTOR,
            uint8(DeFiInteractorModule.OperationType.WITHDRAW)
        ), deployerPrivateKey);

        console.log("5. Registering AAVE_REPAY selector...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)",
            AAVE_REPAY_SELECTOR,
            uint8(DeFiInteractorModule.OperationType.DEPOSIT)
        ), deployerPrivateKey);

        // Register Uniswap selectors
        console.log("6. Registering EXACT_INPUT_SINGLE selector...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)",
            EXACT_INPUT_SINGLE_SELECTOR,
            uint8(DeFiInteractorModule.OperationType.SWAP)
        ), deployerPrivateKey);

        console.log("7. Registering EXACT_INPUT selector...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)",
            EXACT_INPUT_SELECTOR,
            uint8(DeFiInteractorModule.OperationType.SWAP)
        ), deployerPrivateKey);

        console.log("8. Registering EXACT_OUTPUT_SINGLE selector...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)",
            EXACT_OUTPUT_SINGLE_SELECTOR,
            uint8(DeFiInteractorModule.OperationType.SWAP)
        ), deployerPrivateKey);

        console.log("9. Registering EXACT_OUTPUT selector...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerSelector(bytes4,uint8)",
            EXACT_OUTPUT_SELECTOR,
            uint8(DeFiInteractorModule.OperationType.SWAP)
        ), deployerPrivateKey);

        vm.stopBroadcast();

        console.log("\n=== All Selectors Registered ===");
    }

    function _executeSafeTx(
        address safe,
        address to,
        bytes memory data,
        uint256 signerKey
    ) internal {
        (bool success, bytes memory result) = safe.staticcall(
            abi.encodeWithSignature("nonce()")
        );
        require(success, "Failed to get nonce");
        uint256 nonce = abi.decode(result, (uint256));

        bytes32 safeTxHash = _getSafeTxHash(safe, to, 0, data, 0, 0, 0, 0, address(0), address(0), nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, safeTxHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        (bool execSuccess, bytes memory execResult) = safe.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                to, 0, data, uint8(0), 0, 0, 0, address(0), payable(address(0)), signature
            )
        );
        require(execSuccess, "execTransaction call failed");
        require(abi.decode(execResult, (bool)), "Safe transaction returned false");
    }

    function _getSafeTxHash(
        address safe, address to, uint256 value, bytes memory data,
        uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice,
        address gasToken, address refundReceiver, uint256 nonce
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, block.chainid, safe));
        bytes32 safeTxHash = keccak256(abi.encode(
            SAFE_TX_TYPEHASH, to, value, keccak256(data), operation,
            safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, nonce
        ));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, safeTxHash));
    }
}
