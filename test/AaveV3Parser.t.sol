// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AaveV3Parser} from "../src/parsers/AaveV3Parser.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";

/**
 * @title MockAavePool
 * @notice Mock Aave V3 Pool for testing getReserveData
 */
contract MockAavePool {
    mapping(address => address) public aTokens;

    function setAToken(address asset, address aToken) external {
        aTokens[asset] = aToken;
    }

    function getReserveData(address asset) external view returns (IAavePool.ReserveData memory data) {
        data.aTokenAddress = aTokens[asset];
        return data;
    }
}

/**
 * @title AaveV3ParserTest
 * @notice Tests for the Aave V3 Pool and RewardsController parser
 */
contract AaveV3ParserTest is Test {
    AaveV3Parser public parser;
    MockAavePool public mockPool;

    // Test addresses
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant REWARDS_CONTROLLER = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant aUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c; // Mock aToken
    address constant aWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8; // Mock aToken
    address constant USER = address(0x1234);
    address constant REWARD_TOKEN = address(0xAAAA);

    function setUp() public {
        parser = new AaveV3Parser();
        mockPool = new MockAavePool();
        mockPool.setAToken(USDC, aUSDC);
        mockPool.setAToken(WETH, aWETH);
    }

    // ============ Selector Tests ============

    function testSelectors() public view {
        assertEq(parser.SUPPLY_SELECTOR(), bytes4(0x617ba037), "Supply selector mismatch");
        assertEq(parser.WITHDRAW_SELECTOR(), bytes4(0x69328dec), "Withdraw selector mismatch");
        // BORROW is intentionally NOT supported - only multisig can borrow
        assertEq(parser.REPAY_SELECTOR(), bytes4(0x573ade81), "Repay selector mismatch");
        assertEq(parser.CLAIM_REWARDS_SELECTOR(), bytes4(0x236300dc), "ClaimRewards selector mismatch");
        assertEq(parser.CLAIM_REWARDS_ON_BEHALF_SELECTOR(), bytes4(0x33028b99), "ClaimRewardsOnBehalf selector mismatch");
        assertEq(parser.CLAIM_ALL_REWARDS_SELECTOR(), bytes4(0xbb492bf5), "ClaimAllRewards selector mismatch");
        assertEq(parser.CLAIM_ALL_ON_BEHALF_SELECTOR(), bytes4(0x9ff55db9), "ClaimAllOnBehalf selector mismatch");
    }

    function testSupportsSelector() public view {
        // Pool operations
        assertTrue(parser.supportsSelector(parser.SUPPLY_SELECTOR()), "Should support supply");
        assertTrue(parser.supportsSelector(parser.WITHDRAW_SELECTOR()), "Should support withdraw");
        assertTrue(parser.supportsSelector(parser.REPAY_SELECTOR()), "Should support repay");

        // BORROW is intentionally NOT supported - only multisig can borrow
        assertFalse(parser.supportsSelector(bytes4(0xa415bcad)), "Should NOT support borrow");

        // Rewards operations
        assertTrue(parser.supportsSelector(parser.CLAIM_REWARDS_SELECTOR()), "Should support claimRewards");
        assertTrue(parser.supportsSelector(parser.CLAIM_REWARDS_ON_BEHALF_SELECTOR()), "Should support claimRewardsOnBehalf");
        assertTrue(parser.supportsSelector(parser.CLAIM_ALL_REWARDS_SELECTOR()), "Should support claimAllRewards");
        assertTrue(parser.supportsSelector(parser.CLAIM_ALL_ON_BEHALF_SELECTOR()), "Should support claimAllOnBehalf");

        // Unknown selector
        assertFalse(parser.supportsSelector(bytes4(0xdeadbeef)), "Should not support unknown");
    }

    // ============ Supply Tests ============

    function testSupplyExtractInputToken() public view {
        // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            USDC,
            1000e6,
            USER,
            uint16(0)
        );

        address token = parser.extractInputToken(AAVE_POOL, data);
        assertEq(token, USDC, "Input token should be USDC");
    }

    function testSupplyExtractInputAmount() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            USDC,
            1000e6,
            USER,
            uint16(0)
        );

        uint256 amount = parser.extractInputAmount(AAVE_POOL, data);
        assertEq(amount, 1000e6, "Input amount should be 1000e6");
    }

    function testSupplyExtractOutputToken() public view {
        // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            USDC,
            1000e6,
            USER,
            uint16(0)
        );

        // Output should be the aToken for USDC
        address token = parser.extractOutputToken(address(mockPool), data);
        assertEq(token, aUSDC, "Output token should be aUSDC (aToken for USDC)");
    }

    function testSupplyExtractOutputTokenWETH() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.SUPPLY_SELECTOR(),
            WETH,
            1e18,
            USER,
            uint16(0)
        );

        address token = parser.extractOutputToken(address(mockPool), data);
        assertEq(token, aWETH, "Output token should be aWETH (aToken for WETH)");
    }

    // ============ Withdraw Tests ============

    function testWithdrawExtractOutputToken() public view {
        // withdraw(address asset, uint256 amount, address to)
        bytes memory data = abi.encodeWithSelector(
            parser.WITHDRAW_SELECTOR(),
            USDC,
            1000e6,
            USER
        );

        address token = parser.extractOutputToken(AAVE_POOL, data);
        assertEq(token, USDC, "Output token should be USDC");
    }

    // ============ Borrow Tests ============
    // NOTE: BORROW is intentionally NOT supported - only multisig can borrow
    // Tests removed - subaccounts cannot use borrow function

    // ============ Repay Tests ============

    function testRepayExtractInputToken() public view {
        // repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        bytes memory data = abi.encodeWithSelector(
            parser.REPAY_SELECTOR(),
            WETH,
            1e18,
            uint256(2),
            USER
        );

        address token = parser.extractInputToken(AAVE_POOL, data);
        assertEq(token, WETH, "Input token should be WETH");
    }

    function testRepayExtractInputAmount() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.REPAY_SELECTOR(),
            WETH,
            1e18,
            uint256(2),
            USER
        );

        uint256 amount = parser.extractInputAmount(AAVE_POOL, data);
        assertEq(amount, 1e18, "Input amount should be 1e18");
    }

    function testRepayExtractOutputToken() public view {
        // repay doesn't produce output tokens (it burns debt tokens internally)
        bytes memory data = abi.encodeWithSelector(
            parser.REPAY_SELECTOR(),
            WETH,
            1e18,
            uint256(2),
            USER
        );

        address token = parser.extractOutputToken(AAVE_POOL, data);
        assertEq(token, address(0), "Repay should return zero address (no output token)");
    }

    // ============ Claim Rewards Tests ============

    function testClaimRewardsNoInputToken() public view {
        // claimRewards(address[] assets, uint256 amount, address to, address reward)
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_REWARDS_SELECTOR(),
            assets,
            1000e18,
            USER,
            REWARD_TOKEN
        );

        address token = parser.extractInputToken(REWARDS_CONTROLLER, data);
        assertEq(token, address(0), "Claim should have no input token");
    }

    function testClaimRewardsNoInputAmount() public view {
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_REWARDS_SELECTOR(),
            assets,
            1000e18,
            USER,
            REWARD_TOKEN
        );

        uint256 amount = parser.extractInputAmount(REWARDS_CONTROLLER, data);
        assertEq(amount, 0, "Claim should have no input amount");
    }

    function testClaimRewardsExtractOutputToken() public view {
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_REWARDS_SELECTOR(),
            assets,
            1000e18,
            USER,
            REWARD_TOKEN
        );

        address token = parser.extractOutputToken(REWARDS_CONTROLLER, data);
        assertEq(token, REWARD_TOKEN, "Output token should be reward token");
    }

    function testClaimRewardsOnBehalfExtractOutputToken() public view {
        // claimRewardsOnBehalf(address[] assets, uint256 amount, address user, address to, address reward)
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_REWARDS_ON_BEHALF_SELECTOR(),
            assets,
            1000e18,
            USER,
            USER,
            REWARD_TOKEN
        );

        address token = parser.extractOutputToken(REWARDS_CONTROLLER, data);
        assertEq(token, REWARD_TOKEN, "Output token should be reward token");
    }

    function testClaimAllRewardsReturnsZeroAddress() public view {
        // claimAllRewards(address[] assets, address to)
        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = WETH;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_ALL_REWARDS_SELECTOR(),
            assets,
            USER
        );

        address token = parser.extractOutputToken(REWARDS_CONTROLLER, data);
        assertEq(token, address(0), "ClaimAllRewards should return zero (multiple tokens)");
    }

    function testClaimAllOnBehalfReturnsZeroAddress() public view {
        // claimAllRewardsOnBehalf(address[] assets, address user, address to)
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_ALL_ON_BEHALF_SELECTOR(),
            assets,
            USER,
            USER
        );

        address token = parser.extractOutputToken(REWARDS_CONTROLLER, data);
        assertEq(token, address(0), "ClaimAllOnBehalf should return zero");
    }

    // ============ Operation Type Tests ============

    function testGetOperationType() public view {
        // Helper to create minimal calldata from selector
        bytes memory supplyData = abi.encodeWithSelector(parser.SUPPLY_SELECTOR());
        bytes memory repayData = abi.encodeWithSelector(parser.REPAY_SELECTOR());
        bytes memory withdrawData = abi.encodeWithSelector(parser.WITHDRAW_SELECTOR());
        // BORROW is not supported - only multisig can borrow
        bytes memory claimRewardsData = abi.encodeWithSelector(parser.CLAIM_REWARDS_SELECTOR());
        bytes memory claimOnBehalfData = abi.encodeWithSelector(parser.CLAIM_REWARDS_ON_BEHALF_SELECTOR());
        bytes memory claimAllData = abi.encodeWithSelector(parser.CLAIM_ALL_REWARDS_SELECTOR());
        bytes memory claimAllOnBehalfData = abi.encodeWithSelector(parser.CLAIM_ALL_ON_BEHALF_SELECTOR());
        bytes memory unknownData = abi.encodeWithSelector(bytes4(0xdeadbeef));

        // DEPOSIT operations
        assertEq(parser.getOperationType(supplyData), 2, "Supply should be DEPOSIT (2)");

        // WITHDRAW operations (includes REPAY - repaying debt is FREE)
        assertEq(parser.getOperationType(withdrawData), 3, "Withdraw should be WITHDRAW (3)");
        assertEq(parser.getOperationType(repayData), 3, "Repay should be WITHDRAW (3) - FREE operation");

        // CLAIM operations
        assertEq(parser.getOperationType(claimRewardsData), 4, "ClaimRewards should be CLAIM (4)");
        assertEq(parser.getOperationType(claimOnBehalfData), 4, "ClaimRewardsOnBehalf should be CLAIM (4)");
        assertEq(parser.getOperationType(claimAllData), 4, "ClaimAllRewards should be CLAIM (4)");
        assertEq(parser.getOperationType(claimAllOnBehalfData), 4, "ClaimAllOnBehalf should be CLAIM (4)");

        // Unknown
        assertEq(parser.getOperationType(unknownData), 0, "Unknown should return 0");
    }

    // ============ Revert Tests ============

    function testUnsupportedSelectorReverts() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(AaveV3Parser.UnsupportedSelector.selector);
        parser.extractInputToken(AAVE_POOL, badData);

        vm.expectRevert(AaveV3Parser.UnsupportedSelector.selector);
        parser.extractInputAmount(AAVE_POOL, badData);

        vm.expectRevert(AaveV3Parser.UnsupportedSelector.selector);
        parser.extractOutputToken(AAVE_POOL, badData);
    }
}
