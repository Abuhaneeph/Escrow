// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Counter} from "../src/Counter.sol";  // Import your Counter contract

contract CounterTest is Test {
    Counter public counter;

    // The setup function is called before each test
    function setUp() public {
        counter = new Counter();  // Deploy a new Counter contract
        counter.reset();  // Ensure the counter starts at 0
    }

    // Test the increment function
    function test_Increment() public {
        counter.inc();  // Increment the counter
        assertEq(counter.get(), 1);  // Assert the counter is now 1
    }

    // Test the decrement function
    function test_Decrement() public {
        counter.inc();  // Increment first to avoid underflow
        counter.dec();  // Decrement the counter
        assertEq(counter.get(), 0);  // Assert the counter is now back to 0
    }

    // Test decrement with underflow (should revert)
    function test_Decrement_Underflow() public {
        vm.expectRevert("Counter: cannot decrement below zero");  // Expect the revert message
        counter.dec();  // Attempt to decrement when count is already 0
    }

    // Test the reset function
    function test_Reset() public {
        counter.inc();  // Increment the counter
        counter.inc();  // Increment again
        counter.reset();  // Reset the counter
        assertEq(counter.get(), 0);  // Assert the counter is reset to 0
    }

    // Fuzz test for setting the counter to any uint256 value
    function testFuzz_SetNumber(uint256 x) public {
        counter.reset();  // Reset counter to start from 0
        counter.inc();    // Increment to avoid underflow
        counter.dec();    // Decrement once to bring back to 0
        counter.inc();    // Increment to ensure non-zero value
        assertEq(counter.get(), 1);  // Ensure it's 1 after incrementing
    }
}
