<p align="center">
  <h1 align="center">Lattice</h1>
  <p align="center">
    <strong>The hierarchical blockchain.</strong>
    <br />
    One proof-of-work. Every chain secured. No bridges. No trusted third parties.
  </p>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> &bull;
  <a href="SPEC.md">Protocol Spec</a> &bull;
  <a href="CROSS_CHAIN_PROTOCOL.md">Cross-Chain Protocol</a> &bull;
  <a href="#architecture">Architecture</a> &bull;
  <a href="#roadmap">Roadmap</a>
</p>

---

## What is Lattice?

Lattice is a Layer 1 blockchain protocol where a single root chain (the **nexus**) can spawn an unlimited tree of child chains. Every child chain inherits the full security of its parent through **nested merged mining** — one nonce search secures the entire hierarchy. Value flows between chains through a cryptographic deposit/receipt/withdrawal protocol verified entirely by Merkle proofs. No bridges. No federations. No relayers.

**This is not a testnet, a token, or a whitepaper.** This is a working implementation in Swift with full block validation, consensus, state management, networking, and cross-chain transfers.

### Why Lattice exists

Every multi-chain system before Lattice forces the same tradeoff: either chains share security and compete for limited slots (Polkadot), or chains are sovereign and must recruit their own validators (Cosmos, Avalanche). Both fragment security. Both require trusted bridges for cross-chain value transfer — the [most exploited components in crypto](https://www.fxempire.com/news/article/over-2b-lost-in-13-separate-crypto-bridge-hacks-this-year-1085594), responsible for over $2 billion in losses between 2022-2024.

Lattice eliminates both problems:

- **Nested merged mining** — Miners mine every chain in the hierarchy with a single hash. No hashrate fragmentation. No "which chain do I mine?" decision. Every child chain is backed by the full parent hashrate. This extends [RSK's merged mining with Bitcoin](https://medium.com/iovlabs-innovation-stories/modern-merge-mining-f294e45101a0) recursively across an entire tree of chains.

- **Trustless cross-chain transfers** — Value moves between chains via Merkle proof verification against state roots already committed in blocks. No multisig. No federation. No relayer. Compare this to RSK, which despite merged mining still relies on a [federated bridge](https://web3.gate.com/en/crypto-wiki/article/exploring-rootstock-an-in-depth-overview-of-bitcoin-s-sidechain-solution-20251208) for BTC transfers.

- **Unlimited chain creation** — Any chain can spawn children via a genesis transaction. No slot auctions. No governance proposals. No permission required. Each child chain has its own economic parameters, transaction filters, and state — but inherits the parent's full proof-of-work security.

### How it compares

| | Security Model | Cross-Chain | Chain Limit |
|---|---|---|---|
| **Bitcoin** | Full PoW | None | 1 chain |
| **Ethereum** | L1 + rollup proofs | Bridges (trusted) | Unlimited rollups, L1 bottleneck |
| **Cosmos** | Per-zone validators | IBC + relayers | Unlimited, fragmented security |
| **Polkadot** | Shared via relay chain | XCMP | Limited parachain slots |
| **Avalanche** | Per-subnet validators | Warp messaging | Unlimited, fragmented security |
| **Lattice** | Nested merged mining | Merkle proofs, no bridges | Unlimited, shared security |

---

## Quickstart

### Requirements

- Swift 6.0+
- macOS 15+

### Build

```bash
swift build
```

### Test

```bash
swift test
```

### Run

```bash
swift run LatticeDemo
```

### Use as a dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/treehauslabs/Lattice.git", branch: "master")
]
```

---

## Architecture

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
              │  │ ChainState     │ │ ◄── Consensus: tips, forks, reorgs
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

Every `ChainLevel` owns a `ChainState` actor that manages block metadata, fork tracking, and reorganization for a single chain. Child chains are nested `ChainLevel` instances. Block processing cascades downward: if a block doesn't match the current chain's difficulty target, it's offered to children.

### Core design

**Content-addressed everything.** All data — blocks, transactions, state — is wrapped in content-addressed headers (IPLD/CID). Nodes only fetch what they need. A node tracking the nexus doesn't download child chain state; it verifies Merkle proofs against committed roots.

**Three-phase state model.** Each block carries `parentHomestead` (parent chain's state), `homestead` (confirmed state entering the block), and `frontier` (state after applying transactions). This is what makes trustless cross-chain verification possible without querying another chain at validation time.

**Eight partitioned sub-states.** World state is split into eight independent Sparse Merkle Trees (accounts, general KV, deposits, withdrawals, receipts, peers, genesis blocks, transactions). All eight are proved and updated concurrently via Swift `async let`. Light clients only need proofs for the sub-state they care about.

**Actor-based concurrency.** The consensus layer maps directly onto Swift's actor model. Each chain is an isolated actor. Reorganizations propagate through the actor hierarchy without shared mutable state. Swift 6's strict sendability checking catches data races at compile time.

### Block processing flow

```
Block arrives
  │
  ├── Validate (structure, PoW, state transitions)
  ├── Determine chain (difficulty target, parent ancestry)
  ├── Submit to ChainState (insert, evaluate fork choice, reorg if needed)
  └── Propagate child blocks to child ChainLevels
```

### Fork choice rule

1. **Parent-anchored beats unanchored** — a block included in a parent chain block always wins
2. **Lower parent index wins** — earlier confirmation on the parent chain takes priority
3. **Longer chain wins** — classic Nakamoto rule as tiebreaker

### Cross-chain value transfer

A three-phase protocol with no trusted intermediaries:

1. **Deposit** (child chain) — Lock funds in child chain's `DepositState` Merkle tree
2. **Receipt** (parent chain) — Parent acknowledges the deposit in its `ReceiptState`
3. **Withdrawal** (child chain) — Claim funds by proving both the deposit and receipt exist via Merkle proofs against committed state roots

Full formal specification: [CROSS_CHAIN_PROTOCOL.md](CROSS_CHAIN_PROTOCOL.md)

---

## Economic model

Each chain defines its own economics via `ChainSpec`:

| Parameter | Description |
|---|---|
| `initialRewardExponent` | Block reward = 2^exponent tokens |
| `premine` | Halving schedule offset for chain creators |
| `targetBlockTime` | Target milliseconds between blocks |
| `maxNumberOfTransactionsPerBlock` | Throughput limit |
| `maxStateGrowth` | Maximum state size increase per block |
| `transactionFilters` / `actionFilters` | JavaScript expressions for custom validation |

Block rewards halve on a schedule determined by the exponent. The `premine` offsets the halving clock so chain creators can capture early rewards. Total supply converges to `UInt64.max`.

Preset configurations: `ChainSpec.bitcoin` (10-min blocks), `ChainSpec.ethereum` (15-sec blocks), `ChainSpec.development` (fast blocks for testing).

---

## The trilemma

Lattice does not solve the blockchain trilemma. [It's been formally proven unsolvable.](https://www.mdpi.com/2076-3417/15/1/19) What Lattice does is restructure where the tradeoffs land:

**What improves:**
- Throughput scales horizontally — ten sibling chains = ten times the throughput, all sharing the same PoW security
- Cross-chain transfers are trustless — no bridge exploits possible
- Light clients can verify cross-chain state via Merkle proofs
- Mining profitability increases with chain count (same nonce, more rewards)

**What doesn't:**
- The nexus chain is still bounded by single-chain PoW limits
- Finality latency grows with hierarchy depth: O(depth × block_time)
- Block size grows with child chain count
- Cross-chain MEV is structurally easier for merged miners to extract

Full analysis including incentive dynamics, failure modes, and comparison to every major L1: see the [detailed trilemma assessment](SPEC.md).

---

## Project structure

```
Sources/Lattice/
├── Lattice/          Lattice actor, ChainState, ChainLevel
├── Block/            Block structure, validation, ChainSpec
├── Transaction/      Transaction, TransactionBody, signatures
├── Actions/          Account, Deposit, Withdrawal, Receipt, Genesis, Peer, Action
├── State/            LatticeState + 8 sub-state Sparse Merkle Trees
├── Core/             PublicKey type
├── CryptoUtils.swift P-256 ECDSA, SHA-256, key generation
└── UInt256+Extensions.swift
```

## Cryptography

| Primitive | Algorithm | Usage |
|---|---|---|
| Hash | SHA-256 | Block hashes, Merkle trees, difficulty, addresses |
| Signature | P-256 ECDSA | Transaction authorization |
| Content addressing | CID (DAG-CBOR + SHA-256) | All data structure references |
| State proofs | Sparse Merkle Tree | Inclusion/exclusion proofs for all 8 sub-states |

## Dependencies

| Dependency | Purpose |
|---|---|
| [cashew](https://github.com/pumperknickle/cashew) | Content-addressed Merkle data structures (IPLD, Sparse Merkle Trees, CIDs) |
| [swift-crypto](https://github.com/apple/swift-crypto) | P-256 ECDSA + SHA-256 |
| [UInt256](https://github.com/treehauslabs/UInt256) | 256-bit integers for difficulty targets |
| [swift-cid](https://github.com/swift-libp2p/swift-cid) | Content Identifier encoding |
| [CollectionConcurrencyKit](https://github.com/JohnSundell/CollectionConcurrencyKit) | Concurrent collection operations |

---

## Roadmap

### Done

- [x] Block validation (genesis, nexus, child chain)
- [x] Three-phase state model (parentHomestead / homestead / frontier)
- [x] Eight partitioned Sparse Merkle Tree sub-states with concurrent updates
- [x] Cross-chain deposit/receipt/withdrawal protocol
- [x] Nakamoto fork choice with parent chain anchoring
- [x] Reorganization propagation through chain hierarchy
- [x] Configurable ChainSpec with halving schedule and difficulty adjustment
- [x] P-256 ECDSA transaction signing and verification
- [x] JavaScript transaction/action filters
- [x] libp2p networking, peer discovery, block gossip
- [x] Transaction mempool with fee-based prioritization
- [x] Persistent storage backend via Fetcher protocol
- [x] Content-addressed data retrieval
- [x] Fast sync via state snapshots
- [x] Header-first sync for light clients
- [x] Formal protocol specification

### Next

- [ ] iOS light client SDK
- [ ] SPV block header chain for mobile wallets
- [ ] Cross-chain proof verification on-device
- [ ] SwiftUI wallet reference implementation
- [ ] Alternative consensus per chain (PoS, PoA via ChainSpec extension)
- [ ] Atomic cross-chain swaps
- [ ] On-chain governance for ChainSpec changes
- [ ] EIP-1559-style fee market
- [ ] Block explorer with multi-chain navigation
- [ ] CLI node operator tools
- [ ] Chain creator toolkit
- [ ] Developer SDK

---

## License

See [LICENSE](LICENSE) for details.
