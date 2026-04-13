# Cross-Chain Exchange Protocol: Formal Specification

## Overview

This document specifies the protocol for trustless cross-chain atomic swaps between any two chains in the Lattice hierarchy. The protocol requires no trusted intermediaries -- all verification is performed via Sparse Merkle proofs against state roots committed in blocks. Fees are fully refundable on timeout.

## Definitions

- **N**: Nexus (root) chain
- **X**, **Y**: Any two chains in the lattice hierarchy
- **maker**: An entity that signs an order expressing intent to trade
- **matcher**: An entity (typically a miner) that pairs compatible orders and includes them in blocks
- **B[i]**: Block at index `i` on a given chain
- **homestead(B)**: The confirmed state entering block B (equals frontier of B's parent)
- **frontier(B)**: The state after applying B's transactions to homestead(B)
- **parentHomestead(B)**: For non-nexus blocks, a committed snapshot of the parent chain's state
- **SMT**: Sparse Merkle Tree

## Types

### SwapOrder

```
SwapOrder = {
    maker:        CID(PublicKey),   // Maker's address
    sourceChain:  string,           // Chain where tokens are locked
    sourceAmount: uint64,           // Maximum tokens to sell
    destChain:    string,           // Chain where tokens are received
    destAmount:   uint64,           // Minimum tokens to receive
    timelock:     uint64,           // Expiry block height and refund threshold
    nonce:        uint128,          // Unique identifier
    fee:          uint64            // Fee the maker agrees to pay (proportional to fill)
}
```

### SignedOrder

```
SignedOrder = {
    order:     SwapOrder,
    publicKey: string,              // Maker's secp256k1 public key (hex)
    signature: string               // secp256k1 signature over doubleSha256(JSON(order))
}

Validity: verify(signature, doubleSha256(JSON(order)), publicKey) AND CID(publicKey) == order.maker
```

### MatchedOrder

```
MatchedOrder = {
    orderA:      SignedOrder,
    orderB:      SignedOrder,
    nonce:       uint128,           // Match identifier
    fillAmountA: uint64,            // Tokens filled from order A
    fillAmountB: uint64             // Tokens filled from order B
}
```

### SwapKey

```
SwapKey = sender || "/" || recipient || "/" || amount || "/" || timelock || "/" || nonce

Serialization: "sender/recipient/amount/timelock/nonce"
```

### SettleKey

```
SettleKey = directory || ":" || swapKey

Serialization: "directory:sender/recipient/amount/timelock/nonce"
```

## Invariants

**INV-1: State continuity.** For all blocks B with parent block B':
```
homestead(B) == frontier(B')
```

**INV-2: Swap uniqueness.** For any SwapKey K, at most one entry exists in swapState:
```
∀ K: |{ entry ∈ swapState | entry.key == K }| ≤ 1
```

**INV-3: Settlement uniqueness.** For any SettleKey K, at most one entry exists in settleState:
```
∀ K: |{ entry ∈ settleState | entry.key == K }| ≤ 1
```

**INV-4: Balance conservation.** For any block B at index i with spec S:
```
totalCredits ≤ totalDebits + S.reward(i) + totalFees + totalSwapClaimed - totalSwapLocked + totalOrderReleased - totalOrderLocked
```

**INV-5: Refundable fees.** The swap lock amount includes the proportional fee:
```
swapLockAmount = fillAmount + floor(order.fee × fillAmount / order.sourceAmount)
```
This ensures the full locked value is returned on refund.

**INV-6: Order expiry.** Matched orders are only valid before their timelock:
```
∀ match ∈ matchedOrders: match.orderA.timelock > blockIndex AND match.orderB.timelock > blockIndex
```

## Settlement Chain Selection

Settlement goes on the **lowest common ancestor (LCA)** of the two source chains in the chain hierarchy, not always the nexus. This reduces load on the nexus for swaps between tokens on the same chain or between sibling chains.

- For swaps where both orders target the same chain (e.g., both sourceChain == "ChainA"), the LCA is that chain itself. The entire lifecycle (match, lock, settle, claim) happens on ChainA without involving the nexus.
- For swaps between sibling chains under the nexus (e.g., sourceChain "ChainA" and "ChainB"), the LCA is the nexus.
- The `chainPath` on the transaction determines which chain processes it and where settlement is recorded.

Claim verification checks **both** the chain's own `settleState` and its `parentHomestead.settleState`. This means a claim succeeds whether the settlement was placed on the chain itself (when it's the LCA) or on its parent.

## Protocol Steps

### Step 1: Lock (on each maker's source chain)

**Preconditions:**
- Transaction is included in a block on the maker's source chain
- Transaction body contains a `MatchedOrder` M in `matchedOrders`
- Both `SignedOrder`s are valid (signatures verify, makers match)
- Orders are compatible (see Matching Rules below)
- Orders are not expired (`timelock > blockIndex`)

**Derived state transitions on chain X (where orderA.sourceChain == X):**

```
// Account debit
AccountAction(owner: orderA.maker, delta: -(fillAmountA + feeA))

// Swap lock (fill + fee locked together)
swapKeyA = SwapKey(nonceA, makerA, makerB, fillAmountA + feeA, timelock)
X.swapState' = X.swapState.insert(swapKeyA, fillAmountA + feeA)
```

**Derived state transition on nexus (regardless of which chain the block is on):**

```
// Settlement record
settleKeyA = SettleKey(X, swapKeyA)
settleKeyB = SettleKey(Y, swapKeyB)
N.settleState' = N.settleState.insert(settleKeyA, nonce).insert(settleKeyB, nonce)
```

**Proof obligations:**
- SwapKey insertion proof: key does NOT exist in swapState (prevents duplicate locks)
- SettleKey insertion proofs: keys do NOT exist in settleState (prevents duplicate settlements)

**Effect on balance conservation (INV-4):**
- `totalDebits` increases by `fillAmountA + feeA`
- `totalSwapLocked` increases by `fillAmountA + feeA`
- Net effect on available balance: 0 (debit exactly offset by lock)

### Step 2: Claim (on each maker's source chain)

**Preconditions:**
- Transaction is included in a block on the source chain
- Transaction body contains a `MatchedOrder` M in `claimedOrders`
- Settlement proof exists: `SettleKey(X, swapKeyA)` in settleState (nexus) or parentHomestead.settleState (child chain)

**Derived state transitions on chain X (where orderA.sourceChain == X):**

```
// Counterparty credit (fill amount only, NOT including fee)
AccountAction(owner: orderB.maker, delta: +fillAmountA)

// Swap unlock (full lock amount)
swapKeyA = SwapKey(nonceA, makerA, makerB, fillAmountA + feeA, timelock)
X.swapState' = X.swapState.delete(swapKeyA)
```

**Proof obligation:**
- SwapKey mutation proof: key EXISTS in swapState (proves lock exists, then deletes it)

**Effect on balance conservation (INV-4):**
- `totalCredits` increases by `fillAmountA` (counterparty) + miner coinbase fee
- `totalSwapClaimed` increases by `fillAmountA + feeA`
- The miner captures the fee from the excess: `swapClaimed - counterpartyCredit = feeA`

### Step 3: Refund (after timeout)

**Preconditions:**
- `blockIndex > timelock` (swap has expired)
- Sender submits a `SwapClaimAction` with `isRefund = true`

**State transition:**

```
// Sender reclaims full locked amount (fill + fee)
swapKeyA = SwapKey(nonceA, makerA, makerB, fillAmountA + feeA, timelock)
X.swapState' = X.swapState.delete(swapKeyA)
// Sender credits themselves via explicit AccountAction
```

**Effect:** The maker gets back everything they locked, including the fee. No value is lost.

## Matching Rules

A `MatchedOrder(orderA, orderB, nonce, fillAmountA, fillAmountB)` is valid if:

1. `orderA.sourceChain == orderB.destChain` (cross-chain match)
2. `orderA.destChain == orderB.sourceChain` (symmetric)
3. `orderA.sourceChain != orderA.destChain` (no same-chain swaps)
4. `orderA.maker != orderB.maker` (different parties)
5. `orderA.timelock == orderB.timelock` (synchronized expiry)
6. `orderA.timelock > 0` (positive timelock)
7. `fillAmountA > 0 && fillAmountB > 0` (non-zero fills)
8. `fillAmountA <= orderA.sourceAmount` (within order limit)
9. `fillAmountB <= orderB.sourceAmount` (within order limit)
10. `fillAmountA + feeA <= Int64.max` (safe for delta arithmetic)
11. `fillAmountB + feeB <= Int64.max` (safe for delta arithmetic)
12. `fillAmountB × orderA.sourceAmount >= fillAmountA × orderA.destAmount` (A's rate satisfied)
13. `fillAmountA × orderB.sourceAmount >= fillAmountB × orderB.destAmount` (B's rate satisfied)

Rate comparisons use UInt128 cross-multiplication to avoid floating-point imprecision.

**Block-level rules** (in `matchedOrdersAreValid`):
- `timelock > blockIndex` for all matched orders (expiry check)
- Uniform clearing price: all matches in the same directed pair execute at the same rate
- Cumulative fills per order (keyed by `doubleSha256(JSON(order))`) must not exceed `sourceAmount`

## Fee Model

### Proportional Fee

Each order specifies a `fee` for the full `sourceAmount`. The actual fee charged is proportional to the fill:

```
feeA = floor(orderA.fee × fillAmountA / orderA.sourceAmount)
```

Computed via UInt128 to avoid overflow.

### Refundable Fee Design

The fee is locked alongside the fill amount in swap state:

```
swapLockAmount = fillAmountA + feeA
```

**Why:** If the fee were collected at lock time (non-refundable), a maker whose swap times out would lose the fee despite the trade never completing. By locking fee + fill together:

- **Successful trade:** Counterparty gets `fillAmount`, miner gets `fee` (from swapClaimed excess)
- **Timeout:** Maker refunds the full `swapLockAmount` -- no loss

### Fee Accounting

Order fees do NOT appear in the `totalFees` term of the balance equation. Instead, they flow through the `totalSwapClaimed` term:

```
Balance equation: totalCredits ≤ totalDebits + reward + totalFees + swapClaimed - swapLocked

Lock phase:   swapLocked = fill + fee,  swapClaimed = 0        → net: -(fill + fee) + debits
Claim phase:  swapLocked = 0,           swapClaimed = fill + fee → credits: fill (counterparty) + fee (miner)
Refund:       swapLocked = 0,           swapClaimed = fill + fee → credit: fill + fee (original sender)
```

The `derivedOrderFees` function reports:
- **Lock phase:** 0 (no fee available)
- **Claim phase:** Full proportional fee (available for miner coinbase)

## Security Properties

### Property 1: No value creation

The balance equation guarantees that credits cannot exceed debits plus block reward plus the net swap flow. Fees are zero-sum within the swapClaimed term: `swapClaimed = counterpartyCredit + minerFee`.

### Property 2: No double-fill

Within a block, fills are tracked by `doubleSha256(JSON(order))` (not just nonce, since different makers can have the same nonce). Across blocks, SwapKey uniqueness in swap state (via insertion proofs) prevents the same lock from being created twice.

### Property 3: No stale execution

Order expiry (`timelock > blockIndex`) prevents matchers from filling orders long after the maker intended them to expire. This is enforced at consensus -- invalid matches are rejected.

### Property 4: Claim/refund mutual exclusion

Claims require a settlement proof, which is only created during the lock phase. Refunds require `blockIndex > timelock`. If the swap is claimed before timeout, the SwapKey is deleted -- a subsequent refund fails the mutation proof (key no longer exists). If the swap times out and is refunded, the SwapKey is deleted -- a subsequent claim also fails.

### Property 5: Cross-chain atomicity

Settlement on the nexus provides coordination. Locks on chains X and Y produce settlement entries `SettleKey(X, swapKeyA)` and `SettleKey(Y, swapKeyB)`. Both claims check the same settlement state. Either:
- Both settlements exist → both parties can claim
- Timeout → both parties can refund

There is no state where one party claims and the other cannot. The timelock must match between orders (rule 5), ensuring both locks expire at the same block height.

### Property 6: Replay protection

Each step uses Sparse Merkle proofs:
- Lock: insertion proof (SwapKey must not exist) → prevents duplicate locks
- Settle: insertion proof (SettleKey must not exist) → prevents duplicate settlements
- Claim: mutation proof (SwapKey must exist, then delete) → prevents double-claims
- Refund: mutation proof (SwapKey must exist, then delete) → prevents double-refunds

### Property 7: Settlement persistence

Settle state entries are never deleted. Once a settlement is recorded on the nexus, it persists permanently. This means child chains can always verify that a settlement occurred, regardless of how much later the claim is submitted.

### Property 8: Same-chain rejection

Orders where `sourceChain == destChain` are rejected (rule 3). Same-chain swaps are meaningless (just transfer directly) and would spam swap state.

## Miner Incentives

Miners are incentivized to include exchange transactions through two mechanisms:

1. **Claim-phase fee:** The miner who includes a claim transaction captures the full order fee via the swapClaimed excess. This is the primary incentive for the exchange protocol.

2. **Transaction fee:** The explicit `body.fee` on any transaction (independent of order fees) compensates miners for inclusion. This applies to all transactions, including those containing matched orders.

**Trade-off:** Lock-phase transactions produce no immediate order fee for the miner. The miner's incentive to include locks is the expectation of mining future claim blocks. In practice, miners who operate order books have a natural advantage: they control which orders to match and can immediately include claims in subsequent blocks.

## Persistent On-Chain Order Book

In addition to the instant matching protocol above (`matchedOrders`), the exchange supports a persistent on-chain order book where funds are escrowed at post time. This enables makers to post orders that persist across blocks and are filled later by matchers.

### Order Lock State

An 8th Sparse Merkle Tree in `LatticeState` tracks locked order funds:

```
orderLockState: SMT<OrderLockKey → uint64>

OrderLockKey = maker || "/" || nonce
```

The value is the remaining locked amount (`sourceAmount + fee` at post time, decreasing with partial fills).

### Post (lock funds)

A `SignedOrder` in the transaction's `postOrders` field:

1. Debits the maker's account by `sourceAmount + fee`
2. Inserts `OrderLockKey(maker, nonce) → sourceAmount + fee` into `orderLockState`
3. The insertion proof ensures the order hasn't been posted before

**Validation:** Same as `matchedOrders` signature checks, plus: maker must be a signer, no same-chain orders, positive amounts, and `sourceAmount + fee` must fit in Int64.

### Fill (convert lock to swap)

A `MatchedOrder` in the transaction's `orderFills` field triggers the same derived actions as `matchedOrders` (swap locks, settlements, claims), plus:

1. Releases `fillAmount + proportionalFee` from each maker's `orderLockState` entry
2. If the remaining locked amount reaches 0, the entry is deleted (full fill)
3. Otherwise, the entry is updated with the reduced amount (partial fill)

The fill converts order-locked funds into swap-locked funds. The balance equation balances because `totalOrderReleased` offsets `totalSwapLocked`.

Fill transactions may be signer-less (the signed orders provide authorization), but must have `fee == 0`.

### Cancel (return funds)

An `OrderCancellation` in the transaction's `cancelOrders` field:

1. Credits the maker's account by the remaining locked `amount`
2. Deletes `OrderLockKey(maker, orderNonce)` from `orderLockState`

**Critical safety check:** The declared `amount` must exactly match the value stored in `orderLockState`. This is verified during the state proof -- a cancellation with an inflated amount is rejected at consensus.

### Balance Conservation with Order Locks

The extended balance equation:

```
totalCredits ≤ totalDebits + reward + totalFees + totalSwapClaimed - totalSwapLocked + totalOrderReleased - totalOrderLocked
```

| Phase | orderLocked | orderReleased | swapLocked | Debits | Credits | Net |
|-------|-------------|---------------|------------|--------|---------|-----|
| Post  | +lockAmt    | 0             | 0          | +lockAmt | 0     | 0   |
| Fill  | 0           | +releaseAmt   | +releaseAmt | 0     | 0       | 0   |
| Cancel | 0          | +cancelAmt    | 0          | 0      | +cancelAmt | 0 |

Every phase is zero-sum. No tokens are created or destroyed.
