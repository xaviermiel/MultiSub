// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title AaveV3Parser
 * @notice Calldata parser for Aave V3 Pool and RewardsController operations
 * @dev Extracts token/amount from Aave V3 function calldata
 */
contract AaveV3Parser is ICalldataParser {
    error UnsupportedSelector();

    // Aave V3 Pool function selectors
    bytes4 public constant SUPPLY_SELECTOR = 0x617ba037;      // supply(address,uint256,address,uint16)
    bytes4 public constant WITHDRAW_SELECTOR = 0x69328dec;    // withdraw(address,uint256,address)
    bytes4 public constant BORROW_SELECTOR = 0xa415bcad;      // borrow(address,uint256,uint256,uint16,address)
    bytes4 public constant REPAY_SELECTOR = 0x573ade81;       // repay(address,uint256,uint256,address)

    // Aave V3 RewardsController selectors (CLAIM operations)
    bytes4 public constant CLAIM_REWARDS_SELECTOR = 0x3111e7b3;           // claimRewards(address[],uint256,address,address)
    bytes4 public constant CLAIM_REWARDS_ON_BEHALF_SELECTOR = 0x9a99b4f0; // claimRewardsOnBehalf(address[],uint256,address,address,address)
    bytes4 public constant CLAIM_ALL_REWARDS_SELECTOR = 0x74d945ec;       // claimAllRewards(address[],address)
    bytes4 public constant CLAIM_ALL_ON_BEHALF_SELECTOR = 0x0c3fea64;     // claimAllRewardsOnBehalf(address[],address,address)

    /// @inheritdoc ICalldataParser
    function extractInputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR || selector == REPAY_SELECTOR) {
            // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
            // repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
            token = abi.decode(data[4:], (address));
        } else if (_isClaimSelector(selector)) {
            // CLAIM operations don't have input tokens
            return address(0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmount(address, bytes calldata data) external pure override returns (uint256 amount) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR || selector == REPAY_SELECTOR) {
            // supply(address asset, uint256 amount, ...)
            // repay(address asset, uint256 amount, ...)
            (, amount) = abi.decode(data[4:], (address, uint256));
        } else if (_isClaimSelector(selector)) {
            // CLAIM operations don't have input amounts
            return 0;
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractOutputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == WITHDRAW_SELECTOR) {
            // withdraw(address asset, uint256 amount, address to)
            token = abi.decode(data[4:], (address));
        } else if (selector == BORROW_SELECTOR) {
            // borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
            token = abi.decode(data[4:], (address));
        } else if (selector == CLAIM_REWARDS_SELECTOR) {
            // claimRewards(address[] assets, uint256 amount, address to, address reward)
            // reward token is the 4th parameter
            (, , , token) = abi.decode(data[4:], (address[], uint256, address, address));
        } else if (selector == CLAIM_REWARDS_ON_BEHALF_SELECTOR) {
            // claimRewardsOnBehalf(address[] assets, uint256 amount, address user, address to, address reward)
            // reward token is the 5th parameter
            (, , , , token) = abi.decode(data[4:], (address[], uint256, address, address, address));
        } else if (selector == CLAIM_ALL_REWARDS_SELECTOR || selector == CLAIM_ALL_ON_BEHALF_SELECTOR) {
            // claimAllRewards doesn't specify reward token in calldata
            // Returns address(0) - oracle tracks balance changes
            return address(0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == SUPPLY_SELECTOR ||
               selector == WITHDRAW_SELECTOR ||
               selector == BORROW_SELECTOR ||
               selector == REPAY_SELECTOR ||
               _isClaimSelector(selector);
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
        } else if (_isClaimSelector(selector)) {
            return 4; // CLAIM
        }
        return 0; // UNKNOWN
    }

    /**
     * @notice Check if selector is a CLAIM operation
     */
    function _isClaimSelector(bytes4 selector) internal pure returns (bool) {
        return selector == CLAIM_REWARDS_SELECTOR ||
               selector == CLAIM_REWARDS_ON_BEHALF_SELECTOR ||
               selector == CLAIM_ALL_REWARDS_SELECTOR ||
               selector == CLAIM_ALL_ON_BEHALF_SELECTOR;
    }
}
