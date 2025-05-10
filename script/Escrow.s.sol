// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Escrow} from "../src/Escrow.sol";

contract EscrowDeploy is Script {
    function run() public {
        // Load private key from .env and start broadcasting
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY"); // Ensure this is a uint, not an address
        address arbitrator = vm.envAddress("ARBITRATOR_ADDRESS"); // Add this to your .env
        uint256 feeRate = 100; // 1% in basis points

        vm.startBroadcast(deployerPrivateKey);

        // ✅ Deploy with correct constructor args
        Escrow escrow = new Escrow(arbitrator, feeRate);

        vm.stopBroadcast();

        console.log("Escrow contract deployed to:", address(escrow));
    }
}
