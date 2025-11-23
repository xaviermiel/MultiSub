// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPaymaster, PackedUserOperation, IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {DeFiInteractorModule} from "./DeFiInteractorModule.sol";

/**
 * @title MultiSubPaymaster
 * @notice ERC-4337 Paymaster for MultiSub that sponsors gas for authorized sub-accounts
 * @dev Custom paymaster implementation compatible with Solidity 0.8.20
 *
 * This paymaster:
 * - Sponsors gas fees for authorized sub-accounts in the DeFiInteractorModule
 * - Validates operations using off-chain signatures from a trusted signer
 * - Enforces role-based access control (only sub-accounts with roles can use it)
 * - Allows owner to manage deposits and withdraw funds
 *
 * Architecture:
 * 1. Sub-account creates a UserOperation
 * 2. Backend validates sub-account has proper role in DeFiInteractorModule
 * 3. Backend signs the operation (EIP-712)
 * 4. Sub-account submits UserOp with paymaster signature to bundler
 * 5. Paymaster validates signature and role, then sponsors gas
 * 6. Safe pays gas via paymaster's deposited ETH in EntryPoint
 */
contract MultiSubPaymaster is IPaymaster, EIP712, Ownable {
    using ECDSA for bytes32;
    using ERC4337Utils for PackedUserOperation;

    /// @dev The canonical ERC-4337 EntryPoint v0.8.0
    IEntryPoint public immutable entryPoint;

    /// @dev Reference to the DeFiInteractorModule for role validation
    DeFiInteractorModule public immutable defiModule;

    /// @dev Authorized signer for paymaster approvals
    address public signer;

    /// @dev Mapping to track sponsored gas per sub-account
    mapping(address => uint256) public sponsoredGas;

    /// @dev Maximum gas that can be sponsored per operation (anti-DoS)
    uint256 public maxGasPerOperation;

    /// @dev Total gas sponsored by this paymaster
    uint256 public totalGasSponsored;

    bytes32 private constant USER_OPERATION_REQUEST_TYPEHASH =
        keccak256(
            "UserOperationRequest(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,uint256 paymasterVerificationGasLimit,uint256 paymasterPostOpGasLimit,uint48 validAfter,uint48 validUntil)"
        );

    /// @dev Emitted when gas is sponsored for a sub-account
    event GasSponsored(
        address indexed subAccount,
        address indexed safe,
        uint256 gasCost,
        uint256 timestamp
    );

    /// @dev Emitted when max gas per operation is updated
    event MaxGasPerOperationUpdated(uint256 oldMax, uint256 newMax);

    /// @dev Emitted when signer is updated
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);

    /// @dev Only EntryPoint can call
    error OnlyEntryPoint();

    /// @dev Sub-account not authorized (no role in DeFiInteractorModule)
    error SubAccountNotAuthorized(address subAccount);

    /// @dev Gas limit exceeds maximum allowed
    error GasLimitExceeded(uint256 requested, uint256 maximum);

    /// @dev Invalid signature
    error InvalidSignature();

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert OnlyEntryPoint();
        _;
    }

    /**
     * @notice Initialize the MultiSubPaymaster
     * @param _entryPoint Address of the ERC-4337 EntryPoint
     * @param _defiModule Address of the DeFiInteractorModule
     * @param _signer Address of the authorized signer (backend)
     * @param _owner Address of the paymaster owner
     * @param _maxGasPerOperation Maximum gas that can be sponsored per operation
     */
    constructor(
        address _entryPoint,
        address _defiModule,
        address _signer,
        address _owner,
        uint256 _maxGasPerOperation
    )
        EIP712("MultiSubPaymaster", "1")
        Ownable(_owner)
    {
        entryPoint = IEntryPoint(_entryPoint);
        defiModule = DeFiInteractorModule(_defiModule);
        signer = _signer;
        maxGasPerOperation = _maxGasPerOperation;
    }

    /**
     * @notice Validate a user operation and determine if paymaster will sponsor
     * @dev Validates both signature and sub-account authorization
     * @param userOp The user operation to validate
     * @param userOpHash The hash of the user operation
     * @param maxCost The maximum cost of this operation
     * @return context Data to pass to postOp (sub-account address)
     * @return validationData Packed validation data
     */
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        // Extract sub-account (sender)
        address subAccount = userOp.sender;

        // Validate that sub-account has role in DeFiInteractorModule
        bool hasExecuteRole = defiModule.hasRole(
            subAccount,
            defiModule.DEFI_EXECUTE_ROLE()
        );
        bool hasTransferRole = defiModule.hasRole(
            subAccount,
            defiModule.DEFI_TRANSFER_ROLE()
        );

        if (!hasExecuteRole && !hasTransferRole) {
            revert SubAccountNotAuthorized(subAccount);
        }

        // Validate gas limit doesn't exceed maximum
        if (maxCost > maxGasPerOperation) {
            revert GasLimitExceeded(maxCost, maxGasPerOperation);
        }

        // Decode paymaster data: validAfter (6 bytes) + validUntil (6 bytes) + signature
        (uint48 validAfter, uint48 validUntil, bytes memory signature) = _decodePaymasterData(userOp);

        // Validate signature
        bytes32 hash = _getSignableHash(userOp, validAfter, validUntil);
        address recovered = hash.recover(signature);

        if (recovered != signer) {
            revert InvalidSignature();
        }

        // Pack validation data
        validationData = _packValidationData(true, validAfter, validUntil);

        // Return sub-account address as context for postOp
        context = abi.encode(subAccount);
    }

    /**
     * @notice Post-operation handler to track gas usage
     * @dev Called by EntryPoint after operation execution
     * @param mode Whether the operation succeeded or reverted
     * @param context The context from validatePaymasterUserOp (sub-account address)
     * @param actualGasCost The actual gas cost paid
     * @param actualUserOpFeePerGas The actual fee per gas
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint {
        // Decode sub-account from context
        address subAccount = abi.decode(context, (address));

        // Track sponsored gas
        sponsoredGas[subAccount] += actualGasCost;
        totalGasSponsored += actualGasCost;

        // Get the Safe address from the module
        address safe = defiModule.avatar();

        emit GasSponsored(subAccount, safe, actualGasCost, block.timestamp);
    }

    /**
     * @notice Set the authorized signer
     * @param newSigner The new signer address
     */
    function setSigner(address newSigner) external onlyOwner {
        address oldSigner = signer;
        signer = newSigner;
        emit SignerUpdated(oldSigner, newSigner);
    }

    /**
     * @notice Set the maximum gas per operation
     * @param _maxGasPerOperation New maximum gas limit
     */
    function setMaxGasPerOperation(uint256 _maxGasPerOperation) external onlyOwner {
        uint256 oldMax = maxGasPerOperation;
        maxGasPerOperation = _maxGasPerOperation;
        emit MaxGasPerOperationUpdated(oldMax, _maxGasPerOperation);
    }

    /**
     * @notice Get the total sponsored gas for a sub-account
     * @param subAccount The sub-account address
     * @return The total gas cost sponsored for this sub-account
     */
    function getSponsoredGas(address subAccount) external view returns (uint256) {
        return sponsoredGas[subAccount];
    }

    /**
     * @notice Check if a sub-account is authorized to use this paymaster
     * @param subAccount The sub-account address to check
     * @return True if the sub-account has any role in DeFiInteractorModule
     */
    function isAuthorizedSubAccount(address subAccount) external view returns (bool) {
        return
            defiModule.hasRole(subAccount, defiModule.DEFI_EXECUTE_ROLE()) ||
            defiModule.hasRole(subAccount, defiModule.DEFI_TRANSFER_ROLE());
    }

    /**
     * @notice Deposit ETH to the paymaster for gas sponsorship
     */
    function deposit() public payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /**
     * @notice Withdraw deposited funds
     * @param withdrawAddress Address to receive funds
     * @param amount Amount to withdraw
     */
    function withdrawTo(address payable withdrawAddress, uint256 amount) external onlyOwner {
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    /**
     * @notice Add stake to the EntryPoint
     * @param unstakeDelaySec Unstake delay in seconds
     */
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /**
     * @notice Unlock stake
     */
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    /**
     * @notice Withdraw stake
     * @param withdrawAddress Address to receive stake
     */
    function withdrawStake(address payable withdrawAddress) external onlyOwner {
        entryPoint.withdrawStake(withdrawAddress);
    }

    /**
     * @notice Get the current balance in the EntryPoint
     * @return The balance available for sponsoring gas
     */
    function getBalance() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /**
     * @dev Decode paymaster data from userOp
     */
    function _decodePaymasterData(PackedUserOperation calldata userOp)
        internal
        pure
        returns (uint48 validAfter, uint48 validUntil, bytes memory signature)
    {
        bytes calldata paymasterAndData = userOp.paymasterAndData;
        // Skip first 20 bytes (paymaster address)
        bytes calldata paymasterData = paymasterAndData[20:];

        validAfter = uint48(bytes6(paymasterData[0:6]));
        validUntil = uint48(bytes6(paymasterData[6:12]));
        signature = paymasterData[12:];
    }

    /**
     * @dev Get the signable hash for a user operation
     */
    function _getSignableHash(
        PackedUserOperation calldata userOp,
        uint48 validAfter,
        uint48 validUntil
    ) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    USER_OPERATION_REQUEST_TYPEHASH,
                    userOp.sender,
                    userOp.nonce,
                    keccak256(userOp.initCode),
                    keccak256(userOp.callData),
                    userOp.accountGasLimits,
                    userOp.preVerificationGas,
                    userOp.gasFees,
                    _extractPaymasterVerificationGasLimit(userOp),
                    _extractPaymasterPostOpGasLimit(userOp),
                    validAfter,
                    validUntil
                )
            )
        );
    }

    /**
     * @dev Extract paymasterVerificationGasLimit from paymasterAndData
     */
    function _extractPaymasterVerificationGasLimit(PackedUserOperation calldata userOp)
        internal
        pure
        returns (uint256)
    {
        bytes calldata paymasterAndData = userOp.paymasterAndData;
        if (paymasterAndData.length < 52) return 0;
        return uint128(bytes16(paymasterAndData[20:36]));
    }

    /**
     * @dev Extract paymasterPostOpGasLimit from paymasterAndData
     */
    function _extractPaymasterPostOpGasLimit(PackedUserOperation calldata userOp)
        internal
        pure
        returns (uint256)
    {
        bytes calldata paymasterAndData = userOp.paymasterAndData;
        if (paymasterAndData.length < 52) return 0;
        return uint128(bytes16(paymasterAndData[36:52]));
    }

    /**
     * @dev Pack validation data
     */
    function _packValidationData(
        bool sigSuccess,
        uint48 validAfter,
        uint48 validUntil
    ) internal pure returns (uint256) {
        uint256 authorizer = sigSuccess ? 0 : 1;
        return (uint256(validAfter) << 208) | (uint256(validUntil) << 160) | authorizer;
    }

    /**
     * @dev Allow receiving ETH
     */
    receive() external payable {}
}
