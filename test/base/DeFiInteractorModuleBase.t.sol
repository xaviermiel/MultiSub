// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeFiInteractorModule} from "../../src/DeFiInteractorModule.sol";
import {Module} from "../../src/base/Module.sol";
import {MockSafe} from "../mocks/MockSafe.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockProtocol} from "../mocks/MockProtocol.sol";
import {MockChainlinkPriceFeed} from "../mocks/MockChainlinkPriceFeed.sol";
import {MockParser} from "../mocks/MockParser.sol";

/**
 * @title DeFiInteractorModuleBase
 * @notice Base test contract with shared setup for DeFiInteractorModule tests
 */
abstract contract DeFiInteractorModuleBase is Test {
    DeFiInteractorModule public module;
    MockSafe public safe;
    MockERC20 public token;
    MockProtocol public protocol;
    MockChainlinkPriceFeed public priceFeed;
    MockParser public parser;

    address public owner;
    address public subAccount1;
    address public subAccount2;
    address public recipient;

    // Selectors for testing
    bytes4 constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(uint256,address)"));
    bytes4 constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(uint256,address)"));
    bytes4 constant APPROVE_SELECTOR = bytes4(keccak256("approve(address,uint256)"));

    function setUp() public virtual {
        owner = address(this);
        subAccount1 = makeAddr("subAccount1");
        subAccount2 = makeAddr("subAccount2");
        recipient = makeAddr("recipient");

        // Deploy mock Safe
        address[] memory owners = new address[](1);
        owners[0] = owner;
        safe = new MockSafe(owners, 1);

        // Deploy module (Safe is avatar, THIS is owner for testing, THIS is also authorized oracle)
        module = new DeFiInteractorModule(address(safe), owner, owner);

        // Deploy mock token and protocol
        token = new MockERC20();
        protocol = new MockProtocol();

        // Deploy mock Chainlink price feed ($1.00 with 8 decimals)
        priceFeed = new MockChainlinkPriceFeed(1_00000000, 8);

        // Deploy mock parser (configured for our token)
        parser = new MockParser(address(token));

        // Enable module on Safe
        safe.enableModule(address(module));

        // Transfer tokens to Safe
        token.transfer(address(safe), 100000 * 10**18);

        // Set initial Safe value
        module.updateSafeValue(1_000_000 * 10**18);

        // Set price feed for token
        module.setTokenPriceFeed(address(token), address(priceFeed));

        // Register selectors
        module.registerSelector(DEPOSIT_SELECTOR, DeFiInteractorModule.OperationType.DEPOSIT);
        module.registerSelector(WITHDRAW_SELECTOR, DeFiInteractorModule.OperationType.WITHDRAW);
        module.registerSelector(APPROVE_SELECTOR, DeFiInteractorModule.OperationType.APPROVE);

        // Register parser for protocol (required for spending check operations)
        module.registerParser(address(protocol), address(parser));
    }
}
