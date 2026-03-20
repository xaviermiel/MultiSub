// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SafeTxHelper} from "./utils/SafeTxHelper.sol";

contract SetTokenPriceFeed is Script, SafeTxHelper {
    function run() external {
        uint256 ownerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address safe = 0x6E7692fFE42ca2A3FA2b08611AA7e79A2AaA8e8C;
        address module = 0xDFF3cBa01F63152446E442133B664baE5A42bf39;
        address usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        address mockPriceFeed = 0xDd317fAbDD4884a1C3f87e53c119D2d58609e209;

        // Encode setTokenPriceFeed call
        bytes memory data = abi.encodeWithSignature("setTokenPriceFeed(address,address)", usdc, mockPriceFeed);

        console.log("Setting USDC price feed to MockPriceFeed...");
        console.log("  Safe:", safe);
        console.log("  Module:", module);
        console.log("  USDC:", usdc);
        console.log("  MockPriceFeed:", mockPriceFeed);

        vm.startBroadcast(ownerPrivateKey);

        // Execute through Safe
        _executeSafeTx(safe, module, data, ownerPrivateKey);

        vm.stopBroadcast();

        console.log("Done! USDC price feed updated.");
    }
}
