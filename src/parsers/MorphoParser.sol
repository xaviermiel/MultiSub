// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";
import {IMorphoVault} from "../interfaces/IMorphoVault.sol";

/**
 * @title MorphoParser
 * @notice Calldata parser for Morpho Vault (ERC4626) operations
 * @dev Extracts token/amount from Morpho Vault function calldata
 *      ERC4626 functions don't include token address in calldata,
 *      so this parser queries the vault's asset() function
 */
contract MorphoParser is ICalldataParser {
    error UnsupportedSelector();

    // ERC4626 function selectors
    bytes4 public constant DEPOSIT_SELECTOR = 0x6e553f65;   // deposit(uint256,address)
    bytes4 public constant MINT_SELECTOR = 0x94bf804d;      // mint(uint256,address)
    bytes4 public constant WITHDRAW_SELECTOR = 0xb460af94;  // withdraw(uint256,address,address)
    bytes4 public constant REDEEM_SELECTOR = 0xba087652;    // redeem(uint256,address,address)

    /// @inheritdoc ICalldataParser
    function extractInputToken(address target, bytes calldata data) external view override returns (address) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == DEPOSIT_SELECTOR || selector == MINT_SELECTOR) {
            // Query the vault for its underlying asset
            return IMorphoVault(target).asset();
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmount(address target, bytes calldata data) external view override returns (uint256 amount) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == DEPOSIT_SELECTOR) {
            // deposit(uint256 assets, address receiver)
            (amount,) = abi.decode(data[4:], (uint256, address));
        } else if (selector == MINT_SELECTOR) {
            // mint(uint256 shares, address receiver)
            // Convert shares to assets using previewMint
            (uint256 shares,) = abi.decode(data[4:], (uint256, address));
            amount = IMorphoVault(target).previewMint(shares);
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function extractOutputTokens(address target, bytes calldata data) external view override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == DEPOSIT_SELECTOR || selector == MINT_SELECTOR) {
            // For ERC4626 deposits, output is vault shares (the vault token itself)
            tokens = new address[](1);
            tokens[0] = target;
            return tokens;
        } else if (selector == WITHDRAW_SELECTOR || selector == REDEEM_SELECTOR) {
            // Query the vault for its underlying asset
            tokens = new address[](1);
            tokens[0] = IMorphoVault(target).asset();
            return tokens;
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address) external pure override returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == DEPOSIT_SELECTOR || selector == MINT_SELECTOR) {
            // deposit(uint256 assets, address receiver)
            // mint(uint256 shares, address receiver)
            // receiver is where vault shares go
            (, recipient) = abi.decode(data[4:], (uint256, address));
        } else if (selector == WITHDRAW_SELECTOR || selector == REDEEM_SELECTOR) {
            // withdraw(uint256 assets, address receiver, address owner)
            // redeem(uint256 shares, address receiver, address owner)
            // receiver is where underlying tokens go
            (, recipient,) = abi.decode(data[4:], (uint256, address, address));
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == DEPOSIT_SELECTOR ||
               selector == MINT_SELECTOR ||
               selector == WITHDRAW_SELECTOR ||
               selector == REDEEM_SELECTOR;
    }

    /**
     * @notice Get the operation type for the given calldata
     * @param data The calldata to analyze
     * @return opType 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     */
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == DEPOSIT_SELECTOR || selector == MINT_SELECTOR) {
            return 2; // DEPOSIT
        } else if (selector == WITHDRAW_SELECTOR || selector == REDEEM_SELECTOR) {
            return 3; // WITHDRAW
        }
        return 0; // UNKNOWN
    }
}
