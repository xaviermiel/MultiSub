// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title AaveV3Parser
 * @notice Calldata parser for Aave V3 Pool operations
 * @dev Extracts token/amount from Aave V3 function calldata
 */
contract AaveV3Parser is ICalldataParser {
    // Aave V3 Pool function selectors
    bytes4 public constant SUPPLY_SELECTOR = 0x617ba037;      // supply(address,uint256,address,uint16)
    bytes4 public constant WITHDRAW_SELECTOR = 0x69328dec;    // withdraw(address,uint256,address)
    bytes4 public constant BORROW_SELECTOR = 0xa415bcad;      // borrow(address,uint256,uint256,uint16,address)
    bytes4 public constant REPAY_SELECTOR = 0x573ade81;       // repay(address,uint256,uint256,address)

    /// @inheritdoc ICalldataParser
    function extractInputToken(bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR || selector == REPAY_SELECTOR) {
            // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
            // repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
            token = abi.decode(data[4:], (address));
        } else {
            revert("AaveV3Parser: unsupported selector for input token");
        }
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmount(bytes calldata data) external pure override returns (uint256 amount) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR || selector == REPAY_SELECTOR) {
            // supply(address asset, uint256 amount, ...)
            // repay(address asset, uint256 amount, ...)
            (, amount) = abi.decode(data[4:], (address, uint256));
        } else {
            revert("AaveV3Parser: unsupported selector for input amount");
        }
    }

    /// @inheritdoc ICalldataParser
    function extractOutputToken(bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == WITHDRAW_SELECTOR) {
            // withdraw(address asset, uint256 amount, address to)
            token = abi.decode(data[4:], (address));
        } else if (selector == BORROW_SELECTOR) {
            // borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
            token = abi.decode(data[4:], (address));
        } else {
            revert("AaveV3Parser: unsupported selector for output token");
        }
    }

    /// @inheritdoc ICalldataParser
    function extractApproveSpender(bytes calldata) external pure override returns (address) {
        revert("AaveV3Parser: approve not handled by this parser");
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == SUPPLY_SELECTOR ||
               selector == WITHDRAW_SELECTOR ||
               selector == BORROW_SELECTOR ||
               selector == REPAY_SELECTOR;
    }

    /**
     * @notice Get the operation type for a given selector
     * @param selector The function selector
     * @return opType 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     */
    function getOperationType(bytes4 selector) external pure returns (uint8 opType) {
        if (selector == SUPPLY_SELECTOR || selector == REPAY_SELECTOR) {
            return 2; // DEPOSIT
        } else if (selector == WITHDRAW_SELECTOR || selector == BORROW_SELECTOR) {
            return 3; // WITHDRAW
        }
        return 0; // UNKNOWN
    }
}
