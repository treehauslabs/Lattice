# Lattice Protocol Specification

Version 0.1.0 -- Draft

## 1. Overview

Lattice is a hierarchical multi-chain blockchain protocol. A single root chain (the **nexus**) can spawn child chains via genesis transactions. Child chains inherit security from their parent through **parent chain anchoring** and support trustless cross-chain value transfer through a three-phase **deposit/receipt/withdrawal** protocol.

All state is content-addressed using IPLD/CID. Blocks reference state via Merkle roots, enabling light client verification without full state replication.

## 2. Notation

- `H(x)` -- SHA-256 hash of `x`
- `CID(x)` -- Content Identifier of serialized `x` (IPLD DAG-CBOR + SHA-256)
- `SMT` -- Sparse Merkle Tree
- `B[i]` -- Block at index `i` on a given chain
- `||` -- concatenation
- `>>` -- arithmetic right shift
- `U256` -- 256-bit unsigned integer

## 3. Data Structures

### 3.1 Block

A block `B` is a tuple:

```
B = (
    previousBlock:    CID(Block) | nil,
    transactions:     CID(MerkleDictionary<CID(Transaction)>),
    difficulty:       U256,
    nextDifficulty:   U256,
    spec:             CID(ChainSpec),
    parentHomestead:  CID(LatticeState),
    homestead:        CID(LatticeState),
    frontier:         CID(LatticeState),
    childBlocks:      CID(MerkleDictionary<CID(Block)>),
    index:            uint64,
    timestamp:        int64,
    nonce:            uint64
)
```

### 3.2 Transaction

```
Transaction = (
    signatures: Map<PublicKeyHex, SignatureHex>,
    body:       CID(TransactionBody)
)
```

### 3.3 TransactionBody

```
TransactionBody = (
    accountActions:     [AccountAction],
    actions:            [Action],
    swapActions:        [SwapAction],
    swapClaimActions:   [SwapClaimAction],
    genesisActions:     [GenesisAction],
    peerActions:        [PeerAction],
    settleActions:      [SettleAction],
    signers:            [CID(PublicKey)],
    fee:                uint64,
    nonce:              uint64,
    chainPath:          [string],
    matchedOrders:      [MatchedOrder],
    claimedOrders:      [MatchedOrder],
    postOrders:         [SignedOrder],
    cancelOrders:       [OrderCancellation],
    orderFills:         [MatchedOrder]
)
```

### 3.4 LatticeState

The world state is an 8-tuple of Sparse Merkle Tree roots:

```
LatticeState = (
    accountState:      SMT<CID(PublicKey) -> uint64>,
    generalState:      SMT<string -> string>,
    swapState:         SMT<SwapKey -> uint64>,
    peerState:         SMT<CID(PublicKey) -> PeerInfo>,
    genesisState:      SMT<string -> CID(Block)>,
    settleState:       SMT<SettleKey -> uint64>,
    transactionState:  SMT<uint64 -> CID(TransactionBody)>,
    orderLockState:    SMT<OrderLockKey -> uint64>
)
```

### 3.5 ChainSpec

```
ChainSpec = (
    directory:                      string,
    maxNumberOfTransactionsPerBlock: uint64,
    maxStateGrowth:                 int,
    premine:                        uint64,
    targetBlockTime:                uint64,     // milliseconds
    initialRewardExponent:          uint8,
    transactionFilters:             [string],   // JavaScript expressions
    actionFilters:                  [string]    // JavaScript expressions
)
```

**Derived constants:**

```
halvingExponent   = 64 - initialRewardExponent
halvingInterval   = 2^halvingExponent
initialReward     = 2^initialRewardExponent
maxDifficultyChange = 2                         // protocol constant
totalHalvings     = initialRewardExponent
maxSupply         = UInt64.max
```

### 3.6 Action Types

#### AccountAction

```
AccountAction = (owner: CID(PublicKey), oldBalance: uint64, newBalance: uint64)
```

**Validity:** `oldBalance != newBalance`

#### Action (Generic Key-Value)

```
Action = (key: string, oldValue: string?, newValue: string?)
```

**Validity:** `key != ""` AND (`oldValue != nil` OR `newValue != nil`)

#### DepositAction

```
DepositAction = (nonce: uint128, demander: CID(PublicKey), amountDemanded: uint64, amountDeposited: uint64)
```

#### WithdrawalAction

```
WithdrawalAction = (withdrawer: CID(PublicKey), nonce: uint128, demander: CID(PublicKey), amountDemanded: uint64, amountWithdrawn: uint64)
```

#### ReceiptAction

```
ReceiptAction = (withdrawer: CID(PublicKey), nonce: uint128, demander: CID(PublicKey), amountDemanded: uint64, directory: string)
```

#### GenesisAction

```
GenesisAction = (directory: string, block: Block)
```

#### PeerAction

```
PeerAction = (owner: CID(PublicKey), IpAddress: string, refreshed: int64, fullNode: bool, type: PeerActionType)
PeerActionType = insert | update | delete
```

#### SwapAction

```
SwapAction = (nonce: uint128, sender: CID(PublicKey), recipient: CID(PublicKey), amount: uint64, timelock: uint64)
```

Locks `amount` tokens in swap state. The sender's account is debited and the tokens become claimable by the recipient after settlement proof, or refundable by the sender after timelock expiry.

#### SwapClaimAction

```
SwapClaimAction = (nonce: uint128, sender: CID(PublicKey), recipient: CID(PublicKey), amount: uint64, timelock: uint64, isRefund: bool)
```

Unlocks a swap. If `isRefund == false`, the recipient claims after settlement proof. If `isRefund == true`, the sender reclaims after `blockIndex > timelock`.

#### SettleAction

```
SettleAction = (nonce: uint128, senderA: CID(PublicKey), senderB: CID(PublicKey), swapKeyA: string, directoryA: string, swapKeyB: string, directoryB: string)
```

Records a settlement on the nexus chain. Both parties must be signers. Settlement proofs in settle state are later used to authorize cross-chain claims.

#### SwapOrder

```
SwapOrder = (
    maker:        CID(PublicKey),
    sourceChain:  string,
    sourceAmount: uint64,
    destChain:    string,
    destAmount:   uint64,
    timelock:     uint64,
    nonce:        uint128,
    fee:          uint64
)
```

A maker's intent to exchange `sourceAmount` on `sourceChain` for at least `destAmount` on `destChain`. The `fee` is a per-order fee that the maker agrees to pay, proportional to the fill amount.

#### SignedOrder

```
SignedOrder = (order: SwapOrder, publicKey: string, signature: string)
```

An order signed by the maker's private key. `signature` covers `doubleSha256(JSON(order))`. The `makerAddress` (CID of publicKey) must equal `order.maker`.

#### MatchedOrder

```
MatchedOrder = (
    orderA:      SignedOrder,
    orderB:      SignedOrder,
    nonce:       uint128,
    fillAmountA: uint64,
    fillAmountB: uint64
)
```

A fill between two crossing orders. Both signed orders are verified at consensus. The match derives swap, settle, claim, and account actions automatically (see section 8).

#### OrderCancellation

```
OrderCancellation = (
    orderNonce: uint128,
    maker:      CID(PublicKey),
    publicKey:  string,
    signature:  string,
    amount:     uint64              // Remaining locked amount (verified against state)
)
```

A signed cancellation of a previously posted order. `signature` covers `doubleSha256("cancel:" || orderNonce)`. The `amount` field must exactly match the value stored in `orderLockState` -- the state proof verifies this at consensus.

#### OrderPostAction (derived)

```
OrderPostAction = (maker: CID(PublicKey), nonce: uint128, lockAmount: uint64)
```

Derived from `postOrders`. Inserts `lockAmount` (= `sourceAmount + fee`) into `orderLockState`.

#### OrderReleaseAction (derived)

```
OrderReleaseAction = (maker: CID(PublicKey), nonce: uint128, releaseAmount: uint64)
```

Derived from `orderFills`. Reduces the locked amount in `orderLockState` by `releaseAmount` (= `fillAmount + proportionalFee`). If the remaining amount reaches 0, the entry is deleted.

#### OrderCancelAction (derived)

```
OrderCancelAction = (maker: CID(PublicKey), nonce: uint128, amount: uint64)
```

Derived from `cancelOrders`. Deletes the entry from `orderLockState` after verifying the declared `amount` matches the stored value.

### 3.7 Keys

#### SwapKey

```
SwapKey = sender || "/" || recipient || "/" || amount || "/" || timelock || "/" || nonce
```

Used to index `SwapState`. The swap amount includes the proportional fee so that the full locked value (fill + fee) can be refunded on timeout.

#### SettleKey

```
SettleKey = directory || ":" || swapKey
```

Used to index `SettleState`. Associates a swap on a specific chain with a settlement record on the nexus.

#### OrderLockKey

```
OrderLockKey = maker || "/" || nonce
```

Used to index `OrderLockState`. Tracks the remaining locked amount for a posted order.

### 3.8 Consensus Types

#### BlockMeta

```
BlockMeta = (
    blockInfo:          BlockInfoImpl,
    parentChainBlocks:  Map<ParentBlockHash, ParentBlockIndex?>,
    childBlockHashes:   [string]
)
```

#### Reorganization

```
Reorganization = (
    mainChainBlocksAdded:   Map<BlockHash, BlockIndex>,
    mainChainBlocksRemoved: Set<BlockHash>
)
```

## 4. Chain Hierarchy

### 4.1 Structure

Chains form a rooted tree:

```
    Nexus
   /     \
  A       B
 / \
A1  A2
```

Each chain is identified by a `directory` name defined in its `ChainSpec`. The nexus chain is the root. Child chains are created by including a `GenesisAction` in a transaction on the parent chain.

### 4.2 Chain Level

Each chain is managed by a `ChainLevel`:

```
ChainLevel = (
    chain:    ChainState,      // consensus for this chain
    children: Map<directory, ChainLevel>
)
```

Block processing is recursive: if a block does not belong to the current chain's difficulty target, it is offered to child chains.

## 5. Block Validation

### 5.1 Genesis Block Validation

A genesis block `B` is valid if and only if ALL of the following hold:

1. `B.previousBlock == nil`
2. `B.index == 0`
3. `B.timestamp <= now()`
4. `B.homestead == CID(emptyState())`
5. All transactions in `B.transactions` are fully resolvable
6. For each transaction `tx`: `tx.validateTransactionForGenesis()` returns true
   - Signatures are valid secp256k1 ECDSA signatures over `CID(tx.body)`
   - Signers match signature public keys
   - Account debits are authorized by signers
   - No withdrawal actions present
7. `B.spec.directory` matches the expected directory name
8. All transaction bodies pass `transactionFilters` and `actionFilters`
9. `|transactions| <= spec.maxNumberOfTransactionsPerBlock`
10. `sum(stateDelta(tx) for tx in transactions) <= spec.maxStateGrowth`
11. **Balance conservation (genesis)**:
    ```
    totalCredits <= premineAmount + totalFees - totalSwapLocked
    ```
12. All `GenesisAction` blocks are themselves valid genesis blocks (recursive)
13. **Frontier correctness**: Applying all actions to `homestead` (empty state) produces `frontier`:
    ```
    proveAndUpdateState(homestead, allActions) == frontier
    ```

### 5.2 Nexus Block Validation

A non-genesis nexus block `B` with previous block `P` is valid if and only if:

1. `P` is resolvable
2. `B.spec == P.spec` (chain spec continuity)
3. `B.homestead == P.frontier` (state continuity)
4. `B.index == P.index + 1`
5. `P.timestamp < B.timestamp <= now()`
6. `B.nextDifficulty < calculateMinimumDifficulty(B.difficulty, B.timestamp, P.timestamp)`
7. All transactions pass `validateTransactionForNexus()`:
   - Signatures valid (secp256k1 over `CID(tx.body)`)
   - Signers match signature public keys
   - Account debits authorized by signers
   - Swap action senders are signers
   - Settle action parties are signers
   - Swap claim authorization: refunds require sender as signer, claims require recipient as signer
   - Matched orders: signatures valid, orders compatible, not expired (`timelock > blockIndex`)
   - Claimed orders: signatures valid, orders compatible, settlement proofs exist
8. Transaction/action filters pass
9. Transaction count within limits
10. State delta within limits
11. **Balance conservation (non-genesis)**:
    ```
    totalCredits <= totalDebits + reward(B.index) + totalFees + totalSwapClaimed - totalSwapLocked + totalOrderReleased - totalOrderLocked
    ```
    Where `totalFees` is the sum of explicit transaction fees (not order fees -- see section 8.4), `totalOrderLocked` is the sum of all `OrderPostAction.lockAmount`, and `totalOrderReleased` is the sum of all `OrderReleaseAction.releaseAmount` + `OrderCancelAction.amount`.
12. All genesis actions valid
13. Frontier correctness

**Nexus validation does not validate child blocks.** The `childBlocks` field is committed to via `CID(B.childBlocks)` in the difficulty hash (section 5.4), so the miner commits to a specific set of child blocks when mining. However, child blocks are validated independently *after* the nexus block is accepted (section 5.3). An invalid child block does not affect the nexus block's validity, other child chains, or the nexus chain's state. This means a nexus-only miner only needs to compute the nexus portion of the block -- child block validation is deferred to nodes that participate in those child chains.

### 5.3 Child Chain Block Validation

Child blocks embedded in a nexus block via the `childBlocks` field are **optional**. They are processed independently after the parent nexus block is accepted onto the main chain. Invalid child blocks are silently skipped without affecting the parent block or sibling child chains.

A child chain block `B` with previous block `P` and parent chain block `Q` is valid if and only if:

1. All nexus validation rules (5.2, items 1-10, 12-13) apply, including the same balance conservation equation
2. `B.timestamp == Q.timestamp` (child block timestamp synchronized with parent)
3. Swap claim validation: non-refund claims require settlement proof in `parentHomestead.settleState`; refund claims require `blockIndex > timelock`

### 5.4 Proof-of-Work

The difficulty hash of a block is computed as:

```
difficultyHash(B) = U256(H(
    CID(B.previousBlock) ||
    CID(B.transactions) ||
    hex(B.difficulty) ||
    hex(B.nextDifficulty) ||
    CID(B.spec) ||
    CID(B.parentHomestead) ||
    CID(B.homestead) ||
    CID(B.frontier) ||
    CID(B.childBlocks) ||
    str(B.index) ||
    str(B.timestamp) ||
    str(B.nonce)
))
```

For genesis blocks, `CID(B.previousBlock)` is omitted from the hash input.

A block satisfies proof-of-work if: `difficultyHash(B) < B.difficulty`

### 5.5 Difficulty Adjustment

Given previous difficulty `D`, block timestamp `T`, and previous timestamp `T'`:

```
actualTime = T - T'
targetTime = spec.targetBlockTime

if actualTime < targetTime:
    factor = min(maxDifficultyChange, targetTime / actualTime)
    newMinDifficulty = D / factor
elif actualTime > targetTime:
    factor = min(maxDifficultyChange, actualTime / targetTime)
    newMinDifficulty = D * factor
else:
    newMinDifficulty = D
```

Validity requires: `B.nextDifficulty < newMinDifficulty`

## 6. State Transitions

### 6.1 State Update Procedure

Given a block's `homestead` state and all actions from its transactions:

```
frontier = proveAndUpdateState(homestead, actions)
```

This operation:
1. Partitions actions by type into 8 groups
2. For each sub-state, concurrently:
   a. Generates Sparse Merkle proofs that current values match `homestead`
   b. Applies mutations (inserts, updates, deletions)
   c. Returns new Merkle root
3. Assembles the 8 new roots into a new `LatticeState`

### 6.2 Account State Transitions

For each `AccountAction(owner, oldBalance, newBalance)`:
- **Proof**: Verify `homestead.accountState[owner] == oldBalance`
- **Update**:
  - If `newBalance > 0`: set `accountState[owner] = newBalance`
  - If `newBalance == 0`: delete `accountState[owner]`

### 6.3 General State Transitions

For each `Action(key, oldValue, newValue)`:
- **Proof**: Verify `homestead.generalState[key] == oldValue`
- **Update**:
  - If `newValue != nil`: set `generalState[key] = newValue`
  - If `newValue == nil`: delete `generalState[key]`

### 6.4 Swap State Transitions

See section 8.6 for full details. Swap locks use insertion proofs; swap claims use mutation proofs (existence + deletion).

### 6.5 Settle State Transitions

See section 8.7 for full details. Settlement entries use insertion proofs (two entries per settle action).

### 6.6 Genesis State Transitions

For each `GenesisAction`:
- **Key**: `action.directory`
- **Proof**: Verify key does not exist in `homestead.genesisState` (insertion proof)
- **Update**: `genesisState[directory] = CID(action.block)`

### 6.8 Peer State Transitions

For each `PeerAction`:
- **Key**: `action.owner`
- Depending on `action.type`:
  - `insert`: Prove non-existence, then insert
  - `update`: Prove existence (mutation proof), then update
  - `delete`: Prove existence (mutation proof), then delete

### 6.9 Transaction State Transitions

For each `TransactionBody` with nonce `n`:
- **Key**: `n`
- **Proof**: Verify key does not exist (insertion proof)
- **Update**: `transactionState[n] = CID(transactionBody)`

### 6.10 Order Lock State Transitions

For each `OrderPostAction`:
- **Key**: `OrderLockKey(maker, nonce)` = `maker/nonce`
- **Proof**: Verify key does NOT exist (insertion proof -- prevents duplicate posts)
- **Update**: `orderLockState[key] = lockAmount`

For each `OrderReleaseAction`:
- **Key**: `OrderLockKey(maker, nonce)`
- **Proof**: Verify key EXISTS (mutation proof)
- **Update**:
  - `remaining = current - releaseAmount`
  - If `remaining > 0`: `orderLockState[key] = remaining`
  - If `remaining == 0`: delete `orderLockState[key]`
  - If `current < releaseAmount`: reject (insufficient locked balance)

For each `OrderCancelAction`:
- **Key**: `OrderLockKey(maker, nonce)`
- **Proof**: Verify key EXISTS (deletion proof)
- **Validation**: `orderLockState[key] == amount` (declared amount must match stored value)
- **Update**: delete `orderLockState[key]`

Multiple releases against the same order lock are aggregated (e.g., partial fills across multiple `orderFills` entries). Posts and releases/cancels for the same key in the same block are rejected as conflicting.

### 6.11 State Delta Accounting

Each action type reports a state delta in bytes:

| Action Type | Delta |
|---|---|
| `AccountAction` (create) | `+len(owner) + 8` |
| `AccountAction` (delete) | `-(len(owner) + 8)` |
| `AccountAction` (update) | `0` |
| `Action` (insert) | `+len(key) + len(newValue)` |
| `Action` (delete) | `-(len(key) + len(oldValue))` |
| `Action` (update) | `len(newValue) - len(oldValue)` |
| `SwapAction` | `+len(SwapKey) + 8` |
| `SwapClaimAction` | `-(len(SwapKey) + 8)` |
| `SettleAction` | `+2 * (len(SettleKey) + 8)` |
| `GenesisAction` | `+genesisSize(block) + len(directory)` |
| `PeerAction` | `+len(owner) + len(IpAddress) + 13` |
| `OrderPostAction` | `+len(OrderLockKey) + 8` |
| `OrderCancelAction` | `-(len(OrderLockKey) + 8)` |
| `OrderReleaseAction` (partial) | `0` |
| `OrderReleaseAction` (full) | `-(len(OrderLockKey) + 8)` |

Total delta per block must not exceed `spec.maxStateGrowth`.

## 7. Transaction Validation

### 7.1 Signature Verification

For each `(publicKeyHex, signatureHex)` in `tx.signatures`:

```
valid = P256_ECDSA_Verify(
    message:   CID(tx.body),
    signature: signatureHex,
    publicKey: publicKeyHex
)
```

All signatures must verify. All signers listed in `tx.body.signers` must have corresponding valid signatures.

### 7.2 Authorization

For each `AccountAction` where `newBalance < oldBalance` (debit):
- `action.owner` MUST be in `tx.body.signers`

Credits (`newBalance > oldBalance`) do not require signer authorization.

### 7.3 JavaScript Filters

Transaction filters evaluate a JavaScript function `transactionFilter(json)` on the JSON-serialized `TransactionBody`. Action filters evaluate `actionFilter(json)` on each JSON-serialized `Action`. Both must return `true` for the transaction to be valid.

### 7.4 Context-Specific Rules

| Context | Swaps | Settles | Swap Claims | Matched Orders | Claimed Orders | Post Orders | Cancel Orders | Order Fills |
|---|---|---|---|---|---|---|---|---|
| Genesis | No | No | No | No | No | No | No | No |
| Nexus | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Child chain | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |

## 8. Cross-Chain Exchange Protocol

The exchange protocol enables trustless cross-chain atomic swaps between any two chains in the lattice hierarchy. Makers sign orders off-chain; matchers (typically miners) include matched orders in blocks; consensus enforces correctness.

Settlement is recorded on the **lowest common ancestor (LCA)** of the two source chains, not always the nexus. The transaction's `chainPath` determines which chain processes it and where settlement is recorded. Claim verification checks both the chain's own `settleState` and `parentHomestead.settleState`, so claims succeed regardless of whether settlement was placed on the current chain or its parent.

### 8.1 Protocol Phases

A cross-chain swap proceeds in three phases across multiple chains:

**Phase 1 -- Lock (on each maker's source chain):**
A `MatchedOrder` in a transaction derives `SwapAction`s that lock tokens in swap state. Both makers' accounts are debited `fillAmount + fee` on their respective source chains. The fee is locked alongside the fill amount so it can be refunded on timeout.

**Phase 2 -- Settle (on the nexus chain):**
The same `MatchedOrder` derives a `SettleAction` recorded on the nexus chain's settle state. This serves as a cross-chain coordination point -- child chains can later prove settlement occurred by checking `parentHomestead.settleState`.

**Phase 3 -- Claim (on each maker's source chain):**
A `MatchedOrder` in `claimedOrders` derives `SwapClaimAction`s. Each counterparty claims the other maker's locked tokens. Claim validation requires a settlement proof: the `SettleKey` must exist in the chain's `settleState` (nexus) or `parentHomestead.settleState` (child chain).

### 8.2 Derived Actions

Matched orders automatically derive several action types. Consensus validates the signed orders and then applies these derived actions as if they were explicitly included in the transaction.

For a `MatchedOrder(orderA, orderB, nonce, fillAmountA, fillAmountB)`:

**Lock phase** (from `matchedOrders`):

| Derived Action | Chain | Description |
|---|---|---|
| `AccountAction(orderA.maker, -(fillAmountA + feeA))` | A's sourceChain | Debit maker A |
| `AccountAction(orderB.maker, -(fillAmountB + feeB))` | B's sourceChain | Debit maker B |
| `SwapAction(nonceA, makerA, makerB, fillAmountA + feeA, timelock)` | A's sourceChain | Lock A's tokens + fee |
| `SwapAction(nonceB, makerB, makerA, fillAmountB + feeB, timelock)` | B's sourceChain | Lock B's tokens + fee |
| `SettleAction(nonce, makerA, makerB, swapKeyA, dirA, swapKeyB, dirB)` | nexus | Record settlement |

**Claim phase** (from `claimedOrders`):

| Derived Action | Chain | Description |
|---|---|---|
| `AccountAction(orderB.maker, +fillAmountA)` | A's sourceChain | Credit counterparty B |
| `AccountAction(orderA.maker, +fillAmountB)` | B's sourceChain | Credit counterparty A |
| `SwapClaimAction(nonceA, makerA, makerB, fillAmountA + feeA, timelock)` | A's sourceChain | Unlock A's swap |
| `SwapClaimAction(nonceB, makerB, makerA, fillAmountB + feeB, timelock)` | B's sourceChain | Unlock B's swap |

**Proportional fee**: `feeA = floor(orderA.fee * fillAmountA / orderA.sourceAmount)`, computed via UInt128 to avoid overflow.

### 8.3 Order Matching Rules

A `MatchedOrder` is valid if and only if:

1. **Cross-chain**: `orderA.sourceChain == orderB.destChain` and vice versa
2. **No same-chain**: `orderA.sourceChain != orderA.destChain`
3. **Different makers**: `orderA.maker != orderB.maker`
4. **Matching timelocks**: `orderA.timelock == orderB.timelock`
5. **Positive timelock**: `orderA.timelock > 0`
6. **Positive fills**: `fillAmountA > 0` and `fillAmountB > 0`
7. **Fill within order**: `fillAmountA <= orderA.sourceAmount` and `fillAmountB <= orderB.sourceAmount`
8. **Int64-safe debits**: `fillAmountA + feeA <= Int64.max` and `fillAmountB + feeB <= Int64.max`
9. **A's rate satisfied**: `fillAmountB * orderA.sourceAmount >= fillAmountA * orderA.destAmount`
10. **B's rate satisfied**: `fillAmountA * orderB.sourceAmount >= fillAmountB * orderB.destAmount`
11. **Order not expired**: `orderA.timelock > blockIndex` and `orderB.timelock > blockIndex`
12. **Uniform clearing price**: All matches in the same directed pair within a block must execute at the same rate (verified via cross-multiplication)
13. **Cumulative fill limit**: Total fills per order (by order hash) within a block must not exceed the order's `sourceAmount`
14. **Signature validity**: Both `SignedOrder`s have valid secp256k1 signatures and `makerAddress == order.maker`

### 8.4 Refundable Fee Model

Order fees are **fully refundable** on swap timeout. This is achieved by locking the fee alongside the fill amount in swap state:

```
swapLockAmount = fillAmount + proportionalFee
```

**Lock phase**: No order fee is collected. The fee is escrowed in swap state. `derivedOrderFees(lockPhase) = 0`.

**Claim phase**: The full fee is available from the excess in `swapClaimed` over the counterparty credit. The miner includes `derivedOrderFees` in the coinbase. `derivedOrderFees(claimPhase) = sum(proportionalFees)`.

**Refund (timeout)**: The sender reclaims the full `swapLockAmount` (fill + fee). The maker loses nothing.

This means order fees do NOT appear in the `totalFees` term of the balance equation. Instead, they flow through the `swapClaimed` term:

```
swapClaimed (fill + fee) = counterpartyCredit (fill) + minerFee (fee)
```

### 8.5 Order Expiry

Orders include a `timelock` field. At consensus, matched orders are rejected if `timelock <= blockIndex`. This prevents stale orders from being filled long after the maker intended them to expire.

Claimed orders are NOT subject to the expiry check -- once tokens are locked, the claim is valid regardless of the original timelock. (The timelock governs refund eligibility, not claim eligibility.)

### 8.6 Swap State Transitions

For each `SwapAction`:
- **Key**: `SwapKey(action)` = `sender/recipient/amount/timelock/nonce`
- **Proof**: Verify key does NOT exist in `swapState` (insertion proof -- prevents duplicate locks)
- **Update**: `swapState[key] = action.amount`

For each `SwapClaimAction`:
- **Key**: `SwapKey(action)` (same key format as the corresponding swap)
- **Proof**: Verify key EXISTS in `swapState` (mutation proof -- proves lock exists)
- **Update**: Delete `swapState[key]`

### 8.7 Settle State Transitions

Settlement is recorded on the LCA chain (the chain where the matched order transaction lives). Settle actions are applied to that chain's `settleState`.

For each `SettleAction`:
- **Key A**: `SettleKey(directoryA, swapKeyA)`
- **Key B**: `SettleKey(directoryB, swapKeyB)`
- **Proof**: Verify both keys do NOT exist (insertion proofs)
- **Update**: `settleState[keyA] = nonce`, `settleState[keyB] = nonce`

**Claim verification**: Non-refund swap claims check for settlement existence in both the chain's own `settleState` (for LCA settlements on the current chain) and `parentHomestead.settleState` (for settlements on the parent chain). The first successful proof satisfies the requirement.

### 8.8 Balance Conservation with Swaps and Order Locks

For any block at index `i`:

```
totalCredits <= totalDebits + reward(i) + totalFees + totalSwapClaimed - totalSwapLocked + totalOrderReleased - totalOrderLocked
```

Where:
- `totalCredits` = sum of all positive account action deltas (including derived from orders)
- `totalDebits` = sum of all negative account action deltas (absolute values)
- `totalFees` = sum of explicit transaction `body.fee` values (NOT order fees)
- `totalSwapLocked` = sum of all `SwapAction.amount` values (fill + fee)
- `totalSwapClaimed` = sum of all `SwapClaimAction.amount` values (fill + fee)
- `totalOrderLocked` = sum of all `OrderPostAction.lockAmount` values
- `totalOrderReleased` = sum of all `OrderReleaseAction.releaseAmount` + `OrderCancelAction.amount` values

### 8.9 Refund Flow

After timelock expiry (`blockIndex > timelock`), the original sender can submit a `SwapClaimAction` with `isRefund = true`. This deletes the swap state entry and credits the full locked amount (fill + fee) back to the sender's account via an explicit `AccountAction`.

### 8.10 Security Properties

**No value creation**: The balance equation guarantees that tokens entering accounts (`totalCredits`) cannot exceed tokens leaving accounts (`totalDebits`) plus block reward plus the net swap flow. Order fees are zero-sum within the `swapClaimed` term.

**No double-fill**: Cumulative fills per order are tracked by `doubleSha256(JSON(order))` within each block. Cross-block double-fills are prevented by `SwapKey` uniqueness in swap state (insertion proofs).

**No stale execution**: Order expiry (`timelock > blockIndex`) prevents matching orders whose maker no longer intends to trade.

**Refund safety**: Refunds require `blockIndex > timelock`, so a swap cannot be both claimed and refunded -- the claim window (before expiry) and refund window (after expiry) are disjoint, mediated by the settlement proof requirement for claims.

**Cross-chain atomicity**: Settlement on the nexus provides coordination. If party A's tokens are locked on chain X and party B's tokens are locked on chain Y, both claims require the same settlement proof. Either both claims succeed (after settlement) or both parties eventually refund (after timeout).

## 8b. Persistent On-Chain Order Book

In addition to the instant matching protocol (section 8), Lattice supports a persistent on-chain order book where funds are locked at post time. This enables orders to persist across blocks and be filled later, unlike `matchedOrders` which require both sides to be matched in the same transaction.

### 8b.1 Overview

The order lifecycle has three phases:

1. **Post** -- A maker submits a `SignedOrder` in `postOrders`. The maker's account is debited `sourceAmount + fee` and the locked amount is recorded in `orderLockState`.
2. **Fill** -- A matcher includes a `MatchedOrder` in `orderFills` referencing two previously posted orders. The locked amounts are released from `orderLockState` and converted into swap locks (same as the instant matching protocol).
3. **Cancel** -- The maker signs an `OrderCancellation` included in `cancelOrders`. The locked amount is returned to the maker's account after verifying the declared amount matches state.

### 8b.2 Post Phase

A `SignedOrder` in `postOrders` triggers:

```
// Account debit
AccountAction(owner: maker, delta: -(sourceAmount + fee))

// Order lock insertion
orderLockState[maker/nonce] = sourceAmount + fee
```

**Validation:**
- Signature verifies: `verify(signature, doubleSha256(JSON(order)), publicKey)` and `CID(publicKey) == maker`
- Maker is a signer of the transaction
- `sourceAmount > 0` and `destAmount > 0`
- `timelock > 0`
- `sourceChain != destChain` (no same-chain orders)
- `sourceAmount + fee` fits in Int64 (safe for account delta)

**Proof:** Insertion proof -- `OrderLockKey` must NOT exist in `orderLockState`.

**Balance effect:** `totalDebits` increases by `sourceAmount + fee`; `totalOrderLocked` increases by `sourceAmount + fee`. Net: 0.

### 8b.3 Fill Phase

A `MatchedOrder` in `orderFills` triggers the same derived actions as `matchedOrders` (swap locks, settle actions, account debits), plus:

```
// Release order lock for maker A
OrderReleaseAction(maker: orderA.maker, nonce: orderA.nonce, releaseAmount: fillAmountA + feeA)

// Release order lock for maker B
OrderReleaseAction(maker: orderB.maker, nonce: orderB.nonce, releaseAmount: fillAmountB + feeB)
```

The release reduces the locked amount in `orderLockState`. If the remaining amount reaches 0, the entry is deleted (full fill). Otherwise it is updated (partial fill).

Fills follow the same matching rules as `matchedOrders` (section 8.3), including order expiry, uniform clearing price, and cumulative fill limits.

**Key difference from instant matches:** The account debit already happened at post time, not at fill time. The fill converts locked funds (order lock) into swap-locked funds (swap state), so the fill itself produces no net account movement -- it releases from `orderLockState` and locks into `swapState`.

**Balance effect:** `totalOrderReleased` increases by `fillAmount + fee`; `totalSwapLocked` increases by `fillAmount + fee`. Account debits from swap actions are offset by the order release. Net: 0.

### 8b.4 Cancel Phase

An `OrderCancellation` in `cancelOrders` triggers:

```
// Credit maker the remaining locked amount
AccountAction(owner: maker, delta: +amount)

// Delete order lock
orderLockState.delete(maker/orderNonce)
```

**Validation:**
- Cancellation signature verifies: `verify(doubleSha256("cancel:" || orderNonce), signature, publicKey)` and `CID(publicKey) == maker`
- Maker is a signer of the transaction
- Declared `amount` exactly equals the value stored in `orderLockState[maker/orderNonce]`

**Proof:** Deletion proof -- `OrderLockKey` must exist in `orderLockState`, and the stored value must equal `amount`.

**Balance effect:** `totalCredits` increases by `amount`; `totalOrderReleased` increases by `amount`. Net: 0.

### 8b.5 Conflict Rules

Within a single block, the following combinations for the same `OrderLockKey` are rejected:
- Post + Release (cannot post and fill in the same block)
- Post + Cancel (cannot post and cancel in the same block)
- Release + Cancel (cannot partially fill and cancel in the same block)
- Multiple Posts (cannot post the same order twice)
- Multiple Cancels (cannot cancel the same order twice)

Multiple Releases for the same key are allowed (multiple partial fills in one block) and are aggregated by summing `releaseAmount` values.

### 8b.6 Signer-less Fill Transactions

Fill transactions (`orderFills`) may have empty `signatures` and `signers` -- the signed orders themselves provide authorization. This enables miners to fill orders without being a party to the trade. However, signer-less transactions must have `fee == 0` to prevent supply inflation (fees inflate the balance equation's available pool, and without a signer debit to back the fee, a miner could create tokens).

### 8b.7 Security Properties

**No cancel inflation**: The `amount` field in `OrderCancellation` must exactly match the stored value in `orderLockState`. If a canceller declares an inflated amount, the state proof rejects the transaction. This prevents crediting more than was locked.

**Order lock uniqueness**: Each `OrderLockKey` can only be inserted once (insertion proof). Combined with the order nonce, this prevents duplicate posts for the same order.

**Post-fill atomicity**: When a fill releases from `orderLockState` and locks into `swapState`, both state transitions are proven in the same block. The fill cannot release without also locking -- the balance equation would not balance.

## 9. Consensus

### 9.1 Fork Choice Rule

Given two competing chain tips with work metrics `(highestIndex_L, parentIndex_L)` and `(highestIndex_R, parentIndex_R)`:

```
function rightIsBetter(left, right):
    if right.parentIndex != nil:
        if left.parentIndex != nil:
            return right.parentIndex < left.parentIndex
        return true  // anchored beats unanchored
    if left.parentIndex == nil:
        return right.highestIndex > left.highestIndex  // longer chain
    return false  // unanchored cannot beat anchored
```

**Priority order:**
1. Parent chain anchoring (anchored > unanchored)
2. Earlier parent anchor index (lower > higher)
3. Chain length (longer > shorter)
4. First-seen (incumbent holds on tie)

### 9.2 Chain State

Each chain maintains:

```
ChainState = actor {
    chainTip:                       string,         // hash of best known block
    mainChainHashes:                Set<string>,     // all hashes on main chain
    indexToBlockHash:               Map<uint64, Set<string>>,
    hashToBlock:                    Map<string, BlockMeta>,
    parentChainBlockHashToBlockHash: Map<string, string>
}
```

### 9.3 Nexus Block Processing

When a new nexus block arrives, processing happens in two phases:

**Phase 1: Nexus validation and submission** (required)

1. Validate the block via `validateNexus()` (section 5.2) -- child blocks are NOT validated here
2. Verify proof-of-work: `difficultyHash(B) < B.difficulty`
3. Submit to `ChainState`:
   a. If `block.index + RECENT_BLOCK_DISTANCE < highestBlockIndex`, discard (too old)
   b. If block hash already known, handle as duplicate (may add parent chain reference)
   c. Insert into `hashToBlock` and `indexToBlockHash`
   d. If previous block is current chain tip, extend main chain
   e. If previous block is unknown and block is recent, request the missing parent
   f. Otherwise, evaluate fork choice via `checkForReorg()`

**Phase 2: Child block extraction** (deferred, independent)

Only after the nexus block is accepted onto the main chain:

4. Extract child blocks from `B.childBlocks` Merkle dictionary
5. For each child block, validate independently against its child chain's rules (section 5.3)
6. Invalid child blocks are silently skipped -- they do not affect the nexus block or other children
7. Newly discovered child chains (genesis blocks) are registered in the chain hierarchy

This two-phase design means nexus miners only need to perform nexus-level validation and mining. Child block validation is entirely the responsibility of nodes that participate in those child chains.

### 9.4 Reorganization

When a fork beats the current main chain:

1. Find the earliest orphan block connected to the main chain (the fork point)
2. Compute `mainChainWork` from the fork point using current main chain
3. Compute `forkWork` from the fork point through the new fork
4. If `rightIsBetter(mainChainWork, forkWork)`:
   a. Update `chainTip` to the new fork's tip
   b. Remove old main chain blocks from `mainChainHashes` (above fork point)
   c. Add new fork blocks to `mainChainHashes`
   d. Return `Reorganization` describing added/removed blocks
   e. Propagate to child chains

### 9.5 Parent Chain Anchoring

When a child chain block is included in a parent chain block at index `P_i`:
- Record `parentChainBlockHashToBlockHash[P_hash] = C_hash`
- Record `hashToBlock[C_hash].parentChainBlocks[P_hash] = P_i`

The `parentIndex` of a `BlockMeta` is the minimum of all known parent chain indices:
```
parentIndex = min(parentChainBlocks.values.compactMap { $0 })
```

### 9.6 Parent Reorg Propagation

When the parent chain reorganizes:

1. For each removed parent block hash: clear the corresponding anchoring reference in the child chain's block
2. For each added parent block hash: update the anchoring reference with the new parent index
3. Find affected child chain blocks that are not on the main chain
4. For each, evaluate fork choice -- the changed anchoring may trigger a child chain reorg

### 9.7 Block Pruning

When the chain tip advances, blocks at index `< (tipIndex - RECENT_BLOCK_DISTANCE)` are pruned from memory. `RECENT_BLOCK_DISTANCE = 1000`.

### 9.8 Weight Computation

Block weights for fork comparison are encoded as a 2-element array:

```
weights(block) =
    if block.parentIndex != nil:
        [UInt64.max - block.parentIndex, block.blockIndex]
    else:
        [0, block.blockIndex]
```

This enables lexicographic comparison where parent-anchored blocks always sort higher than unanchored blocks (due to the `UInt64.max - parentIndex` term being very large).

## 10. Economic Model

### 10.1 Reward Schedule

```
rewardAtBlock(index) = initialReward >> ((index + premine) / halvingInterval)
```

Where:
- `initialReward = 2^initialRewardExponent`
- `halvingInterval = 2^(64 - initialRewardExponent)`
- `premine` offsets the halving clock

The reward halves every `halvingInterval` blocks. After `initialRewardExponent` halvings, the reward reaches 0.

### 10.2 Premine

The premine represents blocks conceptually "mined" by chain creators before public mining begins. The premine amount is:

```
premineAmount = premine * initialReward
```

Public mining starts at block index 0, but the halving schedule treats it as block `premine`. This means the first public halving occurs at block `halvingInterval - premine`.

### 10.3 Total Supply

```
totalRewards(n) = sum(rewardAtBlock(i) for i in 0..<n)
```

Computed efficiently via geometric series in O(log n) time by iterating through halving periods.

### 10.4 ChainSpec Validity

A `ChainSpec` is valid if:

```
maxNumberOfTransactionsPerBlock > 0
maxStateGrowth > 0
targetBlockTime > 0
0 < initialRewardExponent < 64
premine < halvingInterval
```

## 11. Cryptographic Primitives

| Primitive | Algorithm | Usage |
|---|---|---|
| Hash | SHA-256 | Block hashes, Merkle trees, addresses, difficulty |
| Signature | secp256k1 ECDSA | Transaction and order authorization |
| Content addressing | CID (DAG-CBOR + SHA-256) | All data structure references |
| Sparse proofs | Sparse Merkle Tree | State inclusion/exclusion proofs |

### 11.1 Address Derivation

```
address(publicKey) = "1" || sha256(ripemd160(publicKey))[:32]
```

Note: In the current implementation, `ripemd160` delegates to `sha256`.

## 12. Invariants

The following invariants MUST hold at all times:

### 12.1 State Continuity

For any consecutive blocks `B[i]` and `B[i+1]` on the same chain:

```
B[i].frontier == B[i+1].homestead
```

### 12.2 Balance Conservation

For any valid block:

```
totalCredits <= totalDebits + reward + totalFees + totalSwapClaimed - totalSwapLocked + totalOrderReleased - totalOrderLocked
```

No tokens are created or destroyed by swaps or order locks. Lock-phase debits are exactly offset by swap/order state growth; claim-phase swap state reduction is exactly offset by counterparty credits plus miner fees; order releases are exactly offset by swap locks or cancel credits.

### 12.3 Consensus Invariants

1. The chain tip is always on the main chain
2. The chain tip block always exists in the block map
3. The genesis block is always on the main chain (never removed by reorg)
4. Main chain blocks form a connected path from genesis to tip
5. `mainChainBlocksAdded` and `mainChainBlocksRemoved` in a `Reorganization` are disjoint sets

### 12.4 Exchange Invariants

1. Each `SwapKey` is unique in swap state (insertion proof prevents duplicate locks)
2. A swap claim requires the corresponding `SwapKey` to exist (mutation proof)
3. A non-refund claim requires a settlement proof in settle state
4. A refund claim requires `blockIndex > timelock` (swap has expired)
5. Settlement entries are never deleted -- they persist as permanent coordination proofs
6. Cumulative fills per order within a block cannot exceed the order's `sourceAmount`
7. Matched orders must not be expired (`timelock > blockIndex`)
8. Order fees are fully refundable: `swapLockAmount = fillAmount + proportionalFee`
9. Each `OrderLockKey` is unique in order lock state (insertion proof prevents duplicate posts)
10. Order cancel amount must exactly match stored lock value (prevents cancel inflation)
11. Order post and release/cancel for the same key in the same block are rejected (conflict rule)

### 12.5 Fork Choice Invariants

1. `compareWork` is irreflexive: no fork is better than itself
2. `compareWork` is asymmetric: if A beats B, B does not beat A
3. Parent chain anchoring strictly dominates chain length
4. Among equally anchored forks, lower parent index wins
5. Among unanchored forks, strictly longer chain wins

## 13. Constants

| Constant | Value | Description |
|---|---|---|
| `RECENT_BLOCK_DISTANCE` | 1000 | Blocks older than this are pruned from memory |
| `maxDifficultyChange` | 2 | Maximum difficulty adjustment factor per block |
| `totalExponent` | 64 | Bit width of the reward/halving system |
