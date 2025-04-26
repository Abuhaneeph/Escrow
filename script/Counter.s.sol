// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";  // Import Forge's Script utility
import {Counter} from "../src/Counter.sol";  // Your contract to deploy

contract CounterDeploy is Script {
    function run() public {
        // Access RPC URL and Deployer Private Key from environment variables
        string memory rpcUrl = vm.envString("LISK_RPC_URL");  // Get RPC URL
        address deployer = vm.envAddress("DEPLOYER_PRIVATE_KEY"); // Get Deployer's private key (address)
        
        // Start broadcasting with the deployer's private key
        vm.startBroadcast(deployer);

        // Deploy the Counter contract
        Counter counter = new Counter();

        // Stop broadcasting after deployment
        vm.stopBroadcast();

        // Log the address where the contract was deployed
        console.log("Counter contract deployed to:", address(counter));
    }
}
