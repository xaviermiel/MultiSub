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

    // Aave V3 Sepolia aTokens (1:1 with underlying, use same price feeds)
    address constant aDAI = 0x29598b72eb5CeBd806C5dCD549490FdA35B13cD8;
    address constant aUSDC = 0x16dA4541aD1807f4443d92D26044C1147406EB80;
    address constant aUSDT = 0xAF0F6e8b0Dc5c913bbF4d14c22B4E78Dd14310B6;
    address constant aWETH = 0x5b071b590a59395fE4025A0Ccc1FcC931AAc1830;
    address constant aWBTC = 0x1804Bf30507dc2EB3bDEbbbdd859991EAeF6EefF;
    address constant aLINK = 0x3FfAf50D4F4E96eB78f2407c090b72e86eCaed24;
    address constant aAAVE = 0x6b8558764d3b7572136F17174Cb9aB1DDc7E1259;
    address constant aEURS = 0xB20691021F9AcED8631eDaa3c0Cd2949EB45662D;

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

        // Build arrays for all tokens from config.ts (19 tokens total)
        // Includes native ETH (address(0)) for swaps via Universal Router
        address[] memory tokens = new address[](19);
        address[] memory feeds = new address[](19);

        // Native ETH (for swaps with value)
        tokens[0] = address(0); feeds[0] = ETH_USD;

        // Underlying tokens (8)
        tokens[1] = WETH;      feeds[1] = ETH_USD;
        tokens[2] = WBTC;      feeds[2] = BTC_USD;
        tokens[3] = USDC;      feeds[3] = USDC_USD;
        tokens[4] = DAI;       feeds[4] = DAI_USD;
        tokens[5] = USDT;      feeds[5] = USDC_USD;  // Use USDC feed as proxy
        tokens[6] = LINK;      feeds[6] = LINK_USD;
        tokens[7] = AAVE;      feeds[7] = LINK_USD;  // Use LINK as proxy (similar price range on testnet)
        tokens[8] = EURS;      feeds[8] = EUR_USD;

        // aTokens (8) - 1:1 with underlying, use same price feeds
        tokens[9] = aWETH;     feeds[9] = ETH_USD;
        tokens[10] = aWBTC;    feeds[10] = BTC_USD;
        tokens[11] = aUSDC;    feeds[11] = USDC_USD;
        tokens[12] = aDAI;     feeds[12] = DAI_USD;
        tokens[13] = aUSDT;    feeds[13] = USDC_USD;
        tokens[14] = aLINK;    feeds[14] = LINK_USD;
        tokens[15] = aAAVE;    feeds[15] = LINK_USD;
        tokens[16] = aEURS;    feeds[16] = EUR_USD;

        // Other tokens (2)
        tokens[17] = USDC_CIRCLE; feeds[17] = USDC_USD;
        tokens[18] = EURC;        feeds[18] = EUR_USD;

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
