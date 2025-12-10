// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title SetPriceFeeds
 * @notice Set Chainlink price feeds for tokens on Sepolia
 * @dev Executes via Safe transaction since Safe is the module owner
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address (owner of the module)
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *
 * Usage:
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... \
 *   forge script script/SetPriceFeeds.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract SetPriceFeeds is Script, SafeTxHelper {
    // Chainlink Sepolia Price Feeds
    address constant ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant BTC_USD = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
    address constant LINK_USD = 0xc59E3633BAAC79493d908e63626716e204A45EdF;
    address constant USDC_USD = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    address constant DAI_USD = 0x14866185B1962B63C3Ea9E03Bc1da838bab34C19;
    address constant EUR_USD = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;

    // Aave V3 Sepolia underlying tokens
    address constant DAI = 0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357;
    address constant USDC = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;
    address constant USDT = 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0;
    address constant WETH = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;
    address constant WBTC = 0x29f2D40B0605204364af54EC677bD022dA425d03;
    address constant LINK = 0xf8Fb3713D459D7C1018BD0A49D19b4C44290EBE5;
    address constant AAVE = 0x88541670E55cC00bEEFD87eB59EDd1b7C511AC9a;
    address constant EURS = 0x6d906e526a4e2Ca02097BA9d0caA3c382F52278E;

    // Other tokens
    address constant USDC_CIRCLE = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant EURC = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== Set Token Price Feeds ===");
        console.log("Safe:", safe);
        console.log("Module:", module);

        // Build arrays
        address[] memory tokens = new address[](10);
        address[] memory feeds = new address[](10);

        tokens[0] = DAI;       feeds[0] = DAI_USD;
        tokens[1] = USDC;      feeds[1] = USDC_USD;
        tokens[2] = USDT;      feeds[2] = USDC_USD;  // Use USDC feed
        tokens[3] = WETH;      feeds[3] = ETH_USD;
        tokens[4] = WBTC;      feeds[4] = BTC_USD;
        tokens[5] = LINK;      feeds[5] = LINK_USD;
        tokens[6] = AAVE;      feeds[6] = LINK_USD;  // Use LINK as proxy
        tokens[7] = EURS;      feeds[7] = EUR_USD;
        tokens[8] = USDC_CIRCLE; feeds[8] = USDC_USD;
        tokens[9] = EURC;      feeds[9] = EUR_USD;

        vm.startBroadcast(deployerPrivateKey);

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "setTokenPriceFeeds(address[],address[])",
            tokens,
            feeds
        ), deployerPrivateKey);

        vm.stopBroadcast();

        console.log("Set price feeds for %s tokens", tokens.length);
    }
}
