// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Escrow.sol";

contract EscrowTest is Test {
    Escrow public escrow;
    
    address public owner;
    address public arbitrator;
    address public  buyer;
    address  public  seller;
    address  public  other;
    
    uint256 public  feeRate = 250; // 2.5% fee
    uint256  public transactionAmount = 1 ether;
    
    // Events for testing
    event TransactionCreated(uint256 indexed transactionId, address indexed buyer, address indexed seller, uint256 amount);
    event PaymentDeposited(uint256 indexed transactionId, uint256 amount);
    event DeliveryConfirmed(uint256 indexed transactionId);
    event TransactionDisputed(uint256 indexed transactionId);
    event DisputeResolved(uint256 indexed transactionId, address winner);
    event TransactionRefunded(uint256 indexed transactionId);
    event ArbitratorChanged(address oldArbitrator, address newArbitrator);
    event FeeRateChanged(uint256 oldFeeRate, uint256 newFeeRate);
    event FeesWithdrawn(uint256 amount);
    event PaymentReleased(address indexed recipient, uint256 amount);
    
    function setUp() external {
        owner = address(this);
        arbitrator = makeAddr("arbitrator");
        buyer = makeAddr("buyer");
        seller = makeAddr("seller");
        other = makeAddr("other");
        
        // Deploy contract
        escrow = new Escrow(arbitrator, feeRate);
        
        // Fund accounts for testing
        vm.deal(buyer, 10 ether);
        vm.deal(seller, 1 ether);
        vm.deal(other, 1 ether);
    }
    
    // TEST CONSTRUCTOR AND INITIALIZATION
    
    function testInitialization() external view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.arbitrator(), arbitrator);
        assertEq(escrow.feeRate(), feeRate);
        assertEq(escrow.collectedFees(), 0);
        assertEq(escrow.getTransactionCount(), 0);
    }
    
    function test_RevertWhen_ZeroArbitratorAddress() external {
        vm.expectRevert("Arbitrator cannot be zero address");
        new Escrow(address(0), feeRate);
    }
    
    function test_RevertWhen_ExcessiveFeeRate() external {
        vm.expectRevert("Fee rate cannot exceed 10%");
        new Escrow(arbitrator, 1001); // Fee rate > 10%
    }
    
    // TEST TRANSACTION CREATION
    
    function testCreateTransaction() external {
        vm.prank(buyer);
        
        vm.expectEmit(true, true, true, true);
        emit TransactionCreated(0, buyer, seller, 0);
        
        uint256 txId = escrow.createTransaction(payable(seller));
        
        assertEq(txId, 0);
        assertEq(escrow.getTransactionCount(), 1);
        
        (address txBuyer, address txSeller, uint256 amount, Escrow.State state, uint256 createdAt, uint256 completedAt) = escrow.getTransaction(txId);
        
        assertEq(txBuyer, buyer);
        assertEq(txSeller, seller);
        assertEq(amount, 0);
        assertEq(uint256(state), uint256(Escrow.State.AWAITING_PAYMENT));
        assertEq(completedAt, 0);
        assertTrue(createdAt > 0);
    }
    
    function test_RevertWhen_CreateTransactionWithZeroAddress() external {
        vm.prank(buyer);
        vm.expectRevert("Seller cannot be zero address");
        escrow.createTransaction(payable(address(0)));
    }
    
    function test_RevertWhen_CreateTransactionWithSelfAsSeller() external {
        vm.prank(buyer);
        vm.expectRevert("Seller cannot be buyer");
        escrow.createTransaction(payable(buyer));
    }
    
    // TEST PAYMENT DEPOSIT
    
    function testDepositPayment() external {
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        
        vm.expectEmit(true, true, false, true);
        emit PaymentDeposited(txId, transactionAmount);
        
        escrow.depositPayment{value: transactionAmount}(txId);
        vm.stopPrank();
        
        (,, uint256 amount, Escrow.State state,,) = escrow.getTransaction(txId);
        
        assertEq(amount, transactionAmount);
        assertEq(uint256(state), uint256(Escrow.State.AWAITING_DELIVERY));
        assertEq(address(escrow).balance, transactionAmount);
    }
    
    function test_RevertWhen_DepositPaymentNonBuyer() external {
        vm.prank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        
        vm.prank(other);
        vm.expectRevert("Only buyer can deposit");
        escrow.depositPayment{value: transactionAmount}(txId);
    }
    
    function test_RevertWhen_DepositZeroPayment() external {
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        vm.expectRevert("Amount must be greater than zero");
        escrow.depositPayment{value: 0}(txId);
        vm.stopPrank();
    }
    
    function test_RevertWhen_DepositPaymentInvalidState() external {
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        escrow.depositPayment{value: transactionAmount}(txId);
        vm.expectRevert("Invalid state for deposit");
        escrow.depositPayment{value: transactionAmount}(txId); // Should fail - already in AWAITING_DELIVERY
        vm.stopPrank();
    }
    
    // TEST CONFIRM DELIVERY
    
    function testConfirmDelivery() external {
        // Create transaction and deposit payment
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        escrow.depositPayment{value: transactionAmount}(txId);
        
        vm.expectEmit(true, false, false, false);
        emit DeliveryConfirmed(txId);
        
        escrow.confirmDelivery(txId);
        vm.stopPrank();
        
        (,, uint256 amount, Escrow.State state,, uint256 completedAt) = escrow.getTransaction(txId);
        
        assertEq(amount, transactionAmount);
        assertEq(uint256(state), uint256(Escrow.State.COMPLETE));
        assertTrue(completedAt > 0);
        
        // Check that seller has pending withdrawal
        uint256 fee = (transactionAmount * feeRate) / 10000;
        uint256 sellerAmount = transactionAmount - fee;
        assertEq(escrow.getPendingWithdrawal(seller), sellerAmount);
        
        // Check that contract has collected fees
        assertEq(escrow.collectedFees(), fee);
    }
    
    function test_RevertWhen_ConfirmDeliveryNonBuyer() external {
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        escrow.depositPayment{value: transactionAmount}(txId);
        vm.stopPrank();
        
        vm.prank(other);
        vm.expectRevert("Only buyer can confirm");
        escrow.confirmDelivery(txId);
    }
    
    function test_RevertWhen_ConfirmDeliveryInvalidState() external {
        vm.prank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        
        vm.prank(buyer);
        vm.expectRevert("Invalid state for confirmation");
        escrow.confirmDelivery(txId); // Should fail - not in AWAITING_DELIVERY
    }
    
    // TEST DISPUTE PROCESS
    
    function testInitiateDisputeByBuyer() external {
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        escrow.depositPayment{value: transactionAmount}(txId);
        
        vm.expectEmit(true, false, false, false);
        emit TransactionDisputed(txId);
        
        escrow.initiateDispute(txId);
        vm.stopPrank();
        
        (,, uint256 amount, Escrow.State state,,) = escrow.getTransaction(txId);
        
        assertEq(amount, transactionAmount);
        assertEq(uint256(state), uint256(Escrow.State.DISPUTED));
    }
    
    function testInitiateDisputeBySeller() external {
        vm.prank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        
        vm.prank(buyer);
        escrow.depositPayment{value: transactionAmount}(txId);
        
        vm.prank(seller);
        escrow.initiateDispute(txId);
        
        (,, uint256 amount, Escrow.State state,,) = escrow.getTransaction(txId);
        
        assertEq(amount, transactionAmount);
        assertEq(uint256(state), uint256(Escrow.State.DISPUTED));
    }
    
    function test_RevertWhen_InitiateDisputeByOther() external {
        vm.prank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        
        vm.prank(buyer);
        escrow.depositPayment{value: transactionAmount}(txId);
        
        vm.prank(other);
        vm.expectRevert("Only buyer or seller");
        escrow.initiateDispute(txId);
    }
    
    function test_RevertWhen_InitiateDisputeInvalidState() external {
        vm.prank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        
        vm.prank(buyer);
        vm.expectRevert("Invalid state for dispute");
        escrow.initiateDispute(txId); // Should fail - not in AWAITING_DELIVERY
    }
    
    // TEST DISPUTE RESOLUTION
    
    function testResolveDisputeReleaseToSeller() external {
        // Setup: Create transaction, deposit payment, initiate dispute
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        escrow.depositPayment{value: transactionAmount}(txId);
        escrow.initiateDispute(txId);
        vm.stopPrank();
        
        vm.startPrank(arbitrator);
        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(txId, seller);
        
        escrow.resolveDispute(txId, true); // Release to seller
        vm.stopPrank();
        
        (,, uint256 amount, Escrow.State state,, uint256 completedAt) = escrow.getTransaction(txId);
        
        assertEq(amount, transactionAmount);
        assertEq(uint256(state), uint256(Escrow.State.COMPLETE));
        assertTrue(completedAt > 0);
        
        // Check that seller has pending withdrawal
        uint256 fee = (transactionAmount * feeRate) / 10000;
        uint256 sellerAmount = transactionAmount - fee;
        assertEq(escrow.getPendingWithdrawal(seller), sellerAmount);
        
        // Check that contract has collected fees
        assertEq(escrow.collectedFees(), fee);
    }
    
    function testResolveDisputeRefundToBuyer() external {
        // Setup: Create transaction, deposit payment, initiate dispute
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        escrow.depositPayment{value: transactionAmount}(txId);
        escrow.initiateDispute(txId);
        vm.stopPrank();
        
        vm.startPrank(arbitrator);
        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(txId, buyer);
        
        escrow.resolveDispute(txId, false); // Refund to buyer
        vm.stopPrank();
        
        (,, uint256 amount, Escrow.State state,, uint256 completedAt) = escrow.getTransaction(txId);
        
        assertEq(amount, transactionAmount);
        assertEq(uint256(state), uint256(Escrow.State.REFUNDED));
        assertTrue(completedAt > 0);
        
        // Check that buyer has pending withdrawal
        assertEq(escrow.getPendingWithdrawal(buyer), transactionAmount);
        
        // Check that no fees were collected
        assertEq(escrow.collectedFees(), 0);
    }
    
    function test_RevertWhen_ResolveDisputeNonArbitrator() external {
        // Setup: Create transaction, deposit payment, initiate dispute
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        escrow.depositPayment{value: transactionAmount}(txId);
        escrow.initiateDispute(txId);
        vm.stopPrank();
        
        vm.prank(other);
        vm.expectRevert("Only arbitrator can resolve");
        escrow.resolveDispute(txId, true);
    }
    
    function test_RevertWhen_ResolveDisputeInvalidState() external {
        vm.prank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        
        vm.prank(arbitrator);
        vm.expectRevert("Transaction not disputed");
        escrow.resolveDispute(txId, true); // Should fail - not in DISPUTED state
    }
    
    // TEST WITHDRAW FUNDS
    
    function testWithdrawFunds() external {
        // Setup: Create transaction, deposit payment, confirm delivery
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        escrow.depositPayment{value: transactionAmount}(txId);
        escrow.confirmDelivery(txId);
        vm.stopPrank();
        
        uint256 fee = (transactionAmount * feeRate) / 10000;
        uint256 sellerAmount = transactionAmount - fee;
        
        uint256 sellerBalanceBefore = seller.balance;
        
        vm.prank(seller);
        vm.expectEmit(true, false, false, true);
        emit PaymentReleased(seller, sellerAmount);
        
        escrow.withdrawFunds();
        
        uint256 sellerBalanceAfter = seller.balance;
        
        // Check that seller received their funds
        assertEq(sellerBalanceAfter - sellerBalanceBefore, sellerAmount);
        
        // Check that seller has no more pending withdrawals
        assertEq(escrow.getPendingWithdrawal(seller), 0);
    }
    
    function testWithdrawFundsByRefundedBuyer() external {
        // Setup: Create transaction, deposit payment, initiate dispute, resolve in favor of buyer
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        escrow.depositPayment{value: transactionAmount}(txId);
        escrow.initiateDispute(txId);
        vm.stopPrank();
        
        vm.prank(arbitrator);
        escrow.resolveDispute(txId, false); // Refund to buyer
        
        uint256 buyerBalanceBefore = buyer.balance;
        
        vm.prank(buyer);
        escrow.withdrawFunds();
        
        uint256 buyerBalanceAfter = buyer.balance;
        
        // Check that buyer received their refund
        assertEq(buyerBalanceAfter - buyerBalanceBefore, transactionAmount);
        
        // Check that buyer has no more pending withdrawals
        assertEq(escrow.getPendingWithdrawal(buyer), 0);
    }
    
    function test_RevertWhen_WithdrawFundsNoPendingWithdrawal() external {
        vm.prank(other);
        vm.expectRevert("No funds to withdraw");
        escrow.withdrawFunds();
    }
    
    // TEST ADMIN FUNCTIONS
    
    function testChangeArbitrator() external {
        address newArbitrator = makeAddr("newArbitrator");
        
        vm.expectEmit(true, true, false, false);
        emit ArbitratorChanged(arbitrator, newArbitrator);
        
        escrow.changeArbitrator(newArbitrator);
        
        assertEq(escrow.arbitrator(), newArbitrator);
    }
    
  
    
    function test_RevertWhen_ChangeArbitratorZeroAddress() external {
        vm.expectRevert("Arbitrator cannot be zero address");
        escrow.changeArbitrator(address(0));
    }
    
    function testChangeFeeRate() external {
        uint256 newFeeRate = 300; // 3%
        
        vm.expectEmit(true, true, false, false);
        emit FeeRateChanged(feeRate, newFeeRate);
        
        escrow.changeFeeRate(newFeeRate);
        
        assertEq(escrow.feeRate(), newFeeRate);
    }
    
   
    
    function test_RevertWhen_ChangeFeeRateExcessive() external {
        uint256 newFeeRate = 1100; // 11%
        
        vm.expectRevert("Fee rate cannot exceed 10%");
        escrow.changeFeeRate(newFeeRate);
    }
    
    function testWithdrawFees() external {
        // Setup: Create transaction, deposit payment, confirm delivery to generate fees
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        escrow.depositPayment{value: transactionAmount}(txId);
        escrow.confirmDelivery(txId);
        vm.stopPrank();
        
        uint256 fee = (transactionAmount * feeRate) / 10000;
        assertEq(escrow.collectedFees(), fee);
        
        vm.expectEmit(true, false, false, true);
        emit FeesWithdrawn(fee);
        
        escrow.withdrawFees();
        
        // Check that collected fees are reset
        assertEq(escrow.collectedFees(), 0);
        
        // Check that owner has pending withdrawal
        assertEq(escrow.getPendingWithdrawal(owner), fee);
    }
  
    
    function test_RevertWhen_WithdrawFeesNoFees() external {
        vm.expectRevert("No fees to withdraw");
        escrow.withdrawFees(); // No fees collected yet
    }
    
    // COMPREHENSIVE TEST OF FULL FLOW
    
    
    function testFullDisputePathWithRefund() external {
        // 1. Create transaction
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        
        // 2. Deposit payment
        escrow.depositPayment{value: transactionAmount}(txId);
        
        // 3. Initiate dispute
        escrow.initiateDispute(txId);
        vm.stopPrank();
        
        // 4. Arbitrator resolves in favor of buyer
        vm.prank(arbitrator);
        escrow.resolveDispute(txId, false);
        
        // 5. Buyer withdraws refund
        uint256 buyerBalanceBefore = buyer.balance;
        
        vm.prank(buyer);
        escrow.withdrawFunds();
        
        uint256 buyerBalanceAfter = buyer.balance;
        assertEq(buyerBalanceAfter - buyerBalanceBefore, transactionAmount);
        
        // Check final state
        (,, uint256 amount, Escrow.State state,, uint256 completedAt) = escrow.getTransaction(txId);
        
        assertEq(amount, transactionAmount);
        assertEq(uint256(state), uint256(Escrow.State.REFUNDED));
        assertTrue(completedAt > 0);
        assertEq(escrow.collectedFees(), 0);
        assertEq(escrow.getPendingWithdrawal(buyer), 0);
    }
    
    function testFullDisputePathWithRelease() external {
        // 1. Create transaction
        vm.startPrank(buyer);
        uint256 txId = escrow.createTransaction(payable(seller));
        
        // 2. Deposit payment
        escrow.depositPayment{value: transactionAmount}(txId);
        
        // 3. Initiate dispute
        escrow.initiateDispute(txId);
        vm.stopPrank();
        
        // 4. Arbitrator resolves in favor of seller
        vm.prank(arbitrator);
        escrow.resolveDispute(txId, true);
        
        // 5. Seller withdraws funds
        uint256 fee = (transactionAmount * feeRate) / 10000;
        uint256 sellerAmount = transactionAmount - fee;
        
        uint256 sellerBalanceBefore = seller.balance;
        
        vm.prank(seller);
        escrow.withdrawFunds();
        
        uint256 sellerBalanceAfter = seller.balance;
        assertEq(sellerBalanceAfter - sellerBalanceBefore, sellerAmount);
        
        // Check final state
        (,, uint256 amount, Escrow.State state,, uint256 completedAt) = escrow.getTransaction(txId);
        
        assertEq(amount, transactionAmount);
        assertEq(uint256(state), uint256(Escrow.State.COMPLETE));
        assertTrue(completedAt > 0);
        assertEq(escrow.collectedFees(), fee);
        assertEq(escrow.getPendingWithdrawal(seller), 0);
    }
}