// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";

/**
 * @title AaveV3Parser
 * @notice Calldata parser for Aave V3 Pool and RewardsController operations
 * @dev Extracts token/amount from Aave V3 function calldata
 *
 * SECURITY NOTE:
 * - BORROW is intentionally not supported. Borrowing creates debt against Safe's collateral
 *   and could be exploited to bypass spending limits. Only the multisig should borrow.
 * - REPAY is classified as WITHDRAW (free operation) since repaying debt improves Safe's health.
 */
contract AaveV3Parser is ICalldataParser {
    error UnsupportedSelector();

    // Aave V3 Pool function selectors
    bytes4 public constant SUPPLY_SELECTOR = 0x617ba037;      // supply(address,uint256,address,uint16)
    bytes4 public constant WITHDRAW_SELECTOR = 0x69328dec;    // withdraw(address,uint256,address)
    // BORROW_SELECTOR intentionally not supported - only multisig can borrow
    bytes4 public constant REPAY_SELECTOR = 0x573ade81;       // repay(address,uint256,uint256,address)

    // Aave V3 RewardsController selectors (CLAIM operations)
    bytes4 public constant CLAIM_REWARDS_SELECTOR = 0x236300dc;           // claimRewards(address[],uint256,address,address)
    bytes4 public constant CLAIM_REWARDS_ON_BEHALF_SELECTOR = 0x33028b99; // claimRewardsOnBehalf(address[],uint256,address,address,address)
    bytes4 public constant CLAIM_ALL_REWARDS_SELECTOR = 0xbb492bf5;       // claimAllRewards(address[],address)
    bytes4 public constant CLAIM_ALL_ON_BEHALF_SELECTOR = 0x9ff55db9;     // claimAllRewardsOnBehalf(address[],address,address)

    /// @inheritdoc ICalldataParser
    function extractInputToken(address, bytes calldata data) external pure override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR || selector == REPAY_SELECTOR) {
            // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
            // repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
            return abi.decode(data[4:], (address));
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
            return amount;
        } else if (_isClaimSelector(selector)) {
            // CLAIM operations don't have input amounts
            return 0;
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractOutputToken(address target, bytes calldata data) external view override returns (address token) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR) {
            // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
            // Output is the aToken for the supplied asset
            address asset = abi.decode(data[4:], (address));
            return IAavePool(target).getReserveData(asset).aTokenAddress;
        } else if (selector == REPAY_SELECTOR) {
            // repay doesn't produce output tokens (it burns debt tokens internally)
            return address(0);
        } else if (selector == WITHDRAW_SELECTOR) {
            // withdraw(address asset, uint256 amount, address to)
            return abi.decode(data[4:], (address));
        } else if (selector == CLAIM_REWARDS_SELECTOR) {
            // claimRewards(address[] assets, uint256 amount, address to, address reward)
            // reward token is the 4th parameter
            (, , , token) = abi.decode(data[4:], (address[], uint256, address, address));
            return token;
        } else if (selector == CLAIM_REWARDS_ON_BEHALF_SELECTOR) {
            // claimRewardsOnBehalf(address[] assets, uint256 amount, address user, address to, address reward)
            // reward token is the 5th parameter
            (, , , , token) = abi.decode(data[4:], (address[], uint256, address, address, address));
            return token;
        } else if (selector == CLAIM_ALL_REWARDS_SELECTOR || selector == CLAIM_ALL_ON_BEHALF_SELECTOR) {
            // claimAllRewards doesn't specify reward token in calldata
            // Returns address(0) - oracle tracks balance changes
            return address(0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address defaultRecipient) external pure override returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == SUPPLY_SELECTOR) {
            // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
            // onBehalfOf is where aTokens are minted - must be Safe
            (,, recipient,) = abi.decode(data[4:], (address, uint256, address, uint16));
        } else if (selector == WITHDRAW_SELECTOR) {
            // withdraw(address asset, uint256 amount, address to)
            // 'to' is where withdrawn tokens go
            (,, recipient) = abi.decode(data[4:], (address, uint256, address));
        } else if (selector == REPAY_SELECTOR) {
            // repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
            // onBehalfOf is whose debt is repaid - must be Safe
            (,,, recipient) = abi.decode(data[4:], (address, uint256, uint256, address));
        } else if (selector == CLAIM_REWARDS_SELECTOR) {
            // claimRewards(address[] assets, uint256 amount, address to, address reward)
            // 'to' is where rewards go
            (,, recipient,) = abi.decode(data[4:], (address[], uint256, address, address));
        } else if (selector == CLAIM_REWARDS_ON_BEHALF_SELECTOR) {
            // claimRewardsOnBehalf(address[] assets, uint256 amount, address user, address to, address reward)
            // 'to' is where rewards go (4th param)
            (,,, recipient,) = abi.decode(data[4:], (address[], uint256, address, address, address));
        } else if (selector == CLAIM_ALL_REWARDS_SELECTOR) {
            // claimAllRewards(address[] assets, address to)
            // 'to' is where rewards go
            (, recipient) = abi.decode(data[4:], (address[], address));
        } else if (selector == CLAIM_ALL_ON_BEHALF_SELECTOR) {
            // claimAllRewardsOnBehalf(address[] assets, address user, address to)
            // 'to' is where rewards go (3rd param)
            (,, recipient) = abi.decode(data[4:], (address[], address, address));
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == SUPPLY_SELECTOR ||
               selector == WITHDRAW_SELECTOR ||
               selector == REPAY_SELECTOR ||
               _isClaimSelector(selector);
        // NOTE: BORROW is intentionally NOT supported - only multisig can borrow
    }

    /**
     * @notice Get the operation type for the given calldata
     * @param data The calldata to analyze
     * @return opType 1=SWAP, 2=DEPOSIT, 3=WITHDRAW, 4=CLAIM, 5=APPROVE
     *
     * @dev REPAY is classified as WITHDRAW (free operation) because:
     *      - It improves the Safe's health factor by reducing debt
     *      - It doesn't increase risk exposure
     *      - Subaccounts should be free to repay debt without spending checks
     */
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == SUPPLY_SELECTOR) {
            return 2; // DEPOSIT - costs spending for original tokens
        } else if (selector == WITHDRAW_SELECTOR || selector == REPAY_SELECTOR) {
            // REPAY is free (classified as WITHDRAW) - improves Safe health
            return 3; // WITHDRAW
        } else if (_isClaimSelector(selector)) {
            return 4; // CLAIM
        }
        // NOTE: BORROW is not supported - will revert with UnsupportedSelector
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
