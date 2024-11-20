;; Multi-signature Wallet Contract
;; Version: 2.0

;; 
;; This contract enables multiple authorized owners to collectively approve 
;; transactions. A specified minimum number of signatures (approval threshold) 
;; is required to execute transactions, providing a secure and decentralized 
;; wallet management system.

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ALREADY-EXECUTED (err u101))
(define-constant ERR-INVALID-THRESHOLD (err u102))
(define-constant ERR-DUPLICATE_SIGNATURE (err u103))
(define-constant ERR-INSUFFICIENT_SIGNATURES (err u104))
(define-constant ERR-INVALID_RECIPIENT (err u105))
(define-constant ERR-INVALID_AMOUNT (err u106))
(define-constant ERR-TRANSFER_FAILED (err u107))

;; Configuration data variables
(define-data-var approval-threshold uint u2) ;; Minimum number of signatures required to execute a transaction
(define-data-var current-transaction-id uint u0) ;; Tracks the next transaction ID to be used

;; Owner registry
(define-map authorized-owners principal bool)

;; Transaction data
(define-map transaction-records 
    uint 
    {
        recipient: principal,
        amount: uint,
        executed: bool,
        signatures-count: uint
    }
)

;; Track individual owner signatures per transaction
(define-map transaction-signatures 
    {transaction-id: uint, owner: principal} 
    bool
)

;; Initialize contract with owners and threshold
(define-public (initialize (owners-list (list 20 principal)) (threshold uint))
    (begin
        ;; Ensure the threshold is valid
        (asserts! (>= threshold u1) ERR-INVALID-THRESHOLD)
        (asserts! (<= threshold (len owners-list)) ERR-INVALID-THRESHOLD)
        
        ;; Set the approval threshold
        (var-set approval-threshold threshold)
        
        ;; Register each owner
        (map register-owners owners-list)
        (ok true)
    )
)

;; Private helper function to register an owner
(define-private (register-owners (owner principal))
    (map-set authorized-owners owner true)
)

;; Verify if caller is an authorized owner
(define-private (is-authorized-owner (account principal))
    (default-to false (map-get? authorized-owners account))
)

;; Submit a new transaction for approval
(define-public (submit-transaction (recipient principal) (amount uint))
    (let 
        (
            (transaction-id (var-get current-transaction-id))
        )
        ;; Verify sender is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        
        ;; Check recipient and amount validity
        (asserts! (is-valid-recipient recipient) ERR-INVALID_RECIPIENT)
        (asserts! (> amount u0) ERR-INVALID_AMOUNT)
        
        ;; Create and store new transaction
        (map-set transaction-records transaction-id {
            recipient: recipient,
            amount: amount,
            executed: false,
            signatures-count: u1
        })
        
        ;; Record initial signature from transaction creator
        (map-set transaction-signatures {transaction-id: transaction-id, owner: tx-sender} true)
        
        ;; Increment transaction ID for the next submission
        (var-set current-transaction-id (+ transaction-id u1))
        (ok transaction-id)
    )
)

;; Sign an existing transaction to approve it
(define-public (approve-transaction (transaction-id uint))
    (let 
        (
            (transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED))
        )
        ;; Check caller's authority and signature validity
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (not (default-to false (map-get? transaction-signatures {transaction-id: transaction-id, owner: tx-sender}))) ERR-DUPLICATE_SIGNATURE)
        
        ;; Ensure transaction has not already been executed
        (asserts! (not (get executed transaction)) ERR-ALREADY-EXECUTED)
        
        ;; Record the signature
        (map-set transaction-signatures {transaction-id: transaction-id, owner: tx-sender} true)
        
        ;; Update transaction with additional signature
        (map-set transaction-records transaction-id (merge transaction {signatures-count: (+ (get signatures-count transaction) u1)}))
        (ok true)
    )
)

;; Execute a transaction once it has sufficient signatures
(define-public (execute-transaction (transaction-id uint))
    (let
        (
            (transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED))
        )
        ;; Verify caller is authorized and the transaction has not been executed
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (not (get executed transaction)) ERR-ALREADY-EXECUTED)
        
        ;; Check if the transaction has enough signatures to execute
        (asserts! (>= (get signatures-count transaction) (var-get approval-threshold)) ERR-INSUFFICIENT_SIGNATURES)
        
        ;; Attempt to execute STX transfer
        (match (stx-transfer? (get amount transaction) (as-contract tx-sender) (get recipient transaction))
            success (begin
                ;; Mark transaction as executed
                (map-set transaction-records transaction-id (merge transaction {executed: true}))
                (ok true)
            )
            error ERR-TRANSFER_FAILED
        )
    )
)

;; Read-only function to get transaction details
(define-read-only (get-transaction-details (transaction-id uint))
    (map-get? transaction-records transaction-id)
)

;; Read-only function to retrieve approval threshold
(define-read-only (get-approval-threshold)
    (var-get approval-threshold)
)

;; Read-only function to validate if recipient is a valid principal
(define-read-only (is-valid-recipient (recipient principal))
    (not (is-eq recipient (as-contract tx-sender)))
)
