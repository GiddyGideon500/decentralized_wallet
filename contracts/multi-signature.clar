;; Multi-Signature Wallet Contract
;;
;; This smart contract implements a decentralized multi-signature wallet 
;; where multiple authorized owners must approve transactions before they 
;; can be executed. The contract now includes functionality to retrieve 
;; a list of authorized owners.

;; Error constants for transaction handling
(define-constant ERR-NOT-AUTHORIZED (err u100))      ;; Unauthorized access attempt
(define-constant ERR-ALREADY-EXECUTED (err u101))   ;; Transaction already executed
(define-constant ERR-INVALID-THRESHOLD (err u102))   ;; Invalid approval threshold
(define-constant ERR-DUPLICATE_SIGNATURE (err u103)) ;; Signature already recorded
(define-constant ERR-INSUFFICIENT_SIGNATURES (err u104)) ;; Not enough signatures to execute
(define-constant ERR-INVALID_RECIPIENT (err u105))   ;; Invalid recipient address
(define-constant ERR-INVALID_AMOUNT (err u106))      ;; Invalid transaction amount
(define-constant ERR-TRANSFER_FAILED (err u107))     ;; STX transfer failure
(define-constant ERR-TRANSACTION-NOT-PENDING (err u108)) ;; Transaction cannot be canceled
(define-constant ERR-ALREADY-CANCELED (err u109))    ;; Transaction already canceled
(define-constant ERR-OWNERS-LIST-FULL (err u110))    ;; Maximum number of owners reached

;; Configuration data: stores the approval threshold and current transaction ID
(define-data-var approval-threshold uint u2) ;; Minimum number of signatures required for a transaction
(define-data-var current-transaction-id uint u0) ;; Tracks the next available transaction ID

;; Owner registry: stores authorized owners' principal addresses
(define-map authorized-owners principal bool)

;; List of owners to maintain order and enable listing
(define-data-var owners-list (list 20 principal) (list))

;; Transaction records: stores the details of each transaction
(define-map transaction-records 
    uint ;; Transaction ID
    {
        recipient: principal, ;; Recipient of the transaction
        amount: uint,          ;; Amount to transfer
        executed: bool,       ;; Whether the transaction has been executed
        canceled: bool,       ;; Whether the transaction has been canceled
        signatures-count: uint ;; Number of signatures for approval
    }
)

;; Transaction signatures: tracks which owners have signed each transaction
(define-map transaction-signatures 
    {transaction-id: uint, owner: principal} 
    bool
)

;; Initialize the contract with a list of owners and an approval threshold
(define-public (initialize (owners-list-param (list 20 principal)) (threshold uint))
    (begin
        ;; Ensure the threshold is valid (greater than 0 and less than or equal to the number of owners)
        (asserts! (>= threshold u1) ERR-INVALID-THRESHOLD)
        (asserts! (<= threshold (len owners-list-param)) ERR-INVALID-THRESHOLD)
        
        ;; Set the approval threshold
        (var-set approval-threshold threshold)
        
        ;; Clear any existing owners (if reinitializing)
        (var-set owners-list (list))
        
        ;; Register each authorized owner
        (map register-owners owners-list-param)
        (ok true)
    )
)

;; Private helper function to register an owner in the authorized owners list
(define-private (register-owners (owner principal))
    (begin
        (map-set authorized-owners owner true)
        (var-set owners-list 
            (unwrap! 
                (as-max-len? 
                    (append (var-get owners-list) owner) 
                    u20
                ) 
                false
            )
        )
    )
)

;; Public function to add a new owner (can only be done by existing owners)
(define-public (add-owner (new-owner principal))
    (let 
        (
            (current-owners (var-get owners-list))
        )
        ;; Ensure the caller is an existing owner
        (asserts! (or 
            (is-authorized-owner tx-sender) 
            (is-eq (len current-owners) u0)
        ) ERR-NOT-AUTHORIZED)
        
        ;; Check if owner already exists
        (asserts! (not (is-authorized-owner new-owner)) ERR-DUPLICATE_SIGNATURE)
        
        ;; Ensure we don't exceed the maximum number of owners
        (asserts! (< (len current-owners) u20) ERR-OWNERS-LIST-FULL)
        
        ;; Add owner to the map and list
        (map-set authorized-owners new-owner true)
        (var-set owners-list 
            (unwrap! 
                (as-max-len? 
                    (append current-owners new-owner) 
                    u20
                ) 
                ERR-OWNERS-LIST-FULL
            )
        )
        (ok true)
    )
)

;; Verify if the given account is an authorized owner
(define-private (is-authorized-owner (account principal))
    (default-to false (map-get? authorized-owners account))
)

;; Read-only function to retrieve the list of all authorized owners
(define-read-only (get-authorized-owners)
    (var-get owners-list)
)

;; Read-only function to check the total number of authorized owners
(define-read-only (get-owners-count)
    (len (var-get owners-list))
)

;; Submit a new transaction for approval by authorized owners
(define-public (submit-transaction (recipient principal) (amount uint))
    (let 
        (
            (transaction-id (var-get current-transaction-id))
        )
        ;; Verify sender is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        
        ;; Validate recipient and amount
        (asserts! (is-valid-recipient recipient) ERR-INVALID_RECIPIENT)
        (asserts! (> amount u0) ERR-INVALID_AMOUNT)
        
        ;; Create a new transaction record
        (map-set transaction-records transaction-id {
            recipient: recipient,
            amount: amount,
            executed: false,
            canceled: false,
            signatures-count: u1
        })
        
        ;; Record the initial signature from the sender
        (map-set transaction-signatures {transaction-id: transaction-id, owner: tx-sender} true)
        
        ;; Increment the transaction ID for future submissions
        (var-set current-transaction-id (+ transaction-id u1))
        (ok transaction-id)
    )
)

;; Approve an existing transaction by adding a signature from an authorized owner
(define-public (approve-transaction (transaction-id uint))
    (let 
        (
            (transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED))
        )
        ;; Ensure the caller is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        
        ;; Prevent duplicate signatures from the same owner
        (asserts! (not (default-to false (map-get? transaction-signatures {transaction-id: transaction-id, owner: tx-sender}))) ERR-DUPLICATE_SIGNATURE)
        
        ;; Ensure the transaction has not already been executed or canceled
        (asserts! (not (get executed transaction)) ERR-ALREADY-EXECUTED)
        (asserts! (not (get canceled transaction)) ERR-ALREADY-CANCELED)
        
        ;; Record the signature and update the signature count
        (map-set transaction-signatures {transaction-id: transaction-id, owner: tx-sender} true)
        (map-set transaction-records transaction-id (merge transaction {signatures-count: (+ (get signatures-count transaction) u1)}))
        (ok true)
    )
)

;; Execute a transaction once it has enough signatures
(define-public (execute-transaction (transaction-id uint))
    (let
        (
            (transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED))
        )
        ;; Ensure the caller is an authorized owner and the transaction has not been executed
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (not (get executed transaction)) ERR-ALREADY-EXECUTED)
        
        ;; Verify the transaction has enough signatures to be executed
        (asserts! (>= (get signatures-count transaction) (var-get approval-threshold)) ERR-INSUFFICIENT_SIGNATURES)
        
        ;; Attempt to execute the STX transfer
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

;; Cancel a pending transaction
(define-public (cancel-transaction (transaction-id uint))
    (let
        (
            (transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED))
        )
        ;; Ensure the caller is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        
        ;; Ensure the transaction has not been executed or already canceled
        (asserts! (not (get executed transaction)) ERR-TRANSACTION-NOT-PENDING)
        (asserts! (not (get canceled transaction)) ERR-ALREADY-CANCELED)
        
        ;; Mark transaction as canceled
        (map-set transaction-records transaction-id (merge transaction {canceled: true}))
        (ok true)
    )
)

(define-public (change-transaction-recipient (transaction-id uint) (new-recipient principal))
    (let
        ((transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED)))
        ;; Ensure transaction is still pending
        (asserts! (not (get executed transaction)) ERR-ALREADY-EXECUTED)
        (asserts! (not (get canceled transaction)) ERR-ALREADY-CANCELED)
        (map-set transaction-records transaction-id (merge transaction {recipient: new-recipient}))
        (ok true)
    )
)

(define-public (change-transaction-amount (transaction-id uint) (new-amount uint))
    (let
        ((transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED)))
        ;; Ensure transaction is still pending
        (asserts! (not (get executed transaction)) ERR-ALREADY-EXECUTED)
        (asserts! (not (get canceled transaction)) ERR-ALREADY-CANCELED)
        (map-set transaction-records transaction-id (merge transaction {amount: new-amount}))
        (ok true)
    )
)

(define-public (create-new-contract (contract-name (string-ascii 100)))
    (begin
        ;; Ensure the caller is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        ;; Create a new contract instance
        ;; Further contract creation logic could go here
        (ok contract-name)
    )
)

(define-public (check-enough-signatures (transaction-id uint))
    (let
        ((transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED)))
        (asserts! (>= (get signatures-count transaction) (var-get approval-threshold)) ERR-INSUFFICIENT_SIGNATURES)
        (ok true)
    )
)

(define-public (update-transaction-recipient (transaction-id uint) (new-recipient principal))
    (let
        ((transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED)))
        ;; Ensure the transaction is still pending
        (asserts! (not (get executed transaction)) ERR-ALREADY-EXECUTED)
        (asserts! (not (get canceled transaction)) ERR-ALREADY-CANCELED)
        ;; Update the recipient
        (map-set transaction-records transaction-id (merge transaction {recipient: new-recipient}))
        (ok true)
    )
)

(define-public (set-max-transaction-limit (new-limit uint))
    (begin
        ;; Ensure the caller is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        ;; Set the new limit (add logic to use the limit where needed)
        (ok true)
    )
)

(define-public (enable-emergency-mode)
    (begin
        ;; Ensure the caller is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        ;; Activate emergency mode logic
        (ok true)
    )
)

(define-public (disable-emergency-mode)
    (begin
        ;; Ensure the caller is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        ;; Deactivate emergency mode logic
        (ok true)
    )
)

(define-public (set-transaction-amount-threshold (new-threshold uint))
    (begin
        ;; Ensure the caller is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        ;; Set the new threshold (use it in transaction checks)
        (ok true)
    )
)



(define-public (upgrade-contract (new-contract principal))
    (begin
        ;; Ensure the caller is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        ;; Upgrade contract logic (can include versioning, etc.)
        (ok true)
    )
)

;; Function to revoke a signature for a transaction
(define-public (revoke-signature (transaction-id uint))
    (let ((transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED)))
        ;; Ensure the caller is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)
        ;; Ensure the transaction is still pending
        (asserts! (not (get executed transaction)) ERR-ALREADY-EXECUTED)
        (asserts! (not (get canceled transaction)) ERR-ALREADY-CANCELED)
        ;; Revoke the signature
        (map-set transaction-signatures {transaction-id: transaction-id, owner: tx-sender} false)
        (map-set transaction-records transaction-id (merge transaction {signatures-count: (- (get signatures-count transaction) u1)}))
        (ok true)
    )
)

;; Function to log an event for transaction submission
(define-public (log-transaction-event (transaction-id uint))
    (let ((transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED)))
        (asserts! (not (get executed transaction)) ERR-ALREADY-EXECUTED)
        (asserts! (not (get canceled transaction)) ERR-ALREADY-CANCELED)
        ;; Log event (stub implementation for future logging)
        (ok "Transaction event logged")
    )
)

;; Function to remove a pending transaction before execution
(define-public (remove-pending-transaction (transaction-id uint))
    (let ((transaction (unwrap! (map-get? transaction-records transaction-id) ERR-NOT-AUTHORIZED)))
        (asserts! (not (get executed transaction)) ERR-ALREADY-EXECUTED)
        (asserts! (not (get canceled transaction)) ERR-ALREADY-CANCELED)
        (map-set transaction-records transaction-id (merge transaction {canceled: true}))
        (ok true)
    )
)

;; Function to get the current limit on the number of owners
(define-public (get-owner-limit)
    (ok u20) ;; Default limit, can be adjusted as needed
)

;; Function to check if the contract is frozen
(define-public (is-contract-frozen)
    (begin
        ;; Check if the contract is frozen (using a state variable for the contract's frozen state)
        ;; (Further implementation needed to track the frozen state)
        (ok false)  ;; Return false as a placeholder, assuming the contract is not frozen
    )
)

;; Function to withdraw STX from the contract (only authorized owners can withdraw)
(define-public (withdraw-stx (amount uint))
    (begin
        ;; Ensure the caller is an authorized owner
        (asserts! (is-authorized-owner tx-sender) ERR-NOT-AUTHORIZED)

        ;; Ensure the amount is positive and valid
        (asserts! (> amount u0) ERR-INVALID_AMOUNT)

        ;; Attempt to transfer the STX
        (match (stx-transfer? amount (as-contract tx-sender) (as-contract tx-sender))
            success (ok true)
            error ERR-TRANSFER_FAILED
        )
    )
)



;; Read-Only Functions
;; Read-only function to check if a transaction has been executed
(define-read-only (is-transaction-executed (transaction-id uint))
    (match (map-get? transaction-records transaction-id)
        transaction (get executed transaction)
        false
    )
)

;; Read-only function to check if a transaction has been canceled
(define-read-only (is-transaction-canceled (transaction-id uint))
    (match (map-get? transaction-records transaction-id)
        transaction (get canceled transaction)
        false
    )
)

;; Read-only function to retrieve transaction details
(define-read-only (get-transaction-details (transaction-id uint))
    (map-get? transaction-records transaction-id)
)

;; Read-only function to retrieve the current approval threshold
(define-read-only (get-approval-threshold)
    (var-get approval-threshold)
)

;; Read-only function to validate whether the recipient is a valid principal (not the sender)
(define-read-only (is-valid-recipient (recipient principal))
    (not (is-eq recipient (as-contract tx-sender)))
)

(define-read-only (is-emergency-mode-active)
    ;; Return status of emergency mode (implement as state variable)
    false
)

(define-read-only (get-transaction (transaction-id uint))
    (map-get? transaction-records transaction-id)
)

(define-read-only (is-contract-active)
    ;; Return contract active status (implement as state variable)
    true
)
