# Lattice

A hierarchical multi-chain blockchain framework in Swift, where a root "nexus" chain can spawn child chains that form a lattice structure with native cross-chain value transfer.

## Table of Contents

- [Motivation](#motivation)
- [Architecture Overview](#architecture-overview)
- [Design Decisions](#design-decisions)
- [Project Structure](#project-structure)
- [Getting Started](#getting-started)
- [Core Concepts](#core-concepts)
- [Fork Choice and Consensus](#fork-choice-and-consensus)
- [The Blockchain Trilemma: An Honest Assessment](#the-blockchain-trilemma-an-honest-assessment)
- [Cross-Chain Value Transfer](#cross-chain-value-transfer)
- [Configurable Economics via ChainSpec](#configurable-economics-via-chainspec)
- [Cryptography](#cryptography)
- [Dependencies](#dependencies)
- [Requirements](#requirements)
- [Roadmap](#roadmap)

## Motivation

Most blockchain architectures force a choice: one monolithic chain that does everything, or isolated chains that can't easily move value between them. Both have real costs. Monolithic chains hit throughput ceilings -- every node must process every transaction, and state bloat grows without bound. Multi-chain ecosystems solve throughput but fracture liquidity behind bridges that are trusted third parties, historically the most exploited components in crypto (Ronin, Wormhole, Nomad).

Lattice takes a different approach. A single nexus chain acts as the root of a tree of chains, where any chain can spawn child chains via genesis transactions. Child chains inherit security from their parent while maintaining independent state, and value flows between them through a cryptographically-verified deposit/withdrawal/receipt protocol -- no external bridges, no trusted third parties.

**Why a tree, not a mesh?** A tree structure gives every chain exactly one parent. This means cross-chain proofs only need to reference one other chain's state (the parent), not an arbitrary graph of chains. It keeps the proof verification path bounded and the mental model simple: value always flows up or down one level at a time.

**Why content-addressing?** The framework is built on content-addressed data (IPLD/CID) from the ground up. Every piece of state -- blocks, transactions, account balances, peer registries -- lives in Merkle structures that can be lazily resolved from any content-addressed store. This means nodes don't need to hold the full state of every chain in the lattice. They can verify proofs against Merkle roots and fetch only what they need. This is what makes the multi-chain architecture practical rather than theoretical: you can run a node that only tracks the chains you care about and still verify cross-chain operations trustlessly.

**Why Swift?** Swift's actor model maps naturally to blockchain node internals: each chain level is an isolated actor with its own state, communicating through structured concurrency. Swift 6's strict sendability checking catches data races at compile time, which matters for consensus-critical code. The language is also a first-class citizen on Apple platforms, opening the door to mobile light clients that can verify Merkle proofs natively without bridging to C/Rust.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Lattice (actor)                       │
│  Entry point for block processing. Owns the root        │
│  ChainLevel (nexus) and dispatches blocks downward.     │
└────────────────────────┬────────────────────────────────┘
                         │
              ┌──────────▼──────────┐
              │  ChainLevel (actor) │ ◄── One per chain in the hierarchy
              │  ┌────────────────┐ │
              │  │ ChainState     │ │ ◄── Consensus state (tips, forks, reorgs)
              │  │ (actor)        │ │
              │  └────────────────┘ │
              │  children: [String: │
              │    ChainLevel]      │
              └──┬──────────────┬───┘
                 │              │
          ┌──────▼───┐  ┌──────▼───┐
          │ ChainLevel│  │ ChainLevel│   ... child chains
          └──────────┘  └──────────┘
```

Each `ChainLevel` owns a `ChainState` actor that manages block metadata, fork tracking, and reorganization for a single chain. Child chains are nested `ChainLevel` instances keyed by their directory name. Block processing cascades downward: if a block doesn't match the current chain's difficulty target, it's offered to child chains.

### Data Flow: Block Submission

```
Block arrives
  │
  ▼
Lattice.processBlockHeader()
  │
  ├── Validate block (structure, PoW, state transitions)
  │
  ├── Determine which chain this block belongs to
  │     (match difficulty target, parent block ancestry)
  │
  ├── Submit to appropriate ChainState
  │     ├── Insert into block index
  │     ├── Evaluate fork choice rule
  │     └── Trigger reorganization if needed
  │
  └── Propagate to child ChainLevels if block contains child blocks
```

## Design Decisions

### Content-Addressed Everything

All data structures are wrapped in `HeaderImpl<T>`, which pairs a value with its CID (Content Identifier). Data is resolved lazily through a `Fetcher` protocol, so a block header can reference its transactions, parent block, and state roots without embedding them inline. This is the same IPLD model used by IPFS and Filecoin, powered by the [cashew](https://github.com/pumperknickle/cashew) library.

**Why this matters**: A node tracking the nexus chain doesn't need to download every child chain's full state -- it can verify Merkle proofs against the state roots embedded in parent chain blocks. Lazy resolution means you pay for data access only when you actually need the underlying value.

### Hierarchical Chain Structure

```
Nexus (root chain)
├── Chain A (child)
│   ├── Chain A1 (grandchild)
│   └── Chain A2
└── Chain B (child)
```

Each `Block` contains a `childBlocks` field -- a Merkle dictionary of child chain genesis blocks. A `GenesisAction` in a transaction creates a new child chain by embedding its full genesis block. Child chains reference their parent's state through `parentHomestead`, enabling cross-chain state verification without trust assumptions.

The `ChainLevel` actor models this hierarchy: each level holds its own `ChainState` plus a dictionary of child `ChainLevel`s. Block processing cascades -- if a block doesn't belong to the current chain's difficulty target, it's offered to child chains.

### Three-Phase State Model

Each block carries three state snapshots:

- **`parentHomestead`** -- the confirmed state of the parent chain, used to verify cross-chain operations
- **`homestead`** -- the confirmed state entering this block (must equal the previous block's frontier)
- **`frontier`** -- the new state after applying this block's transactions

Validation enforces `previousBlock.frontier == currentBlock.homestead`, creating an unbroken state chain. The prove-then-update pattern ensures every state transition is backed by Sparse Merkle proofs before mutations are applied.

**Why three phases instead of two?** The `parentHomestead` is what makes trustless cross-chain operations possible. When a withdrawal on Chain A needs to verify a deposit on Chain A's parent, it reads from `parentHomestead` -- a snapshot of the parent's state that was committed into Chain A's block. This is the cryptographic anchor that eliminates the need for bridges.

### Partitioned World State

The world state (`LatticeState`) is split into eight independent sub-states, each a Sparse Merkle Tree:

| Sub-state | Stores | Key |
|---|---|---|
| `AccountState` | Token balances | Public key CID |
| `GeneralState` | Arbitrary key-value data | User-defined key |
| `DepositState` | Cross-chain deposit records | Demander/amount/nonce |
| `WithdrawalState` | Cross-chain withdrawal records | Deposit key |
| `ReceiptState` | Cross-chain transfer receipts | Directory/demander/amount/nonce |
| `PeerState` | Network peer registry | Owner public key CID |
| `GenesisState` | Child chain genesis blocks | Directory name |
| `TransactionState` | Transaction index | Nonce |

**Why partition?** Two reasons. First, concurrent updates: all eight sub-states are proved and updated in parallel using Swift's `async let` during block validation. Second, proof efficiency: a light client verifying a balance transfer only needs the `AccountState` Merkle proof, not a proof over the entire world state.

### Actor-Based Concurrency Model

The consensus layer uses Swift actors throughout:

- **`ChainState`** (actor): Manages block metadata, fork tracking, and the main chain hash set for a single chain. Actor isolation guarantees that concurrent block submissions don't corrupt consensus state.
- **`ChainLevel`** (actor): Owns a `ChainState` and its child chains. Reorganizations propagate through the actor hierarchy without shared mutable state.
- **`Lattice`** (actor): Top-level entry point. Ensures block processing is serialized at the entry boundary while allowing child chain operations to proceed concurrently.

This maps the natural isolation boundaries of a multi-chain system directly onto Swift's concurrency model. Each chain is an isolated computation unit -- exactly what actors provide.

### Proof-of-Work

Blocks are mined by finding a nonce such that the SHA-256 hash of the block's canonical fields (as a `UInt256`) is numerically less than the difficulty target. The difficulty hash includes the previous block CID, transaction Merkle root, state roots, spec, timestamp, index, and nonce -- everything needed to commit to a unique block.

PoW was chosen as the initial consensus mechanism for its simplicity and well-understood security properties. The architecture doesn't assume PoW permanently -- the `ChainSpec` abstraction allows individual chains to define their own consensus parameters, and the validation pipeline can be extended to support other mechanisms.

## Project Structure

```
Sources/
├── Lattice/
│   ├── Lattice/
│   │   ├── Lattice.swift          # Top-level actor, block processing entry point
│   │   ├── Chain.swift            # ChainState actor, fork choice, reorgs
│   │   └── ChainIndex.swift       # Chain indexing protocol
│   ├── Block/
│   │   ├── Block.swift            # Block structure, helper methods
│   │   ├── Block+Validate.swift   # Block validation (genesis, nexus, child)
│   │   └── ChainSpec.swift        # Economic parameters, reward schedule
│   ├── Transaction/
│   │   ├── Transaction.swift      # Transaction with signatures
│   │   └── TransactionBody.swift  # Action aggregation, validation
│   ├── Actions/
│   │   ├── Action.swift           # Generic key-value state changes
│   │   ├── AccountAction.swift    # Balance transfers
│   │   ├── DepositAction.swift    # Cross-chain deposit locking
│   │   ├── WithdrawalAction.swift # Cross-chain fund claiming
│   │   ├── ReceiptAction.swift    # Cross-chain transfer acknowledgment
│   │   ├── GenesisAction.swift    # Child chain creation
│   │   └── PeerAction.swift       # Network peer management
│   ├── State/
│   │   ├── LatticeState.swift     # Aggregated world state (8 sub-states)
│   │   ├── AccountState.swift     # Token balance Merkle tree
│   │   ├── GeneralState.swift     # Arbitrary KV Merkle tree
│   │   ├── DepositState.swift     # Deposit record Merkle tree
│   │   ├── WithdrawalState.swift  # Withdrawal record Merkle tree
│   │   ├── ReceiptState.swift     # Receipt record Merkle tree
│   │   ├── PeerState.swift        # Peer registry Merkle tree
│   │   ├── GenesisState.swift     # Genesis block Merkle tree
│   │   ├── TransactionState.swift # Transaction index Merkle tree
│   │   └── StateErrors.swift      # State operation errors
│   ├── Core/
│   │   └── PublicKey.swift        # Public key type wrapper
│   ├── CryptoUtils.swift          # Key generation, signing, hashing
│   ├── UInt256+Extensions.swift   # Hex conversion, UInt256 hashing
│   ├── Blockchain.swift           # High-level blockchain coordinator
│   ├── Wallet.swift               # Wallet abstraction
│   ├── Validator.swift            # Validator node logic
│   └── Miner.swift                # PoW mining logic
├── LatticeDemo/
│   └── main.swift                 # Demo executable
Tests/
└── LatticeTests/
    ├── ChainSpecTests.swift       # Reward schedule, halving, difficulty
    ├── ChainConsensusTests.swift  # Fork choice, reorgs, parent anchoring
    ├── UInt256ExtensionsTests.swift # Hex conversion, hashing
    └── LatticeTests.swift         # Integration tests
```

## Getting Started

### Installation

Add Lattice as a Swift Package Manager dependency:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/<owner>/lattice.git", branch: "master")
]
```

Then add `"Lattice"` to your target's dependencies.

### Building

```bash
swift build
```

### Running Tests

```bash
swift test
```

### Running the Demo

```bash
swift run LatticeDemo
```

## Core Concepts

### Blocks

A `Block` is the fundamental unit of the chain. It contains:

- A reference to the previous block (`previousBlock: HeaderImpl<Block>?`)
- A Merkle dictionary of transactions
- Three state snapshots: `parentHomestead`, `homestead`, `frontier`
- A Merkle dictionary of child chain genesis blocks (`childBlocks`)
- Proof-of-work fields: `difficulty`, `nextDifficulty`, `nonce`
- Metadata: `index`, `timestamp`, `spec`

Block validation is split by context:
- **Genesis blocks** (`validateGenesis`): No parent, empty initial state, valid transactions, correct frontier
- **Nexus blocks** (`validateNexus`): Full validation including parent continuity, difficulty, timestamps, deposits/withdrawals
- **Child blocks** (`validate(nexusHash:parentChainBlock:)`): Validated against parent chain state, timestamps synchronized with parent

### Transactions

A `Transaction` pairs a `TransactionBody` with a signature map (`[publicKeyHex: signatureHex]`). The body aggregates up to seven types of actions:

| Action Type | Purpose |
|---|---|
| `AccountAction` | Transfer tokens between accounts |
| `Action` | Generic key-value state mutations (supports JS filters) |
| `DepositAction` | Lock funds for cross-chain transfer |
| `WithdrawalAction` | Claim funds from cross-chain deposit |
| `ReceiptAction` | Acknowledge a cross-chain deposit on parent |
| `GenesisAction` | Create a child chain |
| `PeerAction` | Register/update/remove network peers |

Each action type implements its own validation logic and reports its state delta (bytes added/removed from the Merkle tree).

### State

`LatticeState` is the complete world state, composed of eight independent Sparse Merkle Trees. The `proveAndUpdateState()` method on `LatticeState` takes all actions from a block's transactions and applies them concurrently across all eight sub-states using `async let`:

```
Block.transactions
  → aggregate all AccountActions, DepositActions, etc.
  → async let account = accountState.proveAndUpdate(accountActions)
  → async let deposit = depositState.proveAndUpdate(depositActions)
  → ... (all 8 in parallel)
  → return new LatticeState with all updated sub-states
```

Each sub-state prove-and-update operation:
1. Generates a Sparse Merkle proof that the current values match the claimed `homestead`
2. Applies the mutations
3. Returns the new Merkle root (the `frontier`)

## Fork Choice and Consensus

Lattice uses a Nakamoto-style longest-chain rule augmented with parent chain anchoring. The fork choice algorithm in `Chain.swift` implements a priority system:

### Fork Choice Rule (`compareWork`)

Given two competing chain tips, the algorithm decides which fork to follow:

1. **Parent chain anchor wins**: If one fork has a block anchored to the parent chain and the other doesn't, the anchored fork wins. This is the key mechanism that ties child chain security to the parent.
2. **Lower parent index wins**: If both forks have parent chain anchors, the one anchored at a lower parent block index wins (it was confirmed earlier on the parent).
3. **Longer chain wins**: If neither fork has parent anchoring (or anchors are equal), the fork with more blocks wins (classic Nakamoto rule).

### Parent Chain Anchoring

When a child chain block is included in a parent chain block, the child `ChainState` records this relationship via `parentChainBlockHashToBlockHash`. This creates a two-way link:

- The parent chain block references child blocks in its `childBlocks` Merkle dictionary
- The child chain records which of its blocks was anchored at which parent index

This anchoring propagates through reorganizations: if the parent chain reorgs, child chains re-evaluate their fork choice because anchoring information may have changed.

### Reorganization

When a new block triggers a fork switch:

1. `checkForReorg()` walks both the old and new chain tips to find the common ancestor
2. `applyReorg()` updates the main chain hash set, swaps the chain tip, and returns a `Reorganization` describing blocks added/removed
3. Blocks older than `RECENT_BLOCK_DISTANCE` (1000 blocks) are pruned from memory
4. Child chains are notified of parent reorgs via `propagateParentReorg()`, which may trigger cascading child reorgs

## The Blockchain Trilemma: An Honest Assessment

The blockchain trilemma states that a distributed system can optimize for at most two of three properties: decentralization, security, and scalability. Lattice does not solve the trilemma. No architecture does -- a [formal proof published in 2025](https://www.mdpi.com/2076-3417/15/1/19) confirmed the inherent tradeoff is fundamental, not an engineering limitation. What Lattice does is restructure *where* the tradeoffs land through a mechanism that most multi-chain systems lack: nested merged mining.

### Nested Merged Mining

The key architectural difference between Lattice and other multi-chain systems is that miners don't choose between chains -- they mine all of them simultaneously.

Every parent chain block embeds child chain blocks in its `childBlocks` Merkle dictionary. The child block CIDs are included in the parent's PoW difficulty hash (`getDifficultyHash()`), so a single nonce search commits to blocks across the entire chain hierarchy. When a miner finds a hash that beats the nexus difficulty target, they produce a valid nexus block *and* valid blocks for every child chain whose difficulty target is also met. If the hash only beats a child chain's target, it produces a child block without a nexus block.

This is the same principle as [RSK's merged mining with Bitcoin](https://medium.com/iovlabs-innovation-stories/modern-merge-mining-f294e45101a0), but applied recursively. RSK reuses Bitcoin's hashrate for one sidechain. Lattice reuses the nexus hashrate for an entire tree of chains, and each child reuses its hashrate for its own children.

The consequences are significant:

- **No hashrate fragmentation.** A miner mining the nexus automatically secures every child chain. There is no "which chain do I mine?" decision -- the answer is all of them. This eliminates the hashrate allocation problem that plagues sovereign multi-chain systems like Cosmos (where each zone recruits its own validator set) and Avalanche (where each subnet requires its own stakers).
- **Child chains inherit the full parent hashrate.** A child chain block embedded in a parent block is backed by the parent's full mining power. Attacking that child block requires outcomputing the parent chain's miners, not just the child chain's. This is strictly stronger than periodic anchoring alone.
- **Mining profitability increases with chain count.** Each additional child chain adds block rewards and transaction fees to the same mining operation. A miner producing a nexus block that also includes blocks for 5 child chains collects 6 block rewards for the cost of one nonce search. This creates a positive feedback loop: more chains make mining more profitable, attracting more hashrate, making all chains more secure.
- **Timestamps are enforced across the hierarchy.** Child blocks must share their parent block's timestamp (`parentChainBlock.timestamp != timestamp` fails validation). This proves the child block was mined simultaneously with the parent, not retroactively attached.

### What Lattice Actually Improves

**Throughput scales horizontally without sacrificing security.** Each child chain processes transactions independently. Ten sibling chains produce ten times the aggregate throughput of any single chain, because they share no state and don't validate each other's transactions. Unlike Cosmos zones or Avalanche subnets, these chains don't need to recruit their own miners -- they inherit security from the nexus through merged mining. Adding chains adds throughput without diluting security.

**Cross-chain transfers don't require trusted intermediaries.** Between 2022 and 2024, bridge exploits drained over [$2 billion](https://www.fxempire.com/news/article/over-2b-lost-in-13-separate-crypto-bridge-hacks-this-year-1085594) from protocols -- the Ronin bridge alone lost $624M to the Lazarus Group, Wormhole lost $326M to a verification bypass, and Nomad lost $190M to a trusted root exploit. These bridges failed because they introduced trusted third parties between chains. Lattice's deposit/receipt/withdrawal protocol eliminates this attack surface: cross-chain proofs are verified against Merkle roots already committed in the block structure. There is no multisig, no federation, no relayer that can be compromised. Compare this to RSK, which despite merged mining still relies on a [federated bridge](https://web3.gate.com/en/crypto-wiki/article/exploring-rootstock-an-in-depth-overview-of-bitcoin-s-sidechain-solution-20251208) for BTC transfers.

**Light clients can verify cross-chain state.** Because all state is Merkle-ized and blocks embed state roots for both the current chain and the parent chain (`parentHomestead`), a light client on any chain can verify a cross-chain operation by checking a Merkle proof against a committed root. This is the same verification model that Ethereum's rollup-centric roadmap targets, applied natively across the chain hierarchy.

### What Lattice Does NOT Improve

**The nexus chain is still fully constrained by the trilemma.** The root chain has no parent to merge-mine with. Its throughput is bounded by the same physics as any single-chain PoW system. Every node on the nexus must process every nexus transaction. This is the same limitation Bitcoin and Ethereum L1 face.

**Deeper chains have longer finality latency.** A grandchild chain (depth 2) needs its block included in a child chain block, which in turn needs inclusion in a nexus block. If each level has a 10-minute block time, a grandchild block takes ~20 minutes to achieve nexus-level finality. At depth N, finality latency is O(N * block_time). This is a fundamental tradeoff: more hierarchy means more throughput but slower finality propagation. In practice, this bounds useful hierarchy depth to 2-3 levels for most applications.

**Block size grows with child chain count.** Each parent block embeds child chain blocks. A nexus block that includes blocks for 20 child chains is substantially larger than a single-chain block. This increases bandwidth requirements for nexus nodes and creates a practical ceiling on how many child chains a single parent can support per block. The `maxStateGrowth` parameter in `ChainSpec` bounds this, but the bound is per-chain, not per-hierarchy.

### How Lattice Compares to Existing Approaches

| Approach | Throughput | Security Model | Cross-Chain | Tradeoff |
|---|---|---|---|---|
| **Bitcoin** | ~7 TPS | Full PoW security | None natively | Throughput sacrificed for security + decentralization |
| **Ethereum (post-Danksharding)** | ~100K TPS via rollups | Rollups inherit L1 security via fraud/validity proofs; [PeerDAS](https://ethereum.org/roadmap/danksharding) enables data availability sampling | Rollup-to-rollup bridges still in development | L1 remains bottleneck for settlement; rollup fragmentation creates UX friction |
| **Cosmos (IBC)** | High (independent zones) | Each zone has its [own validator set](https://supra.com/academy/polkadot-vs-cosmos/); no shared security by default | IBC protocol: trustless but requires relayers | Sovereign zones mean security varies wildly; weak zones are attackable |
| **Polkadot (Relay Chain)** | High (parachains) | Parachains share [Relay Chain security](https://blockchainreporter.net/web3/polkadot-review/) via NPoS | XCMP for cross-chain messaging | Limited parachain slots; chains compete for shared security budget |
| **Avalanche (Subnets)** | High (independent subnets) | Each subnet has its [own validator set](https://moss.sh/news/layer-0-protocols-compared-cosmos-vs-polkadot-vs-avalanche/) with subnet-specific staking | Avalanche Warp Messaging | Similar to Cosmos: subnet security depends on subnet economics |
| **RSK (Merged Mining)** | Moderate | [Merge-mines with Bitcoin](https://medium.com/iovlabs-innovation-stories/modern-merge-mining-f294e45101a0); federated bridge for BTC transfers | Federation-based (trusted third parties) | Bridge is centralization point; merge-mining is single-level only |
| **Lattice** | Scales with chain count | Nested merged mining: child chains inherit full parent hashrate; same nonce search secures entire hierarchy | Merkle-proof-based deposit/receipt/withdrawal; no bridges, no federations | Nexus is throughput bottleneck; finality latency grows with depth; block size grows with child count |

**Lattice extends RSK's model recursively.** RSK demonstrated that merged mining lets a sidechain inherit Bitcoin's hashrate without fragmenting it. Lattice applies this at every level of a chain hierarchy, so a grandchild chain inherits the nexus hashrate through its parent, and cross-chain transfers are trustless instead of federated.

**Lattice achieves Polkadot's shared security without slot limits.** Polkadot parachains share the Relay Chain's security, but the number of parachains is bounded by the relay chain's validation capacity. In Lattice, any chain can spawn children without permission, and merged mining means those children don't compete for a fixed security budget -- they all share the same hashrate.

**Lattice solves Cosmos's security fragmentation.** Cosmos zones are sovereign, meaning a zone with a weak validator set is attackable regardless of how secure the Cosmos Hub is. In Lattice, every child chain is backed by the nexus hashrate through merged mining. A weak child chain doesn't exist -- all chains at the same depth have the same PoW security.

**Lattice's cross-chain model is closest to Cosmos IBC** in philosophy -- Merkle proof verification against committed state roots -- but with a structural advantage: the parent chain's state root is already embedded in every child chain block (`parentHomestead`), so cross-chain proofs don't require external relayers or separate light client connections.

### Incentive Analysis

The hardest problem in multi-chain architecture isn't cryptography -- it's economics. A system where rational actors don't mine, validate, or use the chains as intended is a system that fails regardless of its cryptographic properties. Nested merged mining changes the incentive landscape in ways that are both beneficial and dangerous.

**Mining economics favor participation.** Unlike sovereign multi-chain systems where miners must choose which chain to dedicate hashpower to, Lattice miners produce blocks for every chain in the hierarchy with a single nonce search. The marginal cost of securing an additional child chain is near zero (just the bandwidth to include the child block), while the marginal revenue is the child chain's block reward plus fees. This means rational miners always include all available child blocks, and the system converges toward full participation rather than hashrate fragmentation. This is the core economic advantage over Cosmos, Avalanche, and other systems where each chain competes for its own security budget.

**Cross-chain MEV is amplified, not reduced.** The honest risk of merged mining: the miner who produces a parent block also controls which child blocks are included. They see pending transactions on all chains simultaneously. This makes [cross-chain MEV](https://review.stanfordblockchain.xyz/p/60-cross-chain-mev-challenges-and) structurally easier to extract than in systems like Cosmos where different validators control different chains. In Ethereum's ecosystem, [two builders already win over 90%](https://www.esma.europa.eu/sites/default/files/2025-07/ESMA50-481369926-29744_Maximal_Extractable_Value_Implications_for_crypto_markets.pdf) of block auctions, driven by MEV concentration. Lattice's merged mining hands the parent chain miner the same kind of cross-chain ordering power. A miner can see a deposit on a child chain and front-run the corresponding receipt on the parent chain, or reorder child chain transactions to extract arbitrage. This is the strongest argument against the architecture and doesn't have a purely protocol-level solution -- it requires either proposer-builder separation, encrypted mempools, or acceptance that MEV is a cost of merged mining.

**Chain creation is cheap but not free.** Anyone can create a child chain via a `GenesisAction`, and merged mining means it automatically inherits the parent's hashrate. The `premine` parameter in `ChainSpec` serves as a soft cost: chain creators allocate themselves early block rewards, which means they're committing to a token distribution that has opportunity cost. But the protocol doesn't enforce a minimum security bond. In practice, the real cost of chain creation is convincing users and miners to include your chain's blocks -- a child chain with no transactions generates no fees, and rational miners might exclude it to save bandwidth. This is an organic market mechanism, but it means the lattice could accumulate orphaned chains that exist in state but serve no one.

**Deposit/withdrawal economics.** The three-step cross-chain transfer protocol has an implicit cost: three separate transactions (deposit, receipt, withdrawal) across two chains, each requiring inclusion in a block. If block space is scarce on either chain, cross-chain transfers compete with regular transactions for inclusion. This creates a fee market for cross-chain operations that is coupled to both chains' congestion levels. In the worst case, a congested parent chain could make child chain withdrawals prohibitively expensive, effectively trapping value. The merged mining structure helps here: since parent blocks include child blocks, a receipt transaction can be included in the same mining round as the deposit, reducing the minimum cross-chain transfer time to one parent block period.

**Long-term sustainability.** Every chain in the lattice has its own halving schedule. Because miners collect rewards from every chain simultaneously, a child chain with near-zero block rewards still gets mined -- the miner is already doing the work for the parent chain. This is fundamentally different from standalone chains where miners leave when rewards drop. A child chain on Lattice can survive on minimal fees because its security cost is already amortized across the hierarchy. The failure mode isn't miners leaving (they won't, because mining is free at the margin) but miners *ignoring* the chain -- choosing not to include its transactions because the fees aren't worth the bandwidth cost of a larger block.

### What Would Need to Be True

For Lattice to meaningfully improve on the trilemma in practice, these conditions would need to hold:

1. **Miners actually include child blocks.** Merged mining makes this nearly free, but not zero-cost -- each child block increases the parent block's size. If block propagation latency matters (as it does in PoW), miners face a tradeoff between collecting child chain fees and the orphan risk of a larger block.
2. **Cross-chain transfer volume justifies the three-transaction cost.** If most value stays on one chain, the hierarchy adds complexity without benefit.
3. **The nexus chain doesn't become a bandwidth bottleneck.** A nexus block embedding 50 child chain blocks is much larger than a single-chain block. Nexus nodes must validate all of them. This creates a practical ceiling that depends on network bandwidth and node hardware.
4. **MEV concentration doesn't undermine decentralization.** If merged mining gives large miners a structural advantage in cross-chain MEV extraction, mining could centralize around a few sophisticated operators -- undermining the decentralization leg of the trilemma even as security and throughput improve.
5. **Chain creators have skin in the game.** Without economic commitment requirements for chain creation, the lattice could fill with abandoned chains that bloat state and waste bandwidth.

None of these are guaranteed by the protocol. They depend on network effects, fee market dynamics, and miner game theory that can only be validated through deployment. The architecture makes the right things cheap (security via merged mining, cross-chain proofs via Merkle commitments) and the wrong things expensive (bridge attacks are impossible, hashrate fragmentation is irrational). Whether that's enough is an empirical question.

## Cross-Chain Value Transfer

Value moves between parent and child chains through a three-step protocol that requires no trusted intermediary:

### Step 1: Deposit (Child Chain)

A `DepositAction` on the child chain locks funds by recording:
- `demander`: Who is requesting the transfer
- `amountDemanded`: How much to transfer
- `nonce`: Unique identifier to prevent replay

The deposit is committed into the child chain's `DepositState` Merkle tree.

### Step 2: Receipt (Parent Chain)

A `ReceiptAction` on the parent chain acknowledges the deposit:
- References the child chain (`directory`)
- Contains the matching `demander`, `amount`, and `nonce`

The receipt is committed into the parent chain's `ReceiptState` Merkle tree.

### Step 3: Withdrawal (Child Chain)

A `WithdrawalAction` claims the funds by proving two things via Merkle proofs:
1. The deposit exists in `homestead.depositState` (current chain's state)
2. The corresponding receipt exists in `parentHomestead.receiptState` (parent chain's state snapshot)

Because `parentHomestead` is a committed state root in the child chain's block, verifying the receipt doesn't require querying the parent chain at validation time. The proof is self-contained.

### Why Three Steps?

Two steps (deposit + withdraw) would require the withdrawal transaction to include a real-time proof against the parent chain's current state, creating a synchronous dependency between chains. The receipt step breaks this dependency: the parent chain commits the acknowledgment into its own state, and the child chain can verify it asynchronously through the `parentHomestead` snapshot.

## Configurable Economics via ChainSpec

Each chain has a `ChainSpec` that defines its economic model. This allows different chains in the lattice to have entirely different economic properties.

### Parameters

| Parameter | Description |
|---|---|
| `directory` | Chain identifier (e.g., "Nexus") |
| `initialRewardExponent` | Block reward = 2^exponent tokens |
| `premine` | Blocks pre-mined by creator (offsets halving schedule) |
| `targetBlockTime` | Target milliseconds between blocks |
| `maxDifficultyChange` | Maximum difficulty adjustment per block |
| `maxNumberOfTransactionsPerBlock` | Transaction throughput limit |
| `maxStateGrowth` | Maximum state size increase per block (bytes) |
| `transactionFilters` | JavaScript expressions for custom tx validation |
| `actionFilters` | JavaScript expressions for custom action validation |

### Reward Schedule

Block rewards follow a halving schedule computed via bit arithmetic:

- `halvingInterval` = `2^initialRewardExponent` (same exponent that sets the initial reward)
- `initialReward` = `2^initialRewardExponent`
- `rewardAtBlock(index)` is O(1): shifts the initial reward right by `(index + premine) / halvingInterval`
- `totalRewards(through:)` uses geometric series for O(log n) computation

The `premine` parameter offsets the halving clock. If `premine = 1000` and `halvingInterval = 10000`, public block 0 earns the reward that block 1000 would earn on the halving schedule. This lets chain creators capture early-schedule rewards without delaying the network launch.

### Preset Configurations

```swift
ChainSpec.bitcoin       // 10-min blocks, 50 BTC initial reward (exponent 25 approximation)
ChainSpec.ethereum      // 15-sec blocks, adapted parameters
ChainSpec.development   // Fast blocks for testing
```

### Difficulty Adjustment

Per-block adjustment comparing actual block time to target:
- If the block was mined faster than target → difficulty increases
- If slower → difficulty decreases
- Change is bounded by `maxDifficultyChange` to prevent oscillation
- Minimum difficulty is enforced based on the chain spec

## Cryptography

`CryptoUtils` provides the cryptographic primitives:

- **Key generation**: P-256 ECDSA key pairs via Apple's `swift-crypto`
- **Signing**: ECDSA signatures over SHA-256 message digests
- **Verification**: Signature verification against public keys
- **Hashing**: SHA-256 for block hashes, Merkle trees, and address derivation
- **Addresses**: Hash160-style addresses (SHA-256 of public key, truncated)

Block difficulty comparison uses `UInt256` -- the SHA-256 hash of a block's canonical fields is interpreted as a 256-bit unsigned integer and compared against the difficulty target.

## Dependencies

| Dependency | Purpose |
|---|---|
| [cashew](https://github.com/pumperknickle/cashew) | Content-addressed Merkle data structures (IPLD nodes, Sparse Merkle Trees, `HeaderImpl`/CIDs) |
| [swift-crypto](https://github.com/apple/swift-crypto) | P-256 ECDSA signatures and SHA-256 hashing |
| [UInt256](https://github.com/hyugit/UInt256) | 256-bit unsigned integers for difficulty targets and block hashes |
| [swift-cid](https://github.com/swift-libp2p/swift-cid) | Content Identifier (CID) encoding/decoding |
| [CollectionConcurrencyKit](https://github.com/JohnSundell/CollectionConcurrencyKit) | Concurrent collection operations for parallel transaction validation |

## Requirements

- Swift 6.0+
- macOS 15+ / iOS 16+

## Roadmap

### Phase 1: Core Protocol Hardening (Current)

- [x] Block structure and validation (genesis, nexus, child)
- [x] Three-phase state model (parentHomestead / homestead / frontier)
- [x] Eight partitioned Sparse Merkle Tree sub-states
- [x] Cross-chain deposit/withdrawal/receipt protocol
- [x] Nakamoto fork choice with parent chain anchoring
- [x] Reorganization propagation through chain hierarchy
- [x] Configurable ChainSpec with halving schedule and difficulty adjustment
- [x] P-256 ECDSA transaction signing and verification
- [x] JavaScript-based transaction/action filters
- [x] Fuzz testing for block validation edge cases
- [x] Property-based testing for state transition invariants
- [x] Formal specification of the cross-chain transfer protocol

### Phase 2: Networking

- [x] libp2p-based peer discovery and gossip protocol
- [x] Block propagation across the network
- [x] Transaction mempool with fee-based prioritization
- [x] Peer reputation scoring (tracked via `PeerState`)
- [x] Chain-specific peer sets (nodes subscribe to chains they care about)

### Phase 3: Storage and Sync

- [x] Persistent block and state storage backend (pluggable via `Fetcher` protocol)
- [x] Content-addressed data retrieval via Acorn CAS worker chain
- [x] Fast sync via state snapshots (download Merkle root + proofs, skip full replay)
- [x] Header-first sync for light clients
- [x] Pruning strategies for old state (only keep recent Merkle roots + proofs)

### Phase 4: Light Clients and Mobile

- [ ] iOS light client SDK (verify Merkle proofs without full state)
- [ ] SPV-style block header chain for mobile wallets
- [ ] Cross-chain proof verification on-device
- [ ] SwiftUI wallet reference implementation

### Phase 5: Advanced Features

- [ ] Alternative consensus mechanisms per chain (PoS, PoA via ChainSpec extension)
- [ ] Smart contract execution layer (WASM or custom VM per chain)
- [ ] Atomic cross-chain swaps (multi-step deposit/receipt/withdrawal in a single logical operation)
- [ ] Chain governance: on-chain voting for ChainSpec parameter changes
- [ ] Fee market with EIP-1559-style base fee adjustment
- [ ] Recursive child chain spawning with depth limits

### Phase 6: Tooling and Ecosystem

- [ ] Block explorer with multi-chain navigation
- [ ] CLI node operator tools (chain management, monitoring, diagnostics)
- [ ] Chain creator toolkit (configure and deploy new child chains)
- [ ] Developer SDK for building applications on Lattice chains
- [ ] Metrics and observability (block times, reorg frequency, cross-chain transfer latency)

## Status

Active development. The core validation logic, state management, consensus, and cross-chain protocol are implemented. Networking and persistent storage are the next major milestones.
