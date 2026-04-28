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
    depositActions:     [DepositAction],
    genesisActions:     [GenesisAction],
    receiptActions:     [ReceiptAction],
    withdrawalActions:  [WithdrawalAction],
    signers:            [CID(PublicKey)],
    fee:                uint64,
    nonce:              uint64,
    chainPath:          [string]
)
```

### 3.4 LatticeState

The world state is a 5-tuple of Sparse Merkle Tree roots:

```
LatticeState = (
    accountState:      SMT<CID(PublicKey) -> uint64>,
    generalState:      SMT<string -> string>,
    depositState:      SMT<DepositKey -> uint64>,
    genesisState:      SMT<string -> CID(Block)>,
    receiptState:      SMT<ReceiptKey -> CID(PublicKey)>
)
```

### 3.5 ChainSpec

```
ChainSpec = (
    directory:                      string,
    maxNumberOfTransactionsPerBlock: uint64,
    maxStateGrowth:                 int,
    maxBlockSize:                   int,
    premine:                        uint64,
    targetBlockTime:                uint64,     // milliseconds
    initialReward:                  uint64,
    halvingInterval:                uint64,
    difficultyAdjustmentWindow:     uint64,
    transactionFilters:             [string],   // JavaScript expressions
    actionFilters:                  [string]    // JavaScript expressions
)
```

**Protocol constants:**

```
maxDifficultyChange = 2
```

### 3.6 Action Types

#### AccountAction

```
AccountAction = (owner: CID(PublicKey), delta: int64)
```

**Validity:** `delta != 0` and `delta != Int64.min`

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

### 3.7 Keys

#### DepositKey

```
DepositKey = demander || "/" || amountDemanded || "/" || nonce
```

Used to index `depositState`. Uniquely identifies a pending cross-chain deposit by the demander's address, the amount demanded on the parent chain, and a nonce.

#### ReceiptKey

```
ReceiptKey = directory || "/" || demander || "/" || amountDemanded || "/" || nonce
```

Used to index `receiptState`. Associates a receipt on the parent chain with the child chain directory where the deposit originated.

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
    totalCredits <= premineAmount + totalFees - totalDeposited
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
   - Receipt action withdrawers are signers
8. Transaction/action filters pass
9. Transaction count within limits
10. State delta within limits
11. **Balance conservation (non-genesis)**:
    ```
    totalCredits <= totalDebits + reward(B.index) + totalFees + totalWithdrawn - totalDeposited
    ```
12. All genesis actions valid
13. Frontier correctness

**Nexus validation does not validate child blocks.** The `childBlocks` field is committed to via `CID(B.childBlocks)` in the difficulty hash (section 5.4), so the miner commits to a specific set of child blocks when mining. However, child blocks are validated independently *after* the nexus block is accepted (section 5.3). An invalid child block does not affect the nexus block's validity, other child chains, or the nexus chain's state. This means a nexus-only miner only needs to compute the nexus portion of the block -- child block validation is deferred to nodes that participate in those child chains.

### 5.3 Child Chain Block Validation

Child blocks embedded in a nexus block via the `childBlocks` field are **optional**. They are processed independently after the parent nexus block is accepted onto the main chain. Invalid child blocks are silently skipped without affecting the parent block or sibling child chains.

A child chain block `B` with previous block `P` and parent chain block `Q` is valid if and only if:

1. All nexus validation rules (5.2, items 1-10, 12-13) apply, including the same balance conservation equation
2. `B.timestamp == Q.timestamp` (child block timestamp synchronized with parent)
3. `B.parentHomestead == Q.homestead` (parent state commitment matches actual parent state)
4. Withdrawal validation: each withdrawal requires proof of corresponding deposit in `homestead.depositState` AND proof of receipt in `parentHomestead.receiptState`

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
1. Partitions actions by type into 5 groups (one per sub-state)
2. For each sub-state, concurrently:
   a. Generates Sparse Merkle proofs that current values match `homestead`
   b. Applies mutations (inserts, updates, deletions)
   c. Returns new Merkle root
3. Assembles the 5 new roots into a new `LatticeState`

### 6.2 Account State Transitions

For each `AccountAction(owner, delta)`:
- **Proof**: Verify `homestead.accountState[owner]` exists (or does not, for new accounts)
- **Update**: Apply `delta` to balance. Positive delta = credit, negative = debit.
  - If resulting balance > 0: set `accountState[owner] = newBalance`
  - If resulting balance == 0: delete `accountState[owner]`

Per-signer nonces are tracked in the same trie via `_nonce_<signerPrefix>` keys.

### 6.3 General State Transitions

For each `Action(key, oldValue, newValue)`:
- **Proof**: Verify `homestead.generalState[key] == oldValue`
- **Update**:
  - If `newValue != nil`: set `generalState[key] = newValue`
  - If `newValue == nil`: delete `generalState[key]`

### 6.4 Deposit State Transitions

For each `DepositAction`:
- **Key**: `DepositKey(demander, amountDemanded, nonce)`
- **Proof**: Verify key does NOT exist in `homestead.depositState` (insertion proof -- prevents duplicate deposits)
- **Validation**: `amountDeposited > 0` and `amountDemanded > 0`
- **Update**: `depositState[key] = amountDeposited`

For each `WithdrawalAction` (deposits are deleted when withdrawn):
- **Key**: `DepositKey(demander, amountDemanded, nonce)`
- **Proof**: Verify key EXISTS in `depositState` (deletion proof)
- **Validation**: Stored `amountDeposited` must equal `amountWithdrawn`
- **Update**: Delete `depositState[key]`

Withdrawals are processed before new deposits within the same block to avoid key conflicts.

### 6.5 Receipt State Transitions

For each `ReceiptAction`:
- **Key**: `ReceiptKey(directory, demander, amountDemanded, nonce)`
- **Proof**: Verify key does NOT exist in `homestead.receiptState` (insertion proof -- prevents duplicate receipts)
- **Update**: `receiptState[key] = CID(withdrawer's PublicKey)`

Receipt actions also derive account actions: the `withdrawer` is debited `amountDemanded` and the `demander` is credited `amountDemanded`.

### 6.6 Genesis State Transitions

For each `GenesisAction`:
- **Key**: `action.directory`
- **Proof**: Verify key does not exist in `homestead.genesisState` (insertion proof)
- **Update**: `genesisState[directory] = CID(action.block)`

### 6.8 State Delta Accounting

Each action type reports a state delta in bytes:

| Action Type | Delta |
|---|---|
| `AccountAction` (update) | `0` |
| `Action` (insert) | `+len(key) + len(newValue)` |
| `Action` (delete) | `-(len(key) + len(oldValue))` |
| `Action` (update) | `len(newValue) - len(oldValue)` |
| `DepositAction` | `+32 + len(demander)` |
| `WithdrawalAction` | `+len(withdrawer) + len(demander) + 32` |
| `ReceiptAction` | `+len(withdrawer) + len(demander) + len(directory) + 24` |
| `GenesisAction` | `+genesisSize(block) + len(directory)` |

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

For each `AccountAction` where `delta < 0` (debit):
- `action.owner` MUST be in `tx.body.signers`

Credits (`delta > 0`) do not require signer authorization.

### 7.5 Deposit/Receipt/Withdrawal Authorization

- **DepositAction**: `demander` MUST be in `tx.body.signers`
- **ReceiptAction**: `withdrawer` MUST be in `tx.body.signers`
- **WithdrawalAction**: `withdrawer` MUST be in `tx.body.signers`; requires proof of corresponding deposit in `homestead.depositState` AND proof of receipt in `parentHomestead.receiptState`

### 7.3 JavaScript Filters

Transaction filters evaluate a JavaScript function `transactionFilter(json)` on the JSON-serialized `TransactionBody`. Action filters evaluate `actionFilter(json)` on each JSON-serialized `Action`. Both must return `true` for the transaction to be valid.

### 7.4 Context-Specific Rules

| Context | Deposits | Receipts | Withdrawals |
|---|---|---|---|
| Genesis | Yes | No | No |
| Nexus | No | Yes (from child chains) | No |
| Child chain | Yes | No | Yes (requires parent receipt proof) |

## 8. Cross-Chain Transfer Protocol

The cross-chain transfer protocol enables trustless value movement between parent and child chains in the hierarchy. All verification is performed via Sparse Merkle proofs against state roots committed in blocks. No bridges, federations, or relayers are required.

### 8.1 Protocol Phases

A cross-chain transfer proceeds in three phases across a parent-child chain pair:

**Phase 1 -- Deposit (child chain):**
A user includes a `DepositAction` in a transaction on the child chain. This locks `amountDeposited` tokens and records a demand: `demander` should receive `amountDemanded` tokens on the parent chain. The deposit is stored in the child's `depositState` via an insertion proof.

**Phase 2 -- Receipt (parent chain):**
The parent chain verifies the deposit exists by checking the child's state root (committed in the child block embedded in the parent block). A `ReceiptAction` records the receipt in the parent's `receiptState` and derives two account actions: debiting `amountDemanded` from the `withdrawer` and crediting `amountDemanded` to the `demander`.

**Phase 3 -- Withdrawal (child chain):**
The child chain verifies a receipt exists on the parent by checking `parentHomestead.receiptState`. A `WithdrawalAction` deletes the deposit entry from `depositState` (deletion proof, preventing double-withdrawal) and releases `amountWithdrawn` back to the `withdrawer`. The stored `amountDeposited` must exactly match `amountWithdrawn`.

### 8.2 Balance Conservation with Cross-Chain Transfers

For any block at index `i`:

```
totalCredits <= totalDebits + reward(i) + totalFees + totalWithdrawn - totalDeposited
```

Where:
- `totalCredits` = sum of all positive account action deltas
- `totalDebits` = sum of all negative account action deltas (absolute values)
- `totalFees` = sum of explicit transaction `body.fee` values
- `totalDeposited` = sum of all `DepositAction.amountDeposited` values
- `totalWithdrawn` = sum of all `WithdrawalAction.amountWithdrawn` values

Deposits reduce the available balance (tokens locked in deposit state). Withdrawals increase it (tokens released from deposit state).

### 8.3 Security Properties

**No value creation**: The balance equation guarantees that credits cannot exceed debits plus block reward plus net withdrawal flow.

**No double-deposit**: Deposit keys are unique in deposit state (insertion proof prevents duplicate deposits with the same nonce/demander/amount).

**No double-withdrawal**: Withdrawals delete the deposit entry (deletion proof). Once withdrawn, the deposit key no longer exists, so a second withdrawal fails the proof.

**No over-withdrawal**: The stored `amountDeposited` must exactly match the declared `amountWithdrawn`. If a withdrawer claims more than was deposited, the state proof rejects the transaction.

**No forged receipts**: Receipt verification uses `parentHomestead.receiptState`, which is committed in the child block's proof-of-work hash. An attacker cannot fabricate a receipt without controlling the parent chain's hashrate.

**Cross-chain replay protection**: Each transaction declares a `chainPath` targeting the exact chain hierarchy path. Transactions are rejected if the `chainPath` doesn't match the validating chain.

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

The reward halves every `halvingInterval` blocks. After all halvings complete, the reward reaches 0.

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
maxBlockSize > 0
targetBlockTime > 0
initialReward > 0
halvingInterval > 0
difficultyAdjustmentWindow > 0
premine < halvingInterval
```

## 11. Cryptographic Primitives

| Primitive | Algorithm | Usage |
|---|---|---|
| Hash | SHA-256 | Block hashes, Merkle trees, addresses, difficulty |
| Signature | secp256k1 ECDSA | Transaction authorization |
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
totalCredits <= totalDebits + reward + totalFees + totalWithdrawn - totalDeposited
```

No tokens are created or destroyed by cross-chain transfers. Deposits reduce available balance (tokens locked in deposit state). Withdrawals increase it (tokens released from deposit state).

### 12.3 Consensus Invariants

1. The chain tip is always on the main chain
2. The chain tip block always exists in the block map
3. The genesis block is always on the main chain (never removed by reorg)
4. Main chain blocks form a connected path from genesis to tip
5. `mainChainBlocksAdded` and `mainChainBlocksRemoved` in a `Reorganization` are disjoint sets

### 12.4 Cross-Chain Transfer Invariants

1. Each `DepositKey` is unique in deposit state (insertion proof prevents duplicate deposits)
2. Each `ReceiptKey` is unique in receipt state (insertion proof prevents duplicate receipts)
3. A withdrawal requires the corresponding deposit to exist (deletion proof)
4. A withdrawal requires the corresponding receipt to exist in `parentHomestead.receiptState` (mutation proof)
5. The stored `amountDeposited` must exactly match the declared `amountWithdrawn` (prevents over-withdrawal)
6. Deposit entries are deleted on withdrawal (prevents double-withdrawal)

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
