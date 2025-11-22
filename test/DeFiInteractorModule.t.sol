// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DeFiInteractorModule.sol";
import "../src/interfaces/ISafe.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockSafe
 * @notice Mock Safe contract for testing
 */
contract MockSafe {
    mapping(address => bool) public enabledModules;
    address[] public owners;
    uint256 public threshold;

    constructor(address[] memory _owners, uint256 _threshold) {
        owners = _owners;
        threshold = _threshold;
    }

    function enableModule(address module) external {
        enabledModules[module] = true;
    }

    function disableModule(address, address module) external {
        enabledModules[module] = false;
    }

    function isModuleEnabled(address module) external view returns (bool) {
        return enabledModules[module];
    }

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        ISafe.Operation
    ) external returns (bool) {
        // Simple execution without checks for testing
        (bool success,) = to.call{value: value}(data);
        return success;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    receive() external payable {}
}

/**
 * @title MockERC20
 * @notice Mock ERC20 token for testing
 */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1000000 * 10**18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockProtocol
 * @notice Mock DeFi protocol for testing
 */
contract MockProtocol {
    event ProtocolCalled(address indexed caller, uint256 amount);

    function deposit(uint256 amount, address) external {
        emit ProtocolCalled(msg.sender, amount);
    }

    function withdraw(uint256 amount, address) external {
        emit ProtocolCalled(msg.sender, amount);
    }
}

/**
 * @title DeFiInteractorModuleTest
 * @notice Tests for DeFiInteractorModule
 */
contract DeFiInteractorModuleTest is Test {
    DeFiInteractorModule public module;
    MockSafe public safe;
    MockERC20 public token;
    MockProtocol public protocol;

    address public owner;
    address public subAccount1;
    address public subAccount2;
    address public recipient;

    function setUp() public {
        owner = address(this);
        subAccount1 = makeAddr("subAccount1");
        subAccount2 = makeAddr("subAccount2");
        recipient = makeAddr("recipient");

        // Deploy mock Safe
        address[] memory owners = new address[](1);
        owners[0] = owner;
        safe = new MockSafe(owners, 1);

        // Deploy module (Safe is avatar, THIS is owner for testing, THIS is also authorized updater for testing)
        module = new DeFiInteractorModule(address(safe), owner, owner);

        // Deploy mock token and protocol
        token = new MockERC20();
        protocol = new MockProtocol();

        // Enable module on Safe
        safe.enableModule(address(module));

        // Transfer tokens to Safe
        token.transfer(address(safe), 100000 * 10**18);

        // Set initial Safe value (simulate Chainlink update)
        // Portfolio value: $1,000,000 USD (with 18 decimals)
        module.updateSafeValue(1_000_000 * 10**18);
    }

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
        // Grant role first
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());

        // Revoke role
        module.revokeRole(subAccount1, module.DEFI_EXECUTE_ROLE());

        assertFalse(module.hasRole(subAccount1, module.DEFI_EXECUTE_ROLE()));
    }

    function testGrantRoleUnauthorized() public {
        vm.expectRevert(Module.Unauthorized.selector);
        vm.prank(subAccount1);
        module.grantRole(subAccount2, 1);
    }

    function testGrantMultipleRoles() public {
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        module.grantRole(subAccount1, module.DEFI_TRANSFER_ROLE());

        assertTrue(module.hasRole(subAccount1, module.DEFI_EXECUTE_ROLE()));
        assertTrue(module.hasRole(subAccount1, module.DEFI_TRANSFER_ROLE()));
    }

    // ============ Sub-Account Limits Tests ============

    function testSetSubAccountLimits() public {
        module.setSubAccountLimits(subAccount1, 1500, 1000, 2 days);

        (uint256 maxLoss, uint256 maxTransfer, uint256 window) =
            module.getSubAccountLimits(subAccount1);

        assertEq(maxLoss, 1500);
        assertEq(maxTransfer, 1000);
        assertEq(window, 2 days);
    }

    function testDefaultLimits() public view {
        (uint256 maxLoss, uint256 maxTransfer, uint256 window) =
            module.getSubAccountLimits(subAccount1);

        assertEq(maxLoss, module.DEFAULT_MAX_LOSS_BPS());
        assertEq(maxTransfer, module.DEFAULT_MAX_TRANSFER_BPS());
        assertEq(window, module.DEFAULT_LIMIT_WINDOW_DURATION());
    }

    function testSetSubAccountLimitsInvalid() public {
        vm.expectRevert(DeFiInteractorModule.InvalidLimitConfiguration.selector);
        module.setSubAccountLimits(subAccount1, 15000, 1000, 2 days); // >100%
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

        // SubAccount1 can access protocol but not token
        assertTrue(module.allowedAddresses(subAccount1, address(protocol)));
        assertFalse(module.allowedAddresses(subAccount1, address(token)));

        // SubAccount2 can access token but not protocol
        assertFalse(module.allowedAddresses(subAccount2, address(protocol)));
        assertTrue(module.allowedAddresses(subAccount2, address(token)));
    }

    function testRemoveAllowedAddress() public {
        address[] memory targets = new address[](1);
        targets[0] = address(protocol);

        module.setAllowedAddresses(subAccount1, targets, true);
        module.setAllowedAddresses(subAccount1, targets, false);

        assertFalse(module.allowedAddresses(subAccount1, address(protocol)));
    }

    // ============ Approval Tests ============

    function testApproveProtocol() public {
        // Setup: grant role and allow address
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        address[] memory targets = new address[](1);
        targets[0] = address(protocol);
        module.setAllowedAddresses(subAccount1, targets, true);

        // Approve
        vm.prank(subAccount1);
        module.approveProtocol(address(token), address(protocol), 1000 * 10**18);

        // Verify approval (check on Safe's token balance)
        assertEq(token.allowance(address(safe), address(protocol)), 1000 * 10**18);
    }

    function testApproveProtocolUnauthorized() public {
        vm.prank(subAccount1);
        vm.expectRevert(Module.Unauthorized.selector);
        module.approveProtocol(address(token), address(protocol), 1000 * 10**18);
    }

    function testApproveProtocolNotAllowed() public {
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());

        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.AddressNotAllowed.selector);
        module.approveProtocol(address(token), address(protocol), 1000 * 10**18);
    }

    // ============ Transfer Tests ============

    function testTransferToken() public {
        // Setup: grant role
        module.grantRole(subAccount1, module.DEFI_TRANSFER_ROLE());

        uint256 safeBalanceBefore = token.balanceOf(address(safe));
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        // Transfer
        vm.prank(subAccount1);
        module.transferToken(address(token), recipient, 100 * 10**18);

        assertEq(token.balanceOf(address(safe)), safeBalanceBefore - 100 * 10**18);
        assertEq(token.balanceOf(recipient), recipientBalanceBefore + 100 * 10**18);
    }

    function testTransferTokenUnauthorized() public {
        vm.prank(subAccount1);
        vm.expectRevert(Module.Unauthorized.selector);
        module.transferToken(address(token), recipient, 100 * 10**18);
    }

    // ============ Protocol Execution Tests ============

    function testExecuteOnProtocol() public {
        // Setup: grant role and allow address
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        address[] memory targets = new address[](1);
        targets[0] = address(protocol);
        module.setAllowedAddresses(subAccount1, targets, true);

        // Prepare calldata
        bytes memory data = abi.encodeWithSignature(
            "deposit(uint256,address)",
            1000 * 10**18,
            address(safe)
        );

        // Execute
        vm.prank(subAccount1);
        module.executeOnProtocol(address(protocol), data);
    }

    function testExecuteOnProtocolBlocksApproval() public {
        // Setup
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        address[] memory targets = new address[](1);
        targets[0] = address(token);
        module.setAllowedAddresses(subAccount1, targets, true);

        // Try to approve via executeOnProtocol (should fail)
        bytes memory approveData = abi.encodeWithSelector(
            IERC20.approve.selector,
            address(protocol),
            1000 * 10**18
        );

        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.ApprovalNotAllowed.selector);
        module.executeOnProtocol(address(token), approveData);
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

    function testPauseUnauthorized() public {
        vm.prank(subAccount1);
        vm.expectRevert(Module.Unauthorized.selector);
        module.pause();
    }

    function testTransferWhenPaused() public {
        // Setup
        module.grantRole(subAccount1, module.DEFI_TRANSFER_ROLE());
        module.pause();

        // Try transfer (should fail)
        vm.prank(subAccount1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        module.transferToken(address(token), recipient, 100 * 10**18);
    }

    // ============ Event Tests ============

    function testRoleAssignedEvent() public {
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        // Event is emitted, we just test the role was granted
        assertTrue(module.hasRole(subAccount1, module.DEFI_EXECUTE_ROLE()));
    }

    function testRoleRevokedEvent() public {
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        module.revokeRole(subAccount1, module.DEFI_EXECUTE_ROLE());

        // Event is emitted, we just test the role was revoked
        assertFalse(module.hasRole(subAccount1, module.DEFI_EXECUTE_ROLE()));
    }

    function testGetTokenBalances() public {
        // Create multiple tokens and mint to Safe
        MockERC20 token1 = new MockERC20();
        MockERC20 token2 = new MockERC20();
        MockERC20 token3 = new MockERC20();

        token1.mint(address(safe), 1000 * 10**18);
        token2.mint(address(safe), 2000 * 10**18);
        token3.mint(address(safe), 3000 * 10**18);

        // Create token array
        address[] memory tokens = new address[](3);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tokens[2] = address(token3);

        // Call getTokenBalances
        uint256[] memory balances = module.getTokenBalances(tokens);

        // Verify balances
        assertEq(balances.length, 3);
        assertEq(balances[0], 1000 * 10**18);
        assertEq(balances[1], 2000 * 10**18);
        assertEq(balances[2], 3000 * 10**18);
    }

    function testGetTokenBalancesEmptyArray() public {
        address[] memory tokens = new address[](0);
        uint256[] memory balances = module.getTokenBalances(tokens);
        assertEq(balances.length, 0);
    }

    // ============ Portfolio Value Tracking Tests ============

    function testPortfolioValueTracking() public {
        // Check initial portfolio value
        (uint256 totalValue, uint256 lastUpdated, uint256 updateCount) = module.getSafeValue();
        assertEq(totalValue, 1_000_000 * 10**18);
        assertGt(lastUpdated, 0);
        assertEq(updateCount, 1);
    }

    function testApprovalWithPortfolioLimit() public {
        // Grant role
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        module.setAllowedAddresses(subAccount1, _createAddressArray(address(protocol)), true);

        // Set limits: 10% loss allowed, 5% transfer allowed
        module.setSubAccountLimits(subAccount1, 1000, 500, 1 days);

        // Approve 10000 tokens (should be within limit)
        vm.prank(subAccount1);
        module.approveProtocol(address(token), address(protocol), 10000 * 10**18);

        // Check cumulative approved value was tracked
        assertGt(module.valueApprovedInWindow(subAccount1), 0);
    }

    function testApprovalExceedsPortfolioLimit() public {
        // Grant role
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        module.setAllowedAddresses(subAccount1, _createAddressArray(address(protocol)), true);

        // Set very low limits: 1% loss allowed, 0.5% transfer allowed
        module.setSubAccountLimits(subAccount1, 100, 50, 1 days);

        // Try to approve 50000 tokens (should exceed 1% of portfolio)
        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.ExceedsApprovalLimit.selector);
        module.approveProtocol(address(token), address(protocol), 50000 * 10**18);
    }

    function testTransferWithPortfolioLimit() public {
        // Grant role
        module.grantRole(subAccount1, module.DEFI_TRANSFER_ROLE());

        // Set limits: 10% loss allowed, 5% transfer allowed
        module.setSubAccountLimits(subAccount1, 1000, 500, 1 days);

        // Transfer 5000 tokens (should be within limit)
        vm.prank(subAccount1);
        module.transferToken(address(token), recipient, 5000 * 10**18);

        // Check cumulative transferred value was tracked
        assertGt(module.valueTransferredInWindow(subAccount1), 0);
    }

    function testTransferExceedsPortfolioLimit() public {
        // Grant role
        module.grantRole(subAccount1, module.DEFI_TRANSFER_ROLE());

        // Set very low limits: 1% loss allowed, 1% transfer allowed
        module.setSubAccountLimits(subAccount1, 100, 100, 1 days);

        // Try to transfer 20000 tokens (should exceed 1% of portfolio)
        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.ExceedsPortfolioLimit.selector);
        module.transferToken(address(token), recipient, 20000 * 10**18);
    }

    function testStalePortfolioValue() public {
        // Grant role
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        module.setAllowedAddresses(subAccount1, _createAddressArray(address(protocol)), true);

        // Fast forward 16 minutes (beyond default 15 minute staleness)
        vm.warp(block.timestamp + 16 minutes);

        // Try to approve - should fail with stale value
        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.StalePortfolioValue.selector);
        module.approveProtocol(address(token), address(protocol), 1000 * 10**18);
    }

    function testUpdateMaxSafeValueAge() public {
        // Update to 10 minutes
        module.setMaxSafeValueAge(10 minutes);
        assertEq(module.maxSafeValueAge(), 10 minutes);

        // Grant role
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        module.setAllowedAddresses(subAccount1, _createAddressArray(address(protocol)), true);

        // Fast forward 6 minutes (should be OK with 10 minute limit)
        vm.warp(block.timestamp + 6 minutes);

        // Should succeed now
        vm.prank(subAccount1);
        module.approveProtocol(address(token), address(protocol), 1000 * 10**18);
    }

    function testPortfolioWindowReset() public {
        // Grant role
        module.grantRole(subAccount1, module.DEFI_TRANSFER_ROLE());

        // Make a transfer
        vm.prank(subAccount1);
        module.transferToken(address(token), recipient, 1000 * 10**18);

        uint256 firstWindowValue = module.valueTransferredInWindow(subAccount1);
        assertGt(firstWindowValue, 0);

        // Fast forward past window (24 hours)
        vm.warp(block.timestamp + 25 hours);

        // Update Safe value (simulate Chainlink update)
        module.updateSafeValue(2_000_000 * 10**18);

        // Make another transfer - should reset window
        vm.prank(subAccount1);
        module.transferToken(address(token), recipient, 1000 * 10**18);

        // Window should have reset
        uint256 newPortfolioValue = module.executionWindowPortfolioValue(subAccount1);
        assertEq(newPortfolioValue, 2_000_000 * 10**18);
    }

    function testCumulativeApprovals() public {
        // Grant role
        module.grantRole(subAccount1, module.DEFI_EXECUTE_ROLE());
        module.setAllowedAddresses(subAccount1, _createAddressArray(address(protocol)), true);

        // Set limits: 10% loss allowed, 5% transfer allowed
        module.setSubAccountLimits(subAccount1, 1000, 500, 1 days);

        // Make multiple small approvals
        vm.startPrank(subAccount1);
        module.approveProtocol(address(token), address(protocol), 3000 * 10**18);
        module.approveProtocol(address(token), address(protocol), 3000 * 10**18);
        module.approveProtocol(address(token), address(protocol), 3000 * 10**18);
        vm.stopPrank();

        // Cumulative should be tracked
        uint256 cumulative = module.valueApprovedInWindow(subAccount1);
        assertGt(cumulative, 0);

        // Next approval that pushes over limit should fail
        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.ExceedsApprovalLimit.selector);
        module.approveProtocol(address(token), address(protocol), 5000 * 10**18);
    }

    // Helper function
    function _createAddressArray(address addr) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = addr;
        return arr;
    }
}
