// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Escrow.sol";

contract EscrowFuzzTest is Test {
    Escrow public escrow;
    
    address payable public owner;
    address payable public arbitrator;
    
    uint256 public feeRate = 200; // 2% in basis points
    
    // Set up the test environment
    function setUp() external {
        owner = payable(address(0x1));
        arbitrator = payable(address(0x2));
        
        vm.startPrank(owner);
        escrow = new Escrow(arbitrator, feeRate);
        vm.stopPrank();
    }
    
    // Fuzz test for creating a transaction 
    function testFuzz_CreateTransaction(address _buyer, address _seller) external {
        // Filter inputs to avoid zero address and identical buyer/seller
        vm.assume(_buyer != address(0) && _seller != address(0) && _buyer != _seller);
        
        vm.startPrank(_buyer);
        uint256 transactionId = escrow.createTransaction(payable(_seller));
        vm.stopPrank();
        
        (
            address txBuyer,
            address txSeller,
            uint256 amount,
            Escrow.State state,
            uint256 createdAt,
            uint256 completedAt
        ) = escrow.getTransaction(transactionId);
        
        assertEq(txBuyer, _buyer, "Buyer should match");
        assertEq(txSeller, _seller, "Seller should match");
        assertEq(amount, 0, "Initial amount should be 0");
        assertEq(uint256(state), uint256(Escrow.State.AWAITING_PAYMENT), "Initial state should be AWAITING_PAYMENT");
        assertGt(createdAt, 0, "Created timestamp should be set");
        assertEq(completedAt, 0, "Completed timestamp should be 0");
    }
    
    // Fuzz test for depositing payment
    function testFuzz_DepositPayment(address _buyer, address _seller, uint256 _amount) external {
        // Filter inputs to avoid zero address, identical buyer/seller, and zero amount
        vm.assume(_buyer != address(0) && _seller != address(0) && _buyer != _seller);
        // Bound amount to avoid overflow and absurdly large values
        _amount = bound(_amount, 1, 100 ether);
        
        // Create a transaction
        vm.startPrank(_buyer);
        uint256 transactionId = escrow.createTransaction(payable(_seller));
        
        // Make deposit
        vm.deal(_buyer, _amount);
        escrow.depositPayment{value: _amount}(transactionId);
        vm.stopPrank();
        
        (
            ,
            ,
            uint256 amount,
            Escrow.State state,
            ,
            
        ) = escrow.getTransaction(transactionId);
        
        assertEq(amount, _amount, "Amount should match deposit");
        assertEq(uint256(state), uint256(Escrow.State.AWAITING_DELIVERY), "State should be AWAITING_DELIVERY");
        assertEq(address(escrow).balance, _amount, "Contract balance should match deposit");
    }
    
    // Fuzz test for completing transaction
    function testFuzz_CompleteTransaction(address _buyer, address _seller, uint256 _amount) external {
        // Filter inputs to avoid zero address, identical buyer/seller, and zero amount
        vm.assume(_buyer != address(0) && _seller != address(0) && _buyer != _seller);
        // Bound amount to avoid overflow and absurdly large values
        _amount = bound(_amount, 1, 100 ether);
        
        // Ensure seller has zero balance
        vm.deal(_seller, 0);
        
        // Create and fund transaction
        vm.startPrank(_buyer);
        uint256 transactionId = escrow.createTransaction(payable(_seller));
        vm.deal(_buyer, _amount);
        escrow.depositPayment{value: _amount}(transactionId);
        
        // Complete transaction
        escrow.confirmDelivery(transactionId);
        vm.stopPrank();
        
        // Calculate expected fee and seller amount
        uint256 fee = (_amount * feeRate) / 10000;
        uint256 sellerAmount = _amount - fee;
        
        (
            ,
            ,
            ,
            Escrow.State state,
            ,
            uint256 completedAt
        ) = escrow.getTransaction(transactionId);
        
        assertEq(uint256(state), uint256(Escrow.State.COMPLETE), "State should be COMPLETE");
        assertGt(completedAt, 0, "Completed timestamp should be set");
        
        // In updated implementation, check pending withdrawals instead of direct balance
        assertEq(escrow.getPendingWithdrawal(_seller), sellerAmount, "Seller should have correct pending withdrawal");
        assertEq(escrow.collectedFees(), fee, "Fees should be collected");
    }
    
    // Fuzz test for arbitration
    function testFuzz_ArbitratorResolveDispute(
        address _buyer, 
        address _seller, 
        uint256 _amount, 
        bool _releaseFunds
    ) external {
        // Filter inputs
        vm.assume(_buyer != address(0) && _seller != address(0) && _buyer != _seller);
        _amount = bound(_amount, 1, 100 ether);
        
        // Reset balances
        vm.deal(_buyer, _amount);
        vm.deal(_seller, 0);
        
        // Create and fund transaction
        vm.startPrank(_buyer);
        uint256 transactionId = escrow.createTransaction(payable(_seller));
        escrow.depositPayment{value: _amount}(transactionId);
        
        // Dispute
        escrow.initiateDispute(transactionId);
        vm.stopPrank();
        
        // Arbitrator resolves
        vm.startPrank(arbitrator);
        escrow.resolveDispute(transactionId, _releaseFunds);
        vm.stopPrank();
        
        (
            ,
            ,
            ,
            Escrow.State state,
            ,
            uint256 completedAt
        ) = escrow.getTransaction(transactionId);
        
        if (_releaseFunds) {
            // Funds released to seller
            uint256 fee = (_amount * feeRate) / 10000;
            uint256 sellerAmount = _amount - fee;
            
            assertEq(uint256(state), uint256(Escrow.State.COMPLETE), "State should be COMPLETE");
            // Check pending withdrawals instead of direct balance
            assertEq(escrow.getPendingWithdrawal(_seller), sellerAmount, "Seller should have correct pending withdrawal");
            assertEq(escrow.collectedFees(), fee, "Fees should be collected");
        } else {
            // Funds refunded to buyer
            assertEq(uint256(state), uint256(Escrow.State.REFUNDED), "State should be REFUNDED");
            // Check pending withdrawals instead of direct balance
            assertEq(escrow.getPendingWithdrawal(_buyer), _amount, "Buyer should have correct pending withdrawal");
            assertEq(escrow.collectedFees(), 0, "No fees should be collected");
        }
        
        assertGt(completedAt, 0, "Completed timestamp should be set");
    }
    
    // Fuzz test for changing fee rate
    function testFuzz_ChangeFeeRate(uint256 _newFeeRate) external {
        // Bound fee rate to valid range (0-10%)
        _newFeeRate = bound(_newFeeRate, 0, 1000);
        
        vm.startPrank(owner);
        escrow.changeFeeRate(_newFeeRate);
        vm.stopPrank();
        
        assertEq(escrow.feeRate(), _newFeeRate, "Fee rate should be updated correctly");
    }
    
    // Fuzz test for fee calculation
    function testFuzz_FeeCalculation(uint256 _amount, uint256 _feeRate) external {
        // Bound inputs to reasonable ranges
        _amount = bound(_amount, 1, 1000 ether);
        _feeRate = bound(_feeRate, 0, 1000); // 0-10%
        
        // Set fee rate
        vm.startPrank(owner);
        escrow.changeFeeRate(_feeRate);
        vm.stopPrank();
        
        // Create and fund a transaction
        address _buyer = address(0x100);
        address payable _seller = payable(address(0x101));
        
        vm.startPrank(_buyer);
        uint256 transactionId = escrow.createTransaction(_seller);
        vm.deal(_buyer, _amount);
        escrow.depositPayment{value: _amount}(transactionId);
        escrow.confirmDelivery(transactionId);
        vm.stopPrank();
        
        // Calculate expected fee
        uint256 expectedFee = (_amount * _feeRate) / 10000;
        
        // Check collected fees
        assertEq(escrow.collectedFees(), expectedFee, "Fee calculation should be correct");
        
        // Check seller has correct pending withdrawal instead of direct balance
        assertEq(escrow.getPendingWithdrawal(_seller), _amount - expectedFee, "Seller should have correct pending withdrawal");
    }
    
 
}