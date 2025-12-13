// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeFiInteractorModuleBase} from "./base/DeFiInteractorModuleBase.t.sol";
import {DeFiInteractorModule} from "../src/DeFiInteractorModule.sol";
import {Module} from "../src/base/Module.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {MockChainlinkPriceFeed} from "./mocks/MockChainlinkPriceFeed.sol";
import {MockParser} from "./mocks/MockParser.sol";

/**
 * @title DeFiInteractorModuleTest
 * @notice Tests for DeFiInteractorModule with Acquired Balance Model
 */
contract DeFiInteractorModuleTest is DeFiInteractorModuleBase {

    // ============ Module Setup Tests ============

    function testModuleInitialization() public view {
        assertEq(module.avatar(), address(safe));
        assertEq(module.target(), address(safe));
        assertEq(module.owner(), owner);
    }

    function testModuleEnabled() public view {
        assertTrue(safe.isModuleEnabled(address(module)));
    }

    // ============ Role Management Tests ============

    function testGrantRole() public {
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        assertTrue(module.hasRole(subAccount1, module.DEFI_EXECUTE_ROLE()));
    }

    function testRevokeRole() public {
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        module.revokeRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        assertFalse(module.hasRole(subAccount1, module.DEFI_EXECUTE_ROLE()));
    }

    function testGrantRoleUnauthorized() public {
        vm.expectRevert(Module.Unauthorized.selector);
        vm.prank(subAccount1);
        module.grantRole(subAccount2, 1);
    }

    function testSubaccountArrayTracking() public {
        assertEq(module.getSubaccountCount(module.DEFI_EXECUTE_ROLE()), 0);

        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        assertEq(module.getSubaccountCount(module.DEFI_EXECUTE_ROLE()), 1);

        module.grantRole(subAccount2, module.DEFI_EXECUTE_ROLE());
        assertEq(module.getSubaccountCount(module.DEFI_EXECUTE_ROLE()), 2);

        address[] memory accounts = module.getSubaccountsByRole(module.DEFI_EXECUTE_ROLE());
        assertEq(accounts.length, 2);
    }

    function testRevokeRoleRemovesFromArray() public {
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        module.grantRole(subAccount2, module.DEFI_EXECUTE_ROLE());
        assertEq(module.getSubaccountCount(module.DEFI_EXECUTE_ROLE()), 2);

        module.revokeRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        assertEq(module.getSubaccountCount(module.DEFI_EXECUTE_ROLE()), 1);
    }

    // ============ Sub-Account Limits Tests ============

    function testSetSubAccountLimits() public {
        module.setSubAccountLimits(subAccount1, 1500, 2 days);

        (uint256 maxSpending, uint256 window) = module.getSubAccountLimits(subAccount1);

        assertEq(maxSpending, 1500);
        assertEq(window, 2 days);
    }

    function testDefaultLimits() public view {
        (uint256 maxSpending, uint256 window) = module.getSubAccountLimits(subAccount1);

        assertEq(maxSpending, module.DEFAULT_MAX_SPENDING_BPS());
        assertEq(window, module.DEFAULT_WINDOW_DURATION());
    }

    function testSetSubAccountLimitsInvalid() public {
        vm.expectRevert(DeFiInteractorModule.InvalidLimitConfiguration.selector);
        module.setSubAccountLimits(subAccount1, 15000, 2 days); // >100%
    }

    function testSetSubAccountLimitsCapsSpendingAllowance() public {
        // Safe value is $1,000,000 (set in base setUp)
        // Set initial limits at 10% = $100,000 max
        module.setSubAccountLimits(subAccount1, 1000, 1 days);

        // Oracle sets spending allowance to $50,000 (remaining)
        module.updateSpendingAllowance(subAccount1, 50_000 * 10**18);
        assertEq(module.getSpendingAllowance(subAccount1), 50_000 * 10**18);

        // Reduce limits to 4% = $40,000 max (less than remaining $50,000)
        // Remaining should be capped to $40,000
        module.setSubAccountLimits(subAccount1, 400, 1 days);

        assertEq(module.getSpendingAllowance(subAccount1), 40_000 * 10**18);
    }

    function testSetSubAccountLimitsDoesNotIncreaseAllowance() public {
        // Safe value is $1,000,000 (set in base setUp)
        // Set initial limits at 10% = $100,000 max
        module.setSubAccountLimits(subAccount1, 1000, 1 days);

        // Oracle sets spending allowance to $50,000 (remaining)
        module.updateSpendingAllowance(subAccount1, 50_000 * 10**18);
        assertEq(module.getSpendingAllowance(subAccount1), 50_000 * 10**18);

        // Increase limits to 7% = $70,000 max (more than remaining $50,000)
        // Remaining should stay at $50,000 (no auto-increase)
        module.setSubAccountLimits(subAccount1, 700, 1 days);

        assertEq(module.getSpendingAllowance(subAccount1), 50_000 * 10**18);
    }

    function testSetSubAccountLimitsEmitsEventOnCap() public {
        // Safe value is $1,000,000
        module.setSubAccountLimits(subAccount1, 1000, 1 days); // 10% = $100k max
        module.updateSpendingAllowance(subAccount1, 50_000 * 10**18);

        // Expect SpendingAllowanceUpdated event when capping
        vm.expectEmit(true, false, false, true);
        emit DeFiInteractorModule.SpendingAllowanceUpdated(subAccount1, 40_000 * 10**18);

        module.setSubAccountLimits(subAccount1, 400, 1 days); // 4% = $40k max
    }

    function testSetSubAccountLimitsNoCapWhenZeroSafeValue() public {
        // Deploy a fresh module with zero safe value
        DeFiInteractorModule freshModule = new DeFiInteractorModule(
            address(safe),
            address(this),
            address(this)
        );

        // Safe value is 0 (not initialized)
        (uint256 totalValue,,) = freshModule.getSafeValue();
        assertEq(totalValue, 0);

        // Even if we had some allowance, it shouldn't be modified since safeValue is 0
        // The capping logic is skipped when safeValue.totalValueUSD == 0
        freshModule.setSubAccountLimits(subAccount1, 500, 1 days);

        // Allowance should remain 0 (unchanged, not capped)
        assertEq(freshModule.getSpendingAllowance(subAccount1), 0);
    }

    function testSetSubAccountLimitsNoCapWhenStaleSafeValue() public {
        // Safe value is $1,000,000 and fresh
        module.setSubAccountLimits(subAccount1, 1000, 1 days); // 10% = $100k max
        module.updateSpendingAllowance(subAccount1, 80_000 * 10**18); // $80k remaining

        // Fast forward past Safe value staleness (maxSafeValueAge is 60 minutes)
        vm.warp(block.timestamp + 61 minutes);

        // Now Safe value is stale. If we reduce limits to 5% ($50k max),
        // the allowance should NOT be capped because Safe value is stale
        // (using stale value could be dangerous if real value dropped)
        module.setSubAccountLimits(subAccount1, 500, 1 days);

        // Allowance should remain $80k (not capped due to stale Safe value)
        assertEq(module.getSpendingAllowance(subAccount1), 80_000 * 10**18);
    }

    function testSetSubAccountLimitsExactMatch() public {
        // Safe value is $1,000,000
        module.setSubAccountLimits(subAccount1, 1000, 1 days); // 10% = $100k max

        // Set remaining exactly at what the new max will be
        module.updateSpendingAllowance(subAccount1, 50_000 * 10**18);

        // Set new max to exactly $50,000 (5%)
        module.setSubAccountLimits(subAccount1, 500, 1 days);

        // Should remain exactly $50,000 (not capped, just equal)
        assertEq(module.getSpendingAllowance(subAccount1), 50_000 * 10**18);
    }

    // ============ Allowed Addresses Tests ============

    function testSetAllowedAddresses() public {
        address[] memory targets = new address[](2);
        targets[0] = address(protocol);
        targets[1] = address(token);

        module.setAllowedAddresses(subAccount1, targets, true);

        assertTrue(module.allowedAddresses(subAccount1, address(protocol)));
        assertTrue(module.allowedAddresses(subAccount1, address(token)));
    }

    function testAllowedAddressesPerSubAccount() public {
        address[] memory targets1 = new address[](1);
        targets1[0] = address(protocol);

        address[] memory targets2 = new address[](1);
        targets2[0] = address(token);

        module.setAllowedAddresses(subAccount1, targets1, true);
        module.setAllowedAddresses(subAccount2, targets2, true);

        assertTrue(module.allowedAddresses(subAccount1, address(protocol)));
        assertFalse(module.allowedAddresses(subAccount1, address(token)));
        assertFalse(module.allowedAddresses(subAccount2, address(protocol)));
        assertTrue(module.allowedAddresses(subAccount2, address(token)));
    }

    // ============ Selector Registry Tests ============

    function testRegisterSelector() public {
        bytes4 newSelector = bytes4(keccak256("newFunction()"));
        module.registerSelector(newSelector, DeFiInteractorModule.OperationType.SWAP);
        assertEq(uint(module.selectorType(newSelector)), uint(DeFiInteractorModule.OperationType.SWAP));
    }

    function testUnregisterSelector() public {
        module.unregisterSelector(DEPOSIT_SELECTOR);
        assertEq(uint(module.selectorType(DEPOSIT_SELECTOR)), uint(DeFiInteractorModule.OperationType.UNKNOWN));
    }

    // ============ Oracle Functions Tests ============

    function testUpdateSpendingAllowance() public {
        module.updateSpendingAllowance(subAccount1, 50000 * 10**18);
        assertEq(module.getSpendingAllowance(subAccount1), 50000 * 10**18);
    }

    function testUpdateAcquiredBalance() public {
        module.updateAcquiredBalance(subAccount1, address(token), 1000 * 10**18);
        assertEq(module.getAcquiredBalance(subAccount1, address(token)), 1000 * 10**18);
    }

    function testBatchUpdate() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = makeAddr("token2");

        uint256[] memory balances = new uint256[](2);
        balances[0] = 500 * 10**18;
        balances[1] = 1000 * 10**18;

        module.batchUpdate(subAccount1, 10000 * 10**18, tokens, balances);

        assertEq(module.getSpendingAllowance(subAccount1), 10000 * 10**18);
        assertEq(module.getAcquiredBalance(subAccount1, tokens[0]), 500 * 10**18);
        assertEq(module.getAcquiredBalance(subAccount1, tokens[1]), 1000 * 10**18);
    }

    function testOnlyOracleCanUpdate() public {
        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.OnlyAuthorizedOracle.selector);
        module.updateSpendingAllowance(subAccount1, 50000 * 10**18);
    }

    function testAbsoluteMaxSpendingCap() public {
        // Safe value is $1,000,000 and absoluteMaxSpendingBps is 2000 (20%)
        // So max allowance is $200,000
        uint256 maxAllowance = (1_000_000 * 10**18 * 2000) / 10000; // $200,000

        // Setting exactly at max should work
        module.updateSpendingAllowance(subAccount1, maxAllowance);
        assertEq(module.getSpendingAllowance(subAccount1), maxAllowance);

        // Setting above max should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                DeFiInteractorModule.ExceedsAbsoluteMaxSpending.selector,
                maxAllowance + 1,
                maxAllowance
            )
        );
        module.updateSpendingAllowance(subAccount1, maxAllowance + 1);
    }

    function testAbsoluteMaxSpendingCapOnBatchUpdate() public {
        uint256 maxAllowance = (1_000_000 * 10**18 * 2000) / 10000; // $200,000

        address[] memory tokens = new address[](0);
        uint256[] memory balances = new uint256[](0);

        // Above max should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                DeFiInteractorModule.ExceedsAbsoluteMaxSpending.selector,
                maxAllowance + 1,
                maxAllowance
            )
        );
        module.batchUpdate(subAccount1, maxAllowance + 1, tokens, balances);
    }

    function testSetAbsoluteMaxSpendingBps() public {
        // Default is 2000 (20%)
        assertEq(module.absoluteMaxSpendingBps(), 2000);

        // Owner can change it
        module.setAbsoluteMaxSpendingBps(500); // 5%
        assertEq(module.absoluteMaxSpendingBps(), 500);

        // Cannot exceed 100%
        vm.expectRevert(DeFiInteractorModule.ExceedsMaxBps.selector);
        module.setAbsoluteMaxSpendingBps(10001);
    }

    // ============ Execute On Protocol Tests ============

    function testExecuteDeposit() public {
        // Setup
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18); // $10k allowance

        // Deposit 1000 tokens
        bytes memory data = abi.encodeWithSignature("deposit(uint256,address)", 1000 * 10**18, address(safe));

        vm.prank(subAccount1);
        module.executeOnProtocol(address(protocol), data);

        // Spending should be deducted (1000 tokens at $1 = $1000 spent)
        assertLt(module.getSpendingAllowance(subAccount1), 10000 * 10**18);
    }

    function testExecuteWithdraw() public {
        // Setup
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);

        // Withdraw - should not cost spending
        bytes memory data = abi.encodeWithSignature("withdraw(uint256,address)", 1000 * 10**18, address(safe));

        uint256 allowanceBefore = module.getSpendingAllowance(subAccount1);

        vm.prank(subAccount1);
        module.executeOnProtocol(address(protocol), data);

        // Spending should be unchanged (withdrawals are free)
        assertEq(module.getSpendingAllowance(subAccount1), allowanceBefore);
    }

    function testExecuteExceedsSpendingLimit() public {
        // Setup with small allowance
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 100 * 10**18); // Only $100

        // Try to deposit 1000 tokens ($1000 worth)
        bytes memory data = abi.encodeWithSignature("deposit(uint256,address)", 1000 * 10**18, address(safe));

        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.ExceedsSpendingLimit.selector);
        module.executeOnProtocol(address(protocol), data);
    }

    function testExecuteUnknownSelector() public {
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);

        // Try unknown function
        bytes memory data = abi.encodeWithSignature("unknownFunction(uint256)", 1000);

        vm.prank(subAccount1);
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.UnknownSelector.selector, bytes4(data)));
        module.executeOnProtocol(address(protocol), data);
    }

    function testAcquiredBalanceReducesSpendingCost() public {
        // Setup
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 500 * 10**18); // Only $500 allowance
        module.updateAcquiredBalance(subAccount1, address(token), 800 * 10**18); // 800 tokens acquired

        // Try to deposit 1000 tokens - 800 from acquired (free) + 200 from original ($200)
        bytes memory data = abi.encodeWithSignature("deposit(uint256,address)", 1000 * 10**18, address(safe));

        vm.prank(subAccount1);
        module.executeOnProtocol(address(protocol), data);

        // Should succeed because only $200 from original (within $500 limit)
        // Acquired balance should be 0 (used 800)
        assertEq(module.getAcquiredBalance(subAccount1, address(token)), 0);
    }

    // ============ Transfer Tests ============

    function testTransferToken() public {
        module.grantRole(subAccount1, module.DEFI_TRANSFER_ROLE());
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);

        uint256 safeBalanceBefore = token.balanceOf(address(safe));

        vm.prank(subAccount1);
        module.transferToken(address(token), recipient, 100 * 10**18);

        assertEq(token.balanceOf(address(safe)), safeBalanceBefore - 100 * 10**18);
        assertEq(token.balanceOf(recipient), 100 * 10**18);
    }

    function testTransferTokenExceedsLimit() public {
        module.grantRole(subAccount1, module.DEFI_TRANSFER_ROLE());
        module.updateSpendingAllowance(subAccount1, 50 * 10**18); // Only $50

        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.ExceedsSpendingLimit.selector);
        module.transferToken(address(token), recipient, 100 * 10**18); // $100 worth
    }

    function testTransferTokenUnauthorized() public {
        vm.prank(subAccount1);
        vm.expectRevert(Module.Unauthorized.selector);
        module.transferToken(address(token), recipient, 100 * 10**18);
    }

    // ============ Emergency Controls Tests ============

    function testPause() public {
        module.pause();
        assertTrue(module.paused());
    }

    function testUnpause() public {
        module.pause();
        module.unpause();
        assertFalse(module.paused());
    }

    function testOperationsWhenPaused() public {
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);
        module.pause();

        bytes memory data = abi.encodeWithSignature("deposit(uint256,address)", 1000 * 10**18, address(safe));

        vm.prank(subAccount1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        module.executeOnProtocol(address(protocol), data);
    }

    // ============ Oracle Staleness Tests ============

    function testStaleOracleData() public {
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);

        // Fast forward past oracle staleness (maxOracleAge is 60 minutes)
        vm.warp(block.timestamp + 61 minutes);

        bytes memory data = abi.encodeWithSignature("deposit(uint256,address)", 1000 * 10**18, address(safe));

        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.StaleOracleData.selector);
        module.executeOnProtocol(address(protocol), data);
    }

    // ============ Price Feed Tests ============

    function testSetTokenPriceFeed() public {
        MockERC20 newToken = new MockERC20();
        MockChainlinkPriceFeed newPriceFeed = new MockChainlinkPriceFeed(2_00000000, 8);

        module.setTokenPriceFeed(address(newToken), address(newPriceFeed));
        assertEq(address(module.tokenPriceFeeds(address(newToken))), address(newPriceFeed));
    }

    function testNoPriceFeedSet() public {
        // Create a new token and protocol for this test
        MockERC20 newToken = new MockERC20();
        newToken.transfer(address(safe), 10000 * 10**18);
        MockProtocol newProtocol = new MockProtocol();

        // Create and register a parser for the new token/protocol
        MockParser newParser = new MockParser(address(newToken));
        module.registerParser(address(newProtocol), address(newParser));

        // Setup subaccount with new protocol allowed
        _setupSubAccount(subAccount1);
        module.setAllowedAddresses(subAccount1, _toArray(address(newProtocol)), true);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);

        bytes memory data = abi.encodeWithSignature("deposit(uint256,address)", 1000 * 10**18, address(safe));

        // Should fail because no price feed is set for newToken
        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.NoPriceFeedSet.selector);
        module.executeOnProtocol(address(newProtocol), data);
    }

    function testStalePriceFeed() public {
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);

        // Make price feed stale (but keep oracle and Safe value fresh)
        vm.warp(block.timestamp + 25 hours);
        module.updateSafeValue(1_000_000 * 10**18); // Refresh Safe value first
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18); // Then refresh oracle

        bytes memory data = abi.encodeWithSignature("deposit(uint256,address)", 1000 * 10**18, address(safe));

        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.StalePriceFeed.selector);
        module.executeOnProtocol(address(protocol), data);
    }

    // ============ View Functions Tests ============

    function testGetTokenBalances() public {
        MockERC20 token1 = new MockERC20();
        MockERC20 token2 = new MockERC20();

        token1.mint(address(safe), 1000 * 10**18);
        token2.mint(address(safe), 2000 * 10**18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        uint256[] memory balances = module.getTokenBalances(tokens);

        assertEq(balances[0], 1000 * 10**18);
        assertEq(balances[1], 2000 * 10**18);
    }

    function testGetSafeValue() public view {
        (uint256 totalValue, uint256 lastUpdated, uint256 updateCount) = module.getSafeValue();
        assertEq(totalValue, 1_000_000 * 10**18);
        assertGt(lastUpdated, 0);
        assertEq(updateCount, 1);
    }

    // ============ Security Fix Tests ============

    function testApproveSucceeds() public {
        // Setup: subaccount with protocol and token allowed
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18); // $10k allowance

        // Create approve calldata
        uint256 approveAmount = 500 * 10**18;
        bytes memory data = abi.encodeWithSelector(
            APPROVE_SELECTOR,
            address(protocol), // spender (must be allowed)
            approveAmount
        );

        // Execute approve - token and amount are extracted from calldata
        vm.prank(subAccount1);
        module.executeOnProtocol(address(token), data);

        // Should succeed - check allowance was set
        assertEq(token.allowance(address(safe), address(protocol)), approveAmount);
    }

    function testSafeValueStalenessCheck() public {
        // Setup initial state
        module.updateSafeValue(1_000_000 * 10**18);

        // Fast forward past Safe value staleness threshold (maxSafeValueAge is 60 minutes)
        vm.warp(block.timestamp + 61 minutes);

        // Try to update spending allowance - should fail due to stale Safe value
        vm.expectRevert(DeFiInteractorModule.StalePortfolioValue.selector);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);
    }

    function testSafeValueStalenessOnBatchUpdate() public {
        // Setup initial state
        module.updateSafeValue(1_000_000 * 10**18);

        // Fast forward past Safe value staleness threshold (maxSafeValueAge is 60 minutes)
        vm.warp(block.timestamp + 61 minutes);

        address[] memory tokens = new address[](0);
        uint256[] memory balances = new uint256[](0);

        // Try batch update - should fail due to stale Safe value
        vm.expectRevert(DeFiInteractorModule.StalePortfolioValue.selector);
        module.batchUpdate(subAccount1, 10000 * 10**18, tokens, balances);
    }

    function testSafeValueFreshAllowsUpdate() public {
        // Setup initial state
        module.updateSafeValue(1_000_000 * 10**18);

        // Fast forward but less than staleness threshold
        vm.warp(block.timestamp + 10 minutes);

        // Should succeed
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);
        assertEq(module.getSpendingAllowance(subAccount1), 10000 * 10**18);
    }

    function testWithdrawRequiresParser() public {
        // Setup
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);

        // Create a new protocol without parser
        MockProtocol newProtocol = new MockProtocol();
        module.setAllowedAddresses(subAccount1, _toArray(address(newProtocol)), true);
        // Note: NOT registering a parser for newProtocol

        // Withdraw should fail because no parser
        bytes memory data = abi.encodeWithSignature("withdraw(uint256,address)", 1000 * 10**18, address(safe));

        vm.prank(subAccount1);
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.NoParserRegistered.selector, address(newProtocol)));
        module.executeOnProtocol(address(newProtocol), data);
    }

    function testClaimRequiresParser() public {
        // Setup
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);

        // Register a CLAIM selector
        bytes4 claimSelector = bytes4(keccak256("claim(uint256)"));
        module.registerSelector(claimSelector, DeFiInteractorModule.OperationType.CLAIM);

        // Create a new protocol without parser
        MockProtocol newProtocol = new MockProtocol();
        module.setAllowedAddresses(subAccount1, _toArray(address(newProtocol)), true);

        // Claim should fail because no parser
        bytes memory data = abi.encodeWithSignature("claim(uint256)", 1000 * 10**18);

        vm.prank(subAccount1);
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.NoParserRegistered.selector, address(newProtocol)));
        module.executeOnProtocol(address(newProtocol), data);
    }

    function testUpdateAcquiredBalanceUpdatesTimestamp() public {
        // Initially no oracle update
        assertEq(module.lastOracleUpdate(subAccount1), 0);

        // Update acquired balance
        module.updateAcquiredBalance(subAccount1, address(token), 1000 * 10**18);

        // Check timestamp was updated
        assertEq(module.lastOracleUpdate(subAccount1), block.timestamp);
    }

    function testApproveCapChecksOriginalPortion() public {
        // Setup
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 100 * 10**18); // $100 allowance
        module.updateAcquiredBalance(subAccount1, address(token), 500 * 10**18); // 500 acquired

        // Try to approve 700 tokens:
        // - 500 from acquired (free)
        // - 200 from original ($200 USD value)
        // Should fail because $200 > $100 allowance
        uint256 approveAmount = 700 * 10**18;
        bytes memory data = abi.encodeWithSelector(
            APPROVE_SELECTOR,
            address(protocol),
            approveAmount
        );

        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.ApprovalExceedsLimit.selector);
        module.executeOnProtocol(address(token), data);
    }

    function testApproveWithAcquiredSucceeds() public {
        // Setup
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 100 * 10**18); // $100 allowance
        module.updateAcquiredBalance(subAccount1, address(token), 500 * 10**18); // 500 acquired

        // Approve 550 tokens:
        // - 500 from acquired (free)
        // - 50 from original ($50 USD value)
        // Should succeed because $50 <= $100 allowance
        uint256 approveAmount = 550 * 10**18;
        bytes memory data = abi.encodeWithSelector(
            APPROVE_SELECTOR,
            address(protocol),
            approveAmount
        );

        vm.prank(subAccount1);
        module.executeOnProtocol(address(token), data);

        assertEq(token.allowance(address(safe), address(protocol)), approveAmount);
    }

    function testApproveSpenderMustBeAllowed() public {
        // Setup
        _setupSubAccount(subAccount1);
        module.updateSpendingAllowance(subAccount1, 10000 * 10**18);

        // Try to approve for a non-allowed spender
        address notAllowedSpender = makeAddr("notAllowed");
        uint256 approveAmount = 100 * 10**18;
        bytes memory data = abi.encodeWithSelector(
            APPROVE_SELECTOR,
            notAllowedSpender, // NOT in allowed addresses
            approveAmount
        );

        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.SpenderNotAllowed.selector);
        module.executeOnProtocol(address(token), data);
    }

    // ============ Helper Functions ============

    function _setupSubAccount(address subAccount) internal {
        module.grantRole(subAccount, module.DEFI_EXECUTE_ROLE());
        address[] memory targets = new address[](2);
        targets[0] = address(protocol);
        targets[1] = address(token);
        module.setAllowedAddresses(subAccount, targets, true);
    }

    function _toArray(address addr) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = addr;
        return arr;
    }
}
