# Cross-Chain Transfer Protocol: Formal Specification

## Overview

This document specifies the three-step protocol for moving value between parent and child chains in the Lattice hierarchy. The protocol requires no trusted intermediaries -- all verification is performed via Sparse Merkle proofs against state roots committed in blocks.

## Definitions

- **P**: Parent chain
- **C**: Child chain (P is C's parent)
- **P.block[i]**: The block at index i on chain P
- **C.block[j]**: The block at index j on chain C
- **S.depositState**: The DepositState Sparse Merkle Tree in state S
- **S.receiptState**: The ReceiptState Sparse Merkle Tree in state S
- **S.withdrawalState**: The WithdrawalState Sparse Merkle Tree in state S
- **homestead(B)**: The confirmed state entering block B (equals frontier of B's parent)
- **frontier(B)**: The state after applying B's transactions to homestead(B)
- **parentHomestead(B)**: For child chain blocks, a committed snapshot of the parent chain's state

## Invariants

**INV-1: State continuity.** For all blocks B with parent block B':
```
homestead(B) == frontier(B')
```

**INV-2: Parent state commitment.** For child chain block C.block[j] merged-mined in parent block P.block[i]:
```
parentHomestead(C.block[j]) == homestead(P.block[i])
```

**INV-3: Deposit uniqueness.** For any deposit key K, at most one entry exists in depositState:
```
∀ K: |{ entry ∈ depositState | entry.key == K }| ≤ 1
```

**INV-4: Withdrawal uniqueness.** For any deposit key K, at most one withdrawal exists:
```
∀ K: |{ entry ∈ withdrawalState | entry.key == K }| ≤ 1
```

**INV-5: Balance conservation.** For any block B at index i with spec S:
```
Σ(newBalance) ≤ Σ(oldBalance) - Σ(amountDeposited) + Σ(amountWithdrawn) + S.reward(i) + Σ(fee)
```

## Types

### DepositKey
```
DepositKey = {
    demander: String,       // CID of the recipient's public key
    amountDemanded: UInt64, // Amount requested
    nonce: UInt128          // Unique identifier
}

Serialization: "{demander}/{amountDemanded}/{nonce}"
```

### ReceiptKey
```
ReceiptKey = {
    directory: String,      // Child chain identifier
    demander: String,       // CID of the recipient's public key
    amountDemanded: UInt64, // Amount requested
    nonce: UInt128          // Unique identifier (matches DepositKey.nonce)
}

Serialization: "{directory}/{demander}/{amountDemanded}/{nonce}"
```

### DepositAction
```
DepositAction = {
    nonce: UInt128,
    demander: String,
    amountDemanded: UInt64,
    amountDeposited: UInt64
}
```

### ReceiptAction
```
ReceiptAction = {
    withdrawer: String,
    nonce: UInt128,
    demander: String,
    amountDemanded: UInt64,
    directory: String
}
```

### WithdrawalAction
```
WithdrawalAction = {
    withdrawer: String,
    nonce: UInt128,
    demander: String,
    amountDemanded: UInt64,
    amountWithdrawn: UInt64
}
```

## Protocol Steps

### Step 1: Deposit (on child chain C)

**Preconditions:**
- Transaction is included in C.block[j]
- Transaction body contains a `DepositAction` D
- D.amountDeposited > 0

**State transition:**
```
K = DepositKey(D.nonce, D.demander, D.amountDemanded)
C.depositState' = C.depositState.insert(K, D.amountDeposited)
```

**Proof obligation:**
- Sparse Merkle insertion proof that K does NOT exist in current depositState (prevents duplicate deposits)

**Effect on balance conservation (INV-5):**
- D.amountDeposited is subtracted from the available balance pool. The depositor's account must have sufficient balance reduced via a corresponding AccountAction.

### Step 2: Receipt (on parent chain P)

**Preconditions:**
- Transaction is included in P.block[i]
- Transaction body contains a `ReceiptAction` R
- R references child chain C by directory name

**State transition:**
```
K = ReceiptKey(R.directory, R.demander, R.amountDemanded, R.nonce)
P.receiptState' = P.receiptState.insert(K, R.withdrawer)
```

**Proof obligation:**
- Sparse Merkle insertion proof that K does NOT exist in current receiptState (prevents duplicate receipts)

**Note:** The receipt step does NOT verify that the corresponding deposit exists. It simply records the parent chain's acknowledgment. The security comes from Step 3, which requires both the deposit AND the receipt to exist.

### Step 3: Withdrawal (on child chain C)

**Preconditions:**
- Transaction is included in C.block[k] where k > j (after the deposit block)
- Transaction body contains a `WithdrawalAction` W
- C.block[k] has a committed parentHomestead from P.block[m] where m >= i (after the receipt block)

**Verification (two Merkle proofs):**
```
depositKey = DepositKey(W.nonce, W.demander, W.amountDemanded)
receiptKey = ReceiptKey(C.directory, W.demander, W.amountDemanded, W.nonce)

PROOF 1: homestead(C.block[k]).depositState contains depositKey
         (proves the deposit was made on this child chain)

PROOF 2: parentHomestead(C.block[k]).receiptState contains receiptKey
         (proves the parent chain acknowledged the deposit)
```

**State transition:**
```
K = DepositKey(W.nonce, W.demander, W.amountDemanded)
C.withdrawalState' = C.withdrawalState.insert(K, WithdrawalValue(W.withdrawer, W.amountWithdrawn))
```

**Proof obligation:**
- Sparse Merkle insertion proof that K does NOT exist in current withdrawalState (prevents double withdrawal -- INV-4)

**Effect on balance conservation (INV-5):**
- W.amountWithdrawn is added to the available balance pool. The withdrawer's account can be credited via a corresponding AccountAction.

## Security Properties

### Property 1: No value creation
Value cannot be created through cross-chain transfers. The deposit locks funds on the child chain (reducing available balance), and the withdrawal unlocks funds (increasing available balance). The receipt is a zero-value acknowledgment.

**Proof sketch:** By INV-5, each block's total balance after is bounded by total balance before minus deposits plus withdrawals plus reward plus fees. A deposit increases the "deposits" term, reducing available balance. A withdrawal increases the "withdrawals" term, restoring balance. The net effect across a deposit-receipt-withdrawal cycle is zero change to total supply.

### Property 2: No double withdrawal
Each deposit can be withdrawn at most once. The withdrawalState uses Sparse Merkle insertion proofs (INV-4), so a second withdrawal with the same deposit key would fail the insertion proof (key already exists).

### Property 3: No withdrawal without deposit
A withdrawal requires PROOF 1 (deposit exists in child chain's depositState). If no deposit was made, the Merkle proof fails.

### Property 4: No withdrawal without receipt
A withdrawal requires PROOF 2 (receipt exists in parent chain's receiptState, accessed via parentHomestead). If no receipt was issued on the parent chain, the Merkle proof fails.

### Property 5: Parent state cannot be fabricated
The parentHomestead in a child chain block is validated against the actual parent chain block via `validateParentState(parent:)`:
```
parent.homestead.rawCID == parentHomestead.rawCID
```
A child chain block that claims a fake parentHomestead is rejected during validation. This prevents an attacker from fabricating a receipt that doesn't exist on the parent chain.

### Property 6: Replay protection
Each of the three steps uses Sparse Merkle insertion proofs, meaning the key must not already exist. Replaying any step fails because the key was already inserted by the first execution:
- Replayed deposit: key already in depositState
- Replayed receipt: key already in receiptState
- Replayed withdrawal: key already in withdrawalState

### Property 7: Cross-chain atomicity
The protocol is NOT atomic in the traditional sense. Each step is a separate transaction on a separate chain. However, the three steps are **sequentially dependent**:
- Step 2 (receipt) can happen independently of Step 1 (the receipt doesn't verify the deposit)
- Step 3 (withdrawal) requires BOTH Step 1 AND Step 2 to have been committed

This means a deposit without a receipt results in locked funds (the depositor cannot withdraw without the parent chain's acknowledgment). This is the cost of asynchronous cross-chain communication without bridges.

### Property 8: Liveness
If a deposit is made on chain C and a receipt is issued on chain P, the withdrawal WILL eventually succeed, provided:
1. Chain C continues to produce blocks (liveness of child chain)
2. At least one block on C has a parentHomestead from a P block at or after the receipt
3. The withdrawal transaction is included in a C block

There is no timeout or expiration on deposits or receipts.

## Failure Modes

### Deposit without receipt
Funds are locked on the child chain. The depositor cannot recover them unless a receipt is later issued on the parent chain. This is the primary risk of the protocol and motivates the need for reliable receipt submission.

### Receipt without deposit
The receipt is recorded on the parent chain but has no effect. A withdrawal attempt would fail PROOF 1 (no matching deposit in depositState). No funds are at risk.

### Parent chain reorg after receipt
If the parent chain reorganizes and the receipt-containing block is removed from the main chain, the parentHomestead in subsequent child chain blocks will reflect the reorg. The withdrawal would fail PROOF 2 because the receipt no longer exists in the parent's state. The deposit remains locked until a new receipt is issued.

### Child chain reorg after deposit
If the child chain reorganizes and the deposit-containing block is removed, the deposit no longer exists in depositState. Any subsequent withdrawal attempt fails PROOF 1. The funds are effectively returned to the depositor (the deposit transaction was undone by the reorg).

## Filter Inheritance

All three steps (deposit, receipt, withdrawal) are transactions that must pass the chain's JavaScript filters. Additionally, child chains inherit all parent chain filters:
- A deposit on chain C must pass C's filters AND P's filters
- A receipt on chain P must pass P's filters
- A withdrawal on chain C must pass C's filters AND P's filters

This ensures a parent chain can restrict what types of cross-chain transfers are permitted on its children.
