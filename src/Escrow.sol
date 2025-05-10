// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Escrow
 * @dev A simple escrow contract for holding funds until conditions are met.
 * The contract allows a buyer to deposit funds, and a seller can only withdraw
 * once the buyer has confirmed receipt or the arbitrator approves.
 * Implements a pull payment pattern for increased security.
 */
contract Escrow is Ownable, ReentrancyGuard {
    enum State { AWAITING_PAYMENT, AWAITING_DELIVERY, COMPLETE, REFUNDED, DISPUTED }
    
    struct Transaction {
        address payable buyer;
        address payable seller;
        uint256 amount;
        State state;
        uint256 createdAt;
        uint256 completedAt;
    }
    
    // Transactions mapping: transactionId => Transaction
    mapping(uint256 => Transaction) public transactions;
    
    // Transaction counter for unique IDs
    uint256 private _transactionCounter;
    
    // Arbitrator address that can resolve disputes
    address public arbitrator;
    
    // Fee percentage taken by the protocol (in basis points: 100 = 1%)
    uint256 public feeRate;
    
    // Collected fees
    uint256 public collectedFees;
    
    // Pending withdrawals mapping
    mapping(address => uint256) public pendingWithdrawals;
    
    // Events
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
    event WithdrawalFailed(address indexed recipient, uint256 amount);
    
    /**
     * @dev Constructor sets the owner and arbitrator
     * @param _arbitrator The address that can resolve disputes
     * @param _feeRate The fee percentage in basis points (100 = 1%)
     */
    constructor(address _arbitrator, uint256 _feeRate) Ownable(msg.sender) {
        require(_arbitrator != address(0), "Arbitrator cannot be zero address");
        require(_feeRate <= 1000, "Fee rate cannot exceed 10%");
        
        arbitrator = _arbitrator;
        feeRate = _feeRate;
    }
    
    /**
     * @dev Creates a new escrow transaction
     * @param _seller The address of the seller
     * @return The ID of the created transaction
     */
    function createTransaction(address payable _seller) external returns (uint256) {
        require(_seller != address(0), "Seller cannot be zero address");
        require(_seller != msg.sender, "Seller cannot be buyer");
        
        uint256 transactionId = _transactionCounter;
        _transactionCounter++;
        
        transactions[transactionId] = Transaction({
            buyer: payable(msg.sender),
            seller: _seller,
            amount: 0,
            state: State.AWAITING_PAYMENT,
            createdAt: block.timestamp,
            completedAt: 0
        });
        
        emit TransactionCreated(transactionId, msg.sender, _seller, 0);
        
        return transactionId;
    }
    
    /**
     * @dev Deposits payment for an escrow transaction
     * @param _transactionId The ID of the transaction
     */
    function depositPayment(uint256 _transactionId) external payable nonReentrant {
        Transaction storage transaction = transactions[_transactionId];
        
        require(transaction.buyer == msg.sender, "Only buyer can deposit");
        require(transaction.state == State.AWAITING_PAYMENT, "Invalid state for deposit");
        require(msg.value > 0, "Amount must be greater than zero");
        
        transaction.amount = msg.value;
        transaction.state = State.AWAITING_DELIVERY;
        
        emit PaymentDeposited(_transactionId, msg.value);
    }
    
    /**
     * @dev Confirms delivery and releases payment to seller
     * @param _transactionId The ID of the transaction
     */
    function confirmDelivery(uint256 _transactionId) external nonReentrant {
        Transaction storage transaction = transactions[_transactionId];
        
        require(transaction.buyer == msg.sender, "Only buyer can confirm");
        require(transaction.state == State.AWAITING_DELIVERY, "Invalid state for confirmation");
        
        _completeTransaction(_transactionId);
    }
    
    /**
     * @dev Initiates a dispute for an escrow transaction
     * @param _transactionId The ID of the transaction
     */
    function initiateDispute(uint256 _transactionId) external {
        Transaction storage transaction = transactions[_transactionId];
        
        require(msg.sender == transaction.buyer || msg.sender == transaction.seller, "Only buyer or seller");
        require(transaction.state == State.AWAITING_DELIVERY, "Invalid state for dispute");
        
        transaction.state = State.DISPUTED;
        
        emit TransactionDisputed(_transactionId);
    }
    
    /**
     * @dev Resolves a dispute (arbitrator only)
     * @param _transactionId The ID of the transaction
     * @param _releaseFunds Whether to release funds to seller (true) or refund buyer (false)
     */
    function resolveDispute(uint256 _transactionId, bool _releaseFunds) external {
        require(msg.sender == arbitrator, "Only arbitrator can resolve");
        
        Transaction storage transaction = transactions[_transactionId];
        require(transaction.state == State.DISPUTED, "Transaction not disputed");
        
        if (_releaseFunds) {
            _completeTransaction(_transactionId);
            emit DisputeResolved(_transactionId, transaction.seller);
        } else {
            _refundTransaction(_transactionId);
            emit DisputeResolved(_transactionId, transaction.buyer);
        }
    }
    
    /**
     * @dev Internal function to complete a transaction and add funds to seller's pending withdrawals
     * @param _transactionId The ID of the transaction
     */
    function _completeTransaction(uint256 _transactionId) internal {
        Transaction storage transaction = transactions[_transactionId];
        
        uint256 fee = (transaction.amount * feeRate) / 10000;
        uint256 sellerAmount = transaction.amount - fee;
        
        collectedFees += fee;
        transaction.state = State.COMPLETE;
        transaction.completedAt = block.timestamp;
        
        // Add to pending withdrawals instead of immediate transfer
        pendingWithdrawals[transaction.seller] += sellerAmount;
        
        emit DeliveryConfirmed(_transactionId);
    }
    
    /**
     * @dev Internal function to refund a transaction back to buyer
     * @param _transactionId The ID of the transaction
     */
    function _refundTransaction(uint256 _transactionId) internal {
        Transaction storage transaction = transactions[_transactionId];
        
        transaction.state = State.REFUNDED;
        transaction.completedAt = block.timestamp;
        
        // Add to pending withdrawals instead of immediate transfer
        pendingWithdrawals[transaction.buyer] += transaction.amount;
        
        emit TransactionRefunded(_transactionId);
    }
    
    /**
     * @dev Allows recipients to withdraw their pending funds
     */
    function withdrawFunds() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No funds to withdraw");
        
        // Reset pending withdrawal before transfer to prevent reentrancy
        pendingWithdrawals[msg.sender] = 0;
        
        // Send the funds, but don't revert if transfer fails
        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) {
            // If transfer fails, restore the balance
            pendingWithdrawals[msg.sender] = amount;
            emit WithdrawalFailed(msg.sender, amount);
        } else {
            emit PaymentReleased(msg.sender, amount);
        }
    }
    
    /**
     * @dev Change the arbitrator address (owner only)
     * @param _newArbitrator The new arbitrator address
     */
    function changeArbitrator(address _newArbitrator) external onlyOwner {
        require(_newArbitrator != address(0), "Arbitrator cannot be zero address");
        
        address oldArbitrator = arbitrator;
        arbitrator = _newArbitrator;
        
        emit ArbitratorChanged(oldArbitrator, _newArbitrator);
    }
    
    /**
     * @dev Change the fee rate (owner only)
     * @param _newFeeRate The new fee rate in basis points
     */
    function changeFeeRate(uint256 _newFeeRate) external onlyOwner {
        require(_newFeeRate <= 1000, "Fee rate cannot exceed 10%");
        
        uint256 oldFeeRate = feeRate;
        feeRate = _newFeeRate;
        
        emit FeeRateChanged(oldFeeRate, _newFeeRate);
    }
    
    /**
     * @dev Withdraw collected fees (owner only) - uses pull payment pattern
     */
    function withdrawFees() external onlyOwner nonReentrant {
        uint256 amount = collectedFees;
        require(amount > 0, "No fees to withdraw");
        
        collectedFees = 0;
        
        // Add to pending withdrawals instead of immediate transfer
        pendingWithdrawals[owner()] += amount;
        
        emit FeesWithdrawn(amount);
    }

    /**
     * @dev Check pending withdrawal amount for an address
     * @param _address The address to check
     * @return Amount of pending withdrawals
     */
    function getPendingWithdrawal(address _address) external view returns (uint256) {
        return pendingWithdrawals[_address];
    }

    /**
     * @dev Get detailed transaction info
     * @param _transactionId The ID of the transaction
     * @return buyer The address of the buyer
     * @return seller The address of the seller
     * @return amount The amount involved in the transaction
     * @return state The current state of the transaction
     * @return createdAt Timestamp when the transaction was created
     * @return completedAt Timestamp when the transaction was completed
     */
    function getTransaction(uint256 _transactionId) external view 
        returns (
            address buyer,
            address seller,
            uint256 amount,
            State state,
            uint256 createdAt,
            uint256 completedAt
        ) 
    {
        Transaction storage transaction = transactions[_transactionId];
        
        return (
            transaction.buyer,
            transaction.seller,
            transaction.amount,
            transaction.state,
            transaction.createdAt,
            transaction.completedAt
        );
    }

    /**
     * @dev Get total number of transactions
     * @return The transaction counter
     */
    function getTransactionCount() external view returns (uint256) {
        return _transactionCounter;
    }
}