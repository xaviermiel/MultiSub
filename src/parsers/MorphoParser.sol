// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";
import {IMorphoVault} from "../interfaces/IMorphoVault.sol";

/**
 * @title MorphoParser
 * @notice Calldata parser for Morpho Vault (ERC4626) operations
 * @dev Extracts token/amount from Morpho Vault function calldata
 *      Note: ERC4626 functions don't include token address in calldata,
 *      so token extraction requires querying the vault's asset() function
 */
contract MorphoParser is ICalldataParser {
    // ERC4626 function selectors
    bytes4 public constant DEPOSIT_SELECTOR = 0x6e553f65;   // deposit(uint256,address)
    bytes4 public constant MINT_SELECTOR = 0x94bf804d;      // mint(uint256,address)
    bytes4 public constant WITHDRAW_SELECTOR = 0xb460af94;  // withdraw(uint256,address,address)
    bytes4 public constant REDEEM_SELECTOR = 0xba087652;    // redeem(uint256,address,address)

    /// @inheritdoc ICalldataParser
    function extractInputToken(bytes calldata data) external pure override returns (address) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == DEPOSIT_SELECTOR || selector == MINT_SELECTOR) {
            // ERC4626 deposit/mint don't include token in calldata
            // Token must be obtained from vault.asset()
            // Return address(0) to signal "use vault.asset()"
            return address(0);
        }
        revert("MorphoParser: unsupported selector for input token");
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmount(bytes calldata data) external pure override returns (uint256 amount) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == DEPOSIT_SELECTOR) {
            // deposit(uint256 assets, address receiver)
            (amount,) = abi.decode(data[4:], (uint256, address));
        } else if (selector == MINT_SELECTOR) {
            // mint(uint256 shares, address receiver)
            // Note: This is shares, not assets - may need conversion
            (amount,) = abi.decode(data[4:], (uint256, address));
        } else {
            revert("MorphoParser: unsupported selector for input amount");
        }
    }

    /// @inheritdoc ICalldataParser
    function extractOutputToken(bytes calldata data) external pure override returns (address) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == WITHDRAW_SELECTOR || selector == REDEEM_SELECTOR) {
            // ERC4626 withdraw/redeem don't include token in calldata
            // Token must be obtained from vault.asset()
            // Return address(0) to signal "use vault.asset()"
            return address(0);
        }
        revert("MorphoParser: unsupported selector for output token");
    }

    /// @inheritdoc ICalldataParser
    function extractApproveSpender(bytes calldata) external pure override returns (address) {
        revert("MorphoParser: approve not handled by this parser");
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == DEPOSIT_SELECTOR ||
               selector == MINT_SELECTOR ||
               selector == WITHDRAW_SELECTOR ||
               selector == REDEEM_SELECTOR;
    }

    /**
     * @notice Get the operation type for a given selector
     * @param selector The function selector
     * @return opType 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     */
    function getOperationType(bytes4 selector) external pure returns (uint8 opType) {
        if (selector == DEPOSIT_SELECTOR || selector == MINT_SELECTOR) {
            return 2; // DEPOSIT
        } else if (selector == WITHDRAW_SELECTOR || selector == REDEEM_SELECTOR) {
            return 3; // WITHDRAW
        }
        return 0; // UNKNOWN
    }

    /**
     * @notice Extract the underlying asset from a Morpho vault
     * @dev This is a view function that queries the vault
     * @param vault The Morpho vault address
     * @return asset The underlying asset address
     */
    function getVaultAsset(address vault) external view returns (address asset) {
        return IMorphoVault(vault).asset();
    }

    /**
     * @notice Extract amount from withdraw/redeem calldata
     * @param data The calldata
     * @return amount The assets/shares amount
     */
    function extractWithdrawAmount(bytes calldata data) external pure returns (uint256 amount) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == WITHDRAW_SELECTOR) {
            // withdraw(uint256 assets, address receiver, address owner)
            (amount,,) = abi.decode(data[4:], (uint256, address, address));
        } else if (selector == REDEEM_SELECTOR) {
            // redeem(uint256 shares, address receiver, address owner)
            (amount,,) = abi.decode(data[4:], (uint256, address, address));
        } else {
            revert("MorphoParser: unsupported selector for withdraw amount");
        }
    }
}
