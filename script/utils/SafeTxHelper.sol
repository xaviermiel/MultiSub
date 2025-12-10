// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Vm.sol";

/**
 * @title SafeTxHelper
 * @notice Helper contract for executing Safe transactions in scripts
 * @dev Provides EIP-712 signing and execution for 1-of-1 Safe multisigs
 */
abstract contract SafeTxHelper {
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");

    bytes32 private constant SAFE_TX_TYPEHASH =
        keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)");

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _executeSafeTx(address safe, address to, bytes memory data, uint256 signerKey) internal {
        (bool success, bytes memory result) = safe.staticcall(abi.encodeWithSignature("nonce()"));
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
