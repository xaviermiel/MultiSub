// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title MorphoBlueParser
 * @notice Calldata parser for Morpho Blue lending protocol operations
 * @dev Extracts token/amount from Morpho Blue function calldata
 *
 * Morpho Blue functions use MarketParams struct to identify markets:
 * struct MarketParams {
 *     address loanToken;
 *     address collateralToken;
 *     address oracle;
 *     address irm;
 *     uint256 lltv;
 * }
 *
 * Supported operations:
 * - supply: Supply loanToken to earn yield (DEPOSIT)
 * - withdraw: Withdraw supplied loanToken (WITHDRAW)
 * - repay: Repay borrowed loanToken (DEPOSIT)
 * - supplyCollateral: Supply collateralToken (DEPOSIT)
 * - withdrawCollateral: Withdraw collateralToken (WITHDRAW)
 *
 * NOTE: borrow is intentionally not supported - only multisig can borrow directly
 */
contract MorphoBlueParser is ICalldataParser {
    error UnsupportedSelector();

    // Morpho Blue function selectors
    // supply((address,address,address,address,uint256),uint256,uint256,address,bytes)
    bytes4 public constant SUPPLY_SELECTOR = 0xa99aad89;
    // withdraw((address,address,address,address,uint256),uint256,uint256,address,address)
    bytes4 public constant WITHDRAW_SELECTOR = 0x5c2bea49;
    // borrow((address,address,address,address,uint256),uint256,uint256,address,address)
    bytes4 public constant BORROW_SELECTOR = 0x50d8cd4b;
    // repay((address,address,address,address,uint256),uint256,uint256,address,bytes)
    bytes4 public constant REPAY_SELECTOR = 0x20b76e81;
    // supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)
    bytes4 public constant SUPPLY_COLLATERAL_SELECTOR = 0x238d6579;
    // withdrawCollateral((address,address,address,address,uint256),uint256,address,address)
    bytes4 public constant WITHDRAW_COLLATERAL_SELECTOR = 0x8720316d;

    // Offsets in calldata (after 4-byte selector)
    // MarketParams struct (160 bytes total):
    uint256 private constant LOAN_TOKEN_OFFSET = 0;
    uint256 private constant COLLATERAL_TOKEN_OFFSET = 32;
    // oracle at 64, irm at 96, lltv at 128

    // For supply/withdraw/borrow/repay (after MarketParams):
    uint256 private constant ASSETS_OFFSET = 160;
    uint256 private constant SHARES_OFFSET = 192;
    uint256 private constant ON_BEHALF_OFFSET = 224;
    uint256 private constant RECEIVER_OFFSET = 256; // for withdraw/borrow

    // For supplyCollateral/withdrawCollateral (no shares parameter):
    uint256 private constant COLLATERAL_ASSETS_OFFSET = 160;
    uint256 private constant COLLATERAL_ON_BEHALF_OFFSET = 192;
    uint256 private constant COLLATERAL_RECEIVER_OFFSET = 224; // for withdrawCollateral

    /// @inheritdoc ICalldataParser
    function extractInputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR || selector == REPAY_SELECTOR) {
            // Supply/Repay: input is loanToken
            tokens = new address[](1);
            tokens[0] = _extractLoanToken(data);
            return tokens;
        } else if (selector == SUPPLY_COLLATERAL_SELECTOR) {
            // SupplyCollateral: input is collateralToken
            tokens = new address[](1);
            tokens[0] = _extractCollateralToken(data);
            return tokens;
        } else if (selector == WITHDRAW_SELECTOR || selector == WITHDRAW_COLLATERAL_SELECTOR) {
            // Withdraw/WithdrawCollateral: no input tokens (receiving tokens)
            return new address[](0);
        }
        // BORROW_SELECTOR intentionally not supported - reverts here
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmounts(address, bytes calldata data) external pure override returns (uint256[] memory amounts) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR || selector == REPAY_SELECTOR) {
            // Supply/Repay: assets amount at standard offset
            amounts = new uint256[](1);
            amounts[0] = _extractAssets(data);
            return amounts;
        } else if (selector == SUPPLY_COLLATERAL_SELECTOR) {
            // SupplyCollateral: assets at collateral offset (no shares param)
            amounts = new uint256[](1);
            amounts[0] = _extractCollateralAssets(data);
            return amounts;
        } else if (selector == WITHDRAW_SELECTOR || selector == WITHDRAW_COLLATERAL_SELECTOR) {
            // Withdraw/WithdrawCollateral: no input amounts
            return new uint256[](0);
        }
        // BORROW_SELECTOR intentionally not supported - reverts here
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractOutputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == WITHDRAW_SELECTOR) {
            // Withdraw: output is loanToken
            tokens = new address[](1);
            tokens[0] = _extractLoanToken(data);
            return tokens;
        } else if (selector == WITHDRAW_COLLATERAL_SELECTOR) {
            // WithdrawCollateral: output is collateralToken
            tokens = new address[](1);
            tokens[0] = _extractCollateralToken(data);
            return tokens;
        } else if (selector == SUPPLY_SELECTOR || selector == REPAY_SELECTOR || selector == SUPPLY_COLLATERAL_SELECTOR) {
            // Supply/Repay/SupplyCollateral: no output tokens (internal accounting)
            return new address[](0);
        }
        // BORROW_SELECTOR intentionally not supported - reverts here
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address defaultRecipient) external pure override returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR || selector == REPAY_SELECTOR) {
            // Supply/Repay: onBehalf is where position is credited
            recipient = _extractOnBehalf(data);
        } else if (selector == WITHDRAW_SELECTOR) {
            // Withdraw: receiver is where tokens go
            recipient = _extractReceiver(data);
        } else if (selector == SUPPLY_COLLATERAL_SELECTOR) {
            // SupplyCollateral: onBehalf at collateral offset
            recipient = _extractCollateralOnBehalf(data);
        } else if (selector == WITHDRAW_COLLATERAL_SELECTOR) {
            // WithdrawCollateral: receiver at collateral offset
            recipient = _extractCollateralReceiver(data);
        } else {
            // BORROW_SELECTOR intentionally not supported - reverts here
            revert UnsupportedSelector();
        }

        // If recipient is zero, use default (Safe address)
        if (recipient == address(0)) {
            recipient = defaultRecipient;
        }
    }

    /// @inheritdoc ICalldataParser
    /// @dev BORROW_SELECTOR intentionally excluded - only multisig can borrow
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == SUPPLY_SELECTOR ||
               selector == WITHDRAW_SELECTOR ||
               selector == REPAY_SELECTOR ||
               selector == SUPPLY_COLLATERAL_SELECTOR ||
               selector == WITHDRAW_COLLATERAL_SELECTOR;
    }

    /**
     * @notice Get the operation type for the given calldata
     * @param data The calldata to analyze
     * @return opType 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     * @dev BORROW_SELECTOR returns 0 (UNKNOWN) as it is not supported
     */
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR ||
            selector == REPAY_SELECTOR ||
            selector == SUPPLY_COLLATERAL_SELECTOR) {
            return 2; // DEPOSIT - costs spending
        } else if (selector == WITHDRAW_SELECTOR ||
                   selector == WITHDRAW_COLLATERAL_SELECTOR) {
            return 3; // WITHDRAW - free operation
        }
        // BORROW_SELECTOR intentionally returns 0 (UNKNOWN) - not supported
        return 0; // UNKNOWN
    }

    // ============ Internal Helpers ============

    function _extractLoanToken(bytes calldata data) internal pure returns (address) {
        return address(uint160(uint256(bytes32(data[4 + LOAN_TOKEN_OFFSET:4 + LOAN_TOKEN_OFFSET + 32]))));
    }

    function _extractCollateralToken(bytes calldata data) internal pure returns (address) {
        return address(uint160(uint256(bytes32(data[4 + COLLATERAL_TOKEN_OFFSET:4 + COLLATERAL_TOKEN_OFFSET + 32]))));
    }

    function _extractAssets(bytes calldata data) internal pure returns (uint256) {
        return uint256(bytes32(data[4 + ASSETS_OFFSET:4 + ASSETS_OFFSET + 32]));
    }

    function _extractOnBehalf(bytes calldata data) internal pure returns (address) {
        return address(uint160(uint256(bytes32(data[4 + ON_BEHALF_OFFSET:4 + ON_BEHALF_OFFSET + 32]))));
    }

    function _extractReceiver(bytes calldata data) internal pure returns (address) {
        return address(uint160(uint256(bytes32(data[4 + RECEIVER_OFFSET:4 + RECEIVER_OFFSET + 32]))));
    }

    // For supplyCollateral/withdrawCollateral (different offsets due to no shares param)
    function _extractCollateralAssets(bytes calldata data) internal pure returns (uint256) {
        return uint256(bytes32(data[4 + COLLATERAL_ASSETS_OFFSET:4 + COLLATERAL_ASSETS_OFFSET + 32]));
    }

    function _extractCollateralOnBehalf(bytes calldata data) internal pure returns (address) {
        return address(uint160(uint256(bytes32(data[4 + COLLATERAL_ON_BEHALF_OFFSET:4 + COLLATERAL_ON_BEHALF_OFFSET + 32]))));
    }

    function _extractCollateralReceiver(bytes calldata data) internal pure returns (address) {
        return address(uint160(uint256(bytes32(data[4 + COLLATERAL_RECEIVER_OFFSET:4 + COLLATERAL_RECEIVER_OFFSET + 32]))));
    }
}
