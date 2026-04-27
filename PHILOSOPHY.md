# Lattice: Design Philosophy and Ideas

## The Core Problem

Every multi-chain blockchain system forces the same fundamental compromise: either chains share security by competing for limited capacity on a single root chain, or chains are sovereign and must independently recruit their own set of validators. The first approach (Polkadot's parachain model) caps the number of chains and creates artificial scarcity. The second approach (Cosmos, Avalanche) fragments security — each new chain starts with minimal economic backing and must bootstrap trust from scratch.

Both approaches also require **bridges** to move value between chains. Bridges are trusted intermediaries — multisigs, federations, relayer networks — that hold custody of assets during transfer. They are the most exploited components in the blockchain ecosystem, responsible for billions in losses. The bridge problem is not incidental; it is structural. When chains have independent state, transferring value between them requires some external entity to attest that a debit on one chain corresponds to a credit on another.

Lattice asks: what if the relationship between chains were not lateral (independent chains connected by bridges) but **hierarchical** (a tree of chains where each child inherits its parent's security)? And what if cross-chain value transfer were not an external coordination problem but an **internal state transition** verifiable by the same Merkle proofs that secure each individual chain?

## The Hierarchical Insight

Lattice structures chains as a rooted tree. A single root chain — the **nexus** — can spawn child chains via genesis transactions. Each child chain can spawn its own children, forming an arbitrarily deep hierarchy.

```
      Nexus
     /     \
    A       B
   / \
  A1  A2
```

This hierarchy is not just organizational. It defines three relationships that solve the problems above:

**Security inheritance through nested merged mining.** When a miner searches for a nonce that satisfies the nexus difficulty target, that same nonce simultaneously secures every chain in the tree. A child chain's block is embedded in its parent's `childBlocks` field, which is committed to the parent's proof-of-work hash. A grandchild is embedded in its parent, which is embedded in its grandparent, all the way up to the nexus. One hash computation secures the entire hierarchy.

This is a recursive generalization of merged mining (as pioneered by Namecoin with Bitcoin, and later RSK). The key difference is that RSK's merged mining is a flat, bilateral relationship — Bitcoin secures RSK, but RSK cannot spawn its own merged-mined children. Lattice's merged mining is tree-structured, enabling unlimited depth.

**Trustless cross-chain transfers through state commitment.** Each block carries three state snapshots: `parentHomestead` (a committed snapshot of the parent chain's state), `homestead` (the chain's own confirmed state entering the block), and `frontier` (the state after applying the block's transactions). Because `parentHomestead` is committed in the child block's proof-of-work hash, a child chain can verify facts about its parent's state without querying the parent at validation time.

This three-phase state model is what makes bridgeless cross-chain transfers possible. A deposit on a child chain creates an entry in the child's deposit state. The parent chain can verify that deposit by checking the child's state root (committed in the child block embedded in the parent block). A withdrawal on the child requires proving that a corresponding receipt exists in the parent's state — which the child can verify against `parentHomestead`. No external attestation needed. The chain hierarchy itself is the bridge.

**Permissionless chain creation.** Any chain can spawn children via a `GenesisAction` in a transaction. No slot auctions, no governance votes, no staking requirements. The child chain defines its own `ChainSpec` — block time, reward schedule, transaction throughput, custom validation filters — but inherits the full proof-of-work security of its parent. This means a new chain with zero independent hashrate is immediately as secure as the nexus, from its first block.

## Content-Addressed Everything

Every data structure in Lattice — blocks, transactions, state trees, chain specs — is wrapped in content-addressed headers using IPLD/CID (Content Identifiers with DAG-CBOR serialization and SHA-256 hashing). A CID is a self-describing hash: given any piece of data, you can compute its CID deterministically, and given a CID, you can verify that any claimed data matches it.

This design choice has several consequences:

**Structural sharing.** Two blocks that reference the same transaction don't duplicate it — they reference the same CID. Two state trees that differ in one account share every other branch. This is the same principle behind Git's content-addressed object store, applied to every layer of the protocol.

**Lazy resolution.** A node doesn't need to have all data locally. It can hold CID references and resolve them on demand from any peer that stores the data. The `Fetcher` protocol abstracts this: validation code works against CIDs and calls `fetcher.fetch(rawCid:)` when it needs the underlying data. A light client can validate a block by fetching only the Sparse Merkle proofs it needs, not the entire state.

**Data locality through Volumes.** Block and transaction boundaries use `Volume` headers — a `Header` subtype that signals to the fetcher layer that the referenced subtree is a contiguity boundary. When a node fetches a block, the Volume hint tells it that the block's children (transactions, child blocks) are stored contiguously on the peer that provided the block. This enables efficient batch fetching without the fetcher needing to understand block semantics.

## The Three-Phase State Model

Each block carries three states rather than the typical two (before and after). This seemingly small addition is what enables the entire cross-chain verification system.

- **parentHomestead** — A snapshot of the parent chain's state at the time this block was mined. For nexus blocks, this is empty. For child blocks, it contains the parent's confirmed state, including the parent's deposit state, receipt state, and settle state.

- **homestead** — The chain's own confirmed state entering this block. Equals the `frontier` of the previous block (state continuity invariant). For genesis blocks, this is the empty state.

- **frontier** — The state after applying this block's transactions to `homestead`. This is what becomes the next block's `homestead`.

The critical property is that `parentHomestead` is committed in the child block's proof-of-work hash. A validator checking a child block can verify cross-chain references (deposits, receipts, withdrawals) against `parentHomestead` without querying the parent chain. The parent chain's state is baked into the child's proof-of-work commitment.

## Partitioned State

World state is split into six independent Sparse Merkle Trees:

| Sub-state | Purpose |
|---|---|
| `accountState` | Token balances and per-signer nonces |
| `generalState` | Arbitrary key-value storage |
| `depositState` | Pending cross-chain deposits |
| `receiptState` | Cross-chain transfer receipts |
| `peerState` | Network peer registry |
| `genesisState` | Child chain genesis block references |

Each sub-state is an independent Sparse Merkle Tree with its own root hash. The six roots are combined into a `LatticeState` composite. This partitioning has two benefits:

**Concurrent updates.** When processing a block's transactions, all six sub-states can be proved and updated in parallel via Swift `async let`. Account balance changes don't block peer state changes. This is a direct mapping of the data model onto Swift's structured concurrency.

**Selective verification.** A light client that only cares about account balances can request Sparse Merkle proofs against `accountState` without downloading proofs for the other five sub-states. A node tracking cross-chain deposits only needs proofs against `depositState` and `receiptState`.

## Sparse Merkle Proofs as the Universal Verification Primitive

Lattice uses Sparse Merkle Trees rather than Patricia tries (Ethereum) or UTXO commitments (Bitcoin). The choice is deliberate: Sparse Merkle Trees support both inclusion proofs (key exists with value V) and **exclusion proofs** (key does not exist) efficiently.

Exclusion proofs are essential for several protocol operations:

- **Swap lock insertion**: Proving a swap key doesn't already exist prevents double-locking.
- **Settlement insertion**: Proving a settle key doesn't exist prevents duplicate settlements.
- **Genesis action**: Proving a child chain directory doesn't exist prevents overwriting an existing chain.
- **Order post**: Proving an order lock key doesn't exist prevents duplicate order posts.

Every state transition in Lattice is proved against the current state before it is applied. The pattern is consistent across all six sub-states: generate a proof that the current value matches expectations, then apply the mutation. This means block validation is a pure function of the block data and the current state proofs — no side effects, no external queries, no consensus-layer assumptions.

## Actor-Based Consensus

The consensus layer maps directly onto Swift's actor model. Each chain in the hierarchy is a `ChainLevel` actor containing a `ChainState` actor. The `Lattice` actor owns the nexus `ChainLevel`, which owns its children, forming a tree of isolated actors.

This mapping is not incidental — it reflects a genuine structural correspondence between the protocol's concurrency model and Swift's:

- Each chain's fork tracking and reorganization logic runs in isolation within its `ChainState` actor. No locks, no shared mutable state.
- Reorganizations propagate through the actor hierarchy: when a parent chain reorgs, the reorg event is sent to each child `ChainLevel`, which evaluates whether its own fork choice changes.
- Child block validation runs concurrently via `withTaskGroup` — sibling chains are validated in parallel since they have no data dependencies.
- Swift 6's strict sendability checking catches data races at compile time, not at runtime.

The actor tree also defines the security boundary: a child chain's `ChainState` can only be modified through its parent `ChainLevel`. There is no path from one sibling chain to another that doesn't go through their common parent.

## Fork Choice: Parent Anchoring Over Chain Length

Lattice's fork choice rule extends Nakamoto consensus (longest chain wins) with a hierarchical priority:

1. **Parent-anchored beats unanchored.** If a block on a child chain has been included in a parent chain block, it is considered more authoritative than a competing block at the same height that hasn't been included.
2. **Lower parent index wins.** Among blocks anchored to the parent chain, the one anchored earlier (lower parent block index) takes priority.
3. **Higher cumulative work wins.** The classic Nakamoto tiebreaker.

This rule means that a 51% attacker on a child chain cannot simply produce a longer fork — they must also get their fork anchored on the parent chain before the honest fork. Since the parent chain has its own proof-of-work security, attacking the child requires attacking the parent's fork choice too, which requires attacking the parent's hashrate. Security propagates upward through the hierarchy.

## Cross-Chain Value Transfer Without Bridges

The deposit/receipt/withdrawal protocol enables trustless value movement between parent and child chains:

1. **Deposit** (child chain): A user creates a deposit action on the child chain, locking tokens and declaring a demand (amount and recipient on the parent). The deposit is recorded in the child's `depositState`.

2. **Receipt** (parent chain): The parent chain verifies the deposit exists by checking the child's state root (committed in the child block embedded in the parent block). A receipt is recorded in the parent's `receiptState`, and the demanded amount is transferred between accounts on the parent.

3. **Withdrawal** (child chain): The child chain verifies that a receipt exists on the parent by checking `parentHomestead.receiptState`. The original deposited tokens are released to the withdrawer.

At no point does any trusted third party hold custody of tokens. The verification is purely cryptographic: Sparse Merkle proofs against state roots that are committed in proof-of-work hashes.

## Cross-Chain Atomic Swaps

For exchanging value between two chains that don't have a direct parent-child relationship, Lattice implements a three-phase atomic swap protocol:

1. **Lock**: Tokens are locked in swap state on each maker's source chain. Account balances are debited and tokens become claimable by the counterparty or refundable by the sender after timeout.

2. **Settle**: A settlement record is written on the lowest common ancestor (LCA) of the two source chains. The LCA optimization means swaps between sibling chains settle on their parent, not necessarily the nexus, reducing nexus load.

3. **Claim/Refund**: Each counterparty claims the other's locked tokens by proving settlement exists. If the swap times out, the original sender refunds by proving the timelock has expired.

The claim and refund windows are mutually exclusive (claims require settlement proof before timeout; refunds require timeout to have passed), so a swap cannot be both claimed and refunded.

Fees are fully refundable — they are locked alongside the fill amount in swap state, so a maker whose swap times out gets back everything they locked, including the fee.

## Persistent On-Chain Order Book

Beyond instant matching (where both sides must appear in the same transaction), Lattice supports a persistent order book:

- **Post**: A maker submits a signed order. Tokens are escrowed in `orderLockState` at post time, not at fill time. This means the maker's commitment is binding and verifiable on-chain.

- **Fill**: A matcher pairs two previously posted orders. The locked amounts are released from `orderLockState` and converted into swap locks, entering the same settle/claim flow as instant matches.

- **Cancel**: The maker signs a cancellation. The locked amount is returned after verifying the declared amount matches state (preventing cancel inflation attacks).

The "lock at post time" design means the order book provides real price discovery: every posted order is backed by escrowed funds, so the book cannot be polluted with unbacked orders.

## JavaScript Filters: Programmable Chain Policy

Each `ChainSpec` can include JavaScript expressions (`transactionFilters` and `actionFilters`) that act as custom validation rules. Transactions and actions are serialized to JSON and passed to these filter functions; the transaction is only valid if every filter returns `true`.

This is deliberately not a general smart contract system. The filters are pure predicates — they can reject transactions but cannot modify state. They run in a sandboxed JavaScript context (`JXKit`) with no access to chain state, network, or filesystem.

The intent is to allow chain creators to define economic policy without introducing Turing-complete state transitions. A chain for stablecoins might filter out transactions above a certain size. A chain for a specific application might require transactions to include certain metadata fields. The filters compose across the hierarchy: child chain transactions must pass both the child's filters and every ancestor's filters, up to the nexus.

## What Lattice Does Not Solve

Lattice restructures where the blockchain trilemma's tradeoffs land, but it does not eliminate them.

**The nexus is still a single chain.** It is bounded by the same throughput constraints as any single-chain PoW system. Horizontal scaling happens through child chains, not through making the nexus faster.

**Finality latency grows with depth.** A transaction on a chain at depth D requires D levels of block confirmations for full security. A nexus transaction needs one confirmation; a grandchild transaction needs three (grandchild block confirmed on child, child block confirmed on nexus, nexus block confirmed by subsequent blocks).

**Cross-chain MEV is structurally easier for merged miners.** A miner that mines both the nexus and a child chain sees pending transactions on both chains simultaneously. This is the same miner-extractable value problem that exists in single-chain systems, amplified across the hierarchy. Lattice does not attempt to solve MEV — it acknowledges it as an inherent property of the hierarchical mining structure.

**Block size grows with child chain count.** Each child block is embedded in its parent's `childBlocks` field. More child chains means larger parent blocks. The `maxBlockSize` parameter in `ChainSpec` provides a hard cap, but the tension between chain count and block size is fundamental.

## Implementation Language Choice

Lattice is implemented in Swift 6 for several reasons that align with the protocol's design:

- **Actor model.** Swift's native actor system maps directly onto the chain hierarchy. Each chain is an actor. Reorganization propagation is message passing between actors. The compiler enforces isolation.

- **Strict sendability.** Swift 6's sendability checking means data races in the consensus layer are compile-time errors, not runtime heisenbugs.

- **Apple ecosystem.** The roadmap includes an iOS light client SDK, SwiftUI wallet, and on-device cross-chain proof verification. Writing the protocol layer in Swift means the mobile client shares the same validation code as full nodes.

- **Performance.** Swift compiles to native code with predictable performance characteristics. There is no garbage collector introducing latency spikes during block validation.

## Design Principles

Several principles guided the design decisions throughout Lattice:

**Verify everything locally.** No validation step requires querying an external system. Block validation is a pure function of the block data and Sparse Merkle proofs. Cross-chain verification uses committed state roots, not external oracles.

**Derive, don't declare.** Matched orders automatically derive the swap actions, settle actions, and account actions they imply. The transaction doesn't redundantly declare what the protocol can compute. This reduces the surface for inconsistency and simplifies validation.

**Make the common case fast.** Six independent sub-state trees update concurrently. Fork choice results are cached and invalidated incrementally. Main chain timestamps are indexed for fast difficulty calculation without fetcher round-trips.

**Fail early, fail cheaply.** Validation checks are ordered from cheapest to most expensive. Structural checks (timestamps, index continuity, difficulty) happen before signature verification, which happens before state proof generation. A malformed block is rejected in microseconds, not milliseconds.

**No implicit trust.** Even blocks that don't meet a chain's difficulty target are validated for homestead continuity before their child blocks are processed. This prevents an attacker from fabricating intermediate blocks with forged state that grandchildren then reference.
