// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MultiSubPaymaster} from "../src/MultiSubPaymaster.sol";
import {SafeERC4337Account} from "../src/SafeERC4337Account.sol";
import {DeFiInteractorModule} from "../src/DeFiInteractorModule.sol";
import {PackedUserOperation, IEntryPoint, IPaymaster} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// Mock contracts for testing
contract MockSafe {
    address[] private _owners;
    mapping(address => bool) private _modules;

    constructor(address[] memory owners) {
        _owners = owners;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getThreshold() external pure returns (uint256) {
        return 1;
    }

    function isModuleEnabled(address module) external view returns (bool) {
        return _modules[module];
    }

    function enableModule(address module) external {
        _modules[module] = true;
    }

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        uint8 /* operation */
    ) external returns (bool) {
        (bool success,) = to.call{value: value}(data);
        return success;
    }

    receive() external payable {}
}

contract MockEntryPoint {
    mapping(address => uint256) public balances;

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function depositTo(address account) external payable {
        balances[account] += msg.value;
    }

    function withdrawTo(address payable to, uint256 amount) external {
        balances[msg.sender] -= amount;
        to.transfer(amount);
    }

    function addStake(uint32 /* unstakeDelaySec */) external payable {
        balances[msg.sender] += msg.value;
    }

    function unlockStake() external {}

    function withdrawStake(address payable to) external {
        uint256 balance = balances[msg.sender];
        balances[msg.sender] = 0;
        to.transfer(balance);
    }

    function getNonce(address /* sender */, uint192 /* key */) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/**
 * @title MultiSubPaymasterTest
 * @notice Comprehensive tests for MultiSub ERC-4337 Paymaster
 */
contract MultiSubPaymasterTest is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    MultiSubPaymaster public paymaster;
    SafeERC4337Account public safeAccount;
    DeFiInteractorModule public defiModule;
    MockSafe public safe;
    MockEntryPoint public entryPoint;

    // Test accounts
    address public safeOwner;
    uint256 public safeOwnerPrivateKey;
    address public paymasterSigner;
    uint256 public paymasterSignerPrivateKey;
    address public paymasterOwner;
    address public subAccount;
    uint256 public subAccountPrivateKey;
    address public authorizedUpdater;

    // Constants
    uint256 constant INITIAL_DEPOSIT = 10 ether;
    uint256 constant MAX_GAS_PER_OPERATION = 1_000_000;

    function setUp() public {
        // Create test accounts
        safeOwnerPrivateKey = 0x1;
        safeOwner = vm.addr(safeOwnerPrivateKey);

        paymasterSignerPrivateKey = 0x2;
        paymasterSigner = vm.addr(paymasterSignerPrivateKey);

        subAccountPrivateKey = 0x3;
        subAccount = vm.addr(subAccountPrivateKey);

        paymasterOwner = makeAddr("paymasterOwner");
        authorizedUpdater = makeAddr("authorizedUpdater");

        // Fund accounts
        vm.deal(safeOwner, 100 ether);
        vm.deal(subAccount, 1 ether);
        vm.deal(paymasterOwner, 100 ether);

        // Deploy Mock EntryPoint
        entryPoint = new MockEntryPoint();
        vm.deal(address(entryPoint), 100 ether);

        // Deploy Mock Safe
        address[] memory owners = new address[](1);
        owners[0] = safeOwner;
        safe = new MockSafe(owners);
        vm.deal(address(safe), 50 ether);

        // Deploy DeFiInteractorModule
        defiModule = new DeFiInteractorModule(
            address(safe), // avatar
            address(safe), // owner
            authorizedUpdater
        );

        // Enable module on Safe
        safe.enableModule(address(defiModule));

        // Deploy SafeERC4337Account
        safeAccount = new SafeERC4337Account(
            address(safe),
            address(entryPoint)
        );

        // Enable SafeERC4337Account as Safe module
        safe.enableModule(address(safeAccount));

        // Deploy MultiSubPaymaster
        paymaster = new MultiSubPaymaster(
            address(entryPoint),
            address(defiModule),
            paymasterSigner,
            paymasterOwner,
            MAX_GAS_PER_OPERATION
        );

        // Fund paymaster
        vm.prank(paymasterOwner);
        paymaster.deposit{value: INITIAL_DEPOSIT}();
    }

    // ============ Deployment Tests ============

    function testDeployment() public view {
        assertEq(address(paymaster.defiModule()), address(defiModule));
        assertEq(paymaster.owner(), paymasterOwner);
        assertEq(paymaster.maxGasPerOperation(), MAX_GAS_PER_OPERATION);
        assertTrue(paymaster.getBalance() >= INITIAL_DEPOSIT);
    }

    function testSafeAccountDeployment() public view {
        assertEq(address(safeAccount.safe()), address(safe));
        assertEq(address(safeAccount.entryPoint()), address(entryPoint));
        assertTrue(safeAccount.isModuleEnabled());
    }

    // ============ Authorization Tests ============

    function testSubAccountAuthorization() public {
        // Sub-account should not be authorized initially
        assertFalse(paymaster.isAuthorizedSubAccount(subAccount));

        // Grant role to sub-account (must be called from Safe owner)
        vm.prank(safeOwner);
        safe.execTransactionFromModule(
            address(defiModule),
            0,
            abi.encodeWithSelector(
                DeFiInteractorModule.grantRole.selector,
                subAccount,
                defiModule.DEFI_EXECUTE_ROLE()
            ),
            0
        );

        // Now should be authorized
        assertTrue(paymaster.isAuthorizedSubAccount(subAccount));
    }

    function testUnauthorizedSubAccountCannotUsePaymaster() public {
        // Create a user operation
        PackedUserOperation memory userOp = _createUserOp(
            subAccount,
            address(0x123),
            0,
            ""
        );

        // Try to validate (should revert because sub-account has no role)
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiSubPaymaster.SubAccountNotAuthorized.selector,
                subAccount
            )
        );
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            1000
        );
    }

    // ============ Gas Limit Tests ============

    function testMaxGasPerOperationEnforced() public {
        // Grant role to sub-account
        vm.prank(safeOwner);
        safe.execTransactionFromModule(
            address(defiModule),
            0,
            abi.encodeWithSelector(
                DeFiInteractorModule.grantRole.selector,
                subAccount,
                defiModule.DEFI_EXECUTE_ROLE()
            ),
            0
        );

        // Create user operation with excessive gas
        PackedUserOperation memory userOp = _createUserOp(
            subAccount,
            address(0x123),
            0,
            ""
        );

        uint256 excessiveGas = MAX_GAS_PER_OPERATION + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiSubPaymaster.GasLimitExceeded.selector,
                excessiveGas,
                MAX_GAS_PER_OPERATION
            )
        );
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            excessiveGas
        );
    }

    function testOwnerCanUpdateMaxGas() public {
        uint256 newMaxGas = 2_000_000;

        vm.prank(paymasterOwner);
        paymaster.setMaxGasPerOperation(newMaxGas);

        assertEq(paymaster.maxGasPerOperation(), newMaxGas);
    }

    function testNonOwnerCannotUpdateMaxGas() public {
        vm.prank(subAccount);
        vm.expectRevert();
        paymaster.setMaxGasPerOperation(2_000_000);
    }

    // ============ Deposit/Withdrawal Tests ============

    function testOwnerCanWithdrawFunds() public {
        uint256 initialBalance = paymaster.getBalance();
        uint256 withdrawAmount = 1 ether;

        vm.prank(paymasterOwner);
        paymaster.withdrawTo(payable(paymasterOwner), withdrawAmount);

        assertEq(paymaster.getBalance(), initialBalance - withdrawAmount);
    }

    function testNonOwnerCannotWithdraw() public {
        vm.prank(subAccount);
        vm.expectRevert();
        paymaster.withdrawTo(payable(subAccount), 1 ether);
    }

    function testFundPaymaster() public {
        uint256 initialBalance = paymaster.getBalance();
        uint256 additionalFunding = 5 ether;

        paymaster.deposit{value: additionalFunding}();

        assertEq(paymaster.getBalance(), initialBalance + additionalFunding);
    }

    // ============ Gas Tracking Tests ============

    function testGasTrackingInPostOp() public {
        // Grant role to sub-account
        vm.prank(safeOwner);
        safe.execTransactionFromModule(
            address(defiModule),
            0,
            abi.encodeWithSelector(
                DeFiInteractorModule.grantRole.selector,
                subAccount,
                defiModule.DEFI_EXECUTE_ROLE()
            ),
            0
        );

        // Simulate post-op call from EntryPoint
        uint256 gasCost = 100000;
        bytes memory context = abi.encode(subAccount);

        vm.prank(address(entryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context,
            gasCost,
            50 gwei
        );

        // Check tracked gas
        assertEq(paymaster.getSponsoredGas(subAccount), gasCost);
        assertEq(paymaster.totalGasSponsored(), gasCost);
    }

    // ============ SafeERC4337Account Tests ============

    function testSafeAccountCanAddDeposit() public {
        uint256 depositAmount = 1 ether;

        safeAccount.addDeposit{value: depositAmount}();

        assertEq(safeAccount.getDeposit(), depositAmount);
    }

    function testSafeOwnerCanWithdrawDeposit() public {
        // Add deposit first
        safeAccount.addDeposit{value: 1 ether}();

        uint256 initialBalance = safeOwner.balance;

        vm.prank(safeOwner);
        safeAccount.withdrawDepositTo(payable(safeOwner), 0.5 ether);

        assertEq(safeOwner.balance, initialBalance + 0.5 ether);
    }

    function testNonOwnerCannotWithdrawFromSafeAccount() public {
        safeAccount.addDeposit{value: 1 ether}();

        vm.prank(subAccount);
        vm.expectRevert("Not Safe owner");
        safeAccount.withdrawDepositTo(payable(subAccount), 0.5 ether);
    }

    // ============ Integration Tests ============

    function testEndToEndGasSponsorship() public {
        // 1. Grant role to sub-account
        vm.prank(safeOwner);
        safe.execTransactionFromModule(
            address(defiModule),
            0,
            abi.encodeWithSelector(
                DeFiInteractorModule.grantRole.selector,
                subAccount,
                defiModule.DEFI_EXECUTE_ROLE()
            ),
            0
        );

        // 2. Verify sub-account is authorized
        assertTrue(paymaster.isAuthorizedSubAccount(subAccount));

        // 3. Check initial balances
        uint256 initialPaymasterBalance = paymaster.getBalance();
        uint256 initialSponsoredGas = paymaster.getSponsoredGas(subAccount);

        // 4. Simulate a sponsored operation
        uint256 gasCost = 50000;
        bytes memory context = abi.encode(subAccount);

        vm.prank(address(entryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context,
            gasCost,
            50 gwei
        );

        // 5. Verify gas was tracked
        assertEq(paymaster.getSponsoredGas(subAccount), initialSponsoredGas + gasCost);
        assertEq(paymaster.totalGasSponsored(), gasCost);
    }

    // ============ Helper Functions ============

    function _createUserOp(
        address sender,
        address target,
        uint256 value,
        bytes memory data
    ) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: abi.encode(target, value, data),
            accountGasLimits: bytes32(uint256(150000) << 128 | uint256(50000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(50 gwei) << 128 | uint256(50 gwei)),
            paymasterAndData: "",
            signature: ""
        });
    }
}
