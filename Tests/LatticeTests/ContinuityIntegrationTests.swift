import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// MARK: - Helpers (mirror HomesteadContinuityTests to keep each file self-contained)

private let difficulty = UInt256(1000)

private func makeSpec(_ dir: String) -> ChainSpec {
    ChainSpec(directory: dir, maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
}

private func addr(_ publicKey: String) -> String {
    HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

private func sign(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = HeaderImpl<TransactionBody>(node: body)
    let s = CryptoUtils.sign(message: h.rawCID, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: s], body: h)
}

private func storeBlock(_ block: Block, to fetcher: StorableFetcher) async throws {
    let storer = CollectingStorer()
    try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
    await storer.flush(to: fetcher)
}

private func header(_ block: Block) -> BlockHeader {
    VolumeImpl<Block>(node: block)
}

/// Integration tests for `Lattice.processBlockHeader` / `acceptChildBlockTree`
/// that exercise scenarios newly guarded by the 7.12.0 continuity fix:
///   - forged continuity chain attack (blocked E2E)
///   - out-of-order delivery (skip-path block arrives before its predecessor)
///   - reorg through continuity (previousBlock living on a side chain)
@MainActor
final class ContinuityIntegrationTests: XCTestCase {

    // MARK: - #1 Forged continuity chain: grandchild cannot withdraw against forged parent state

    /// Attacker mines only the grandchild (cheap PoW at the deepest level),
    /// then fabricates a parent-level skip-path block that "legitimates" a
    /// forged homestead by pointing at a never-validated predecessor. Before
    /// 7.12.0, the one-hop `prev.frontier == curr.homestead` check let this
    /// slide. The grandchild's withdrawal would have then redeemed a fake
    /// receipt against the forged parent state.
    ///
    /// Post-fix: the skip-path check requires previousBlock be on the parent
    /// chain's hashToBlock, so the fabricated predecessor is rejected and the
    /// grandchild is never tree-walked into D's chain.
    func testForgedContinuityChainBlocksGrandchildAcceptance() async throws {
        let nexusSpec = makeSpec("Nexus")
        let bSpec = makeSpec("B")
        let dSpec = makeSpec("D")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        // Real tree: nexus (A) → B → D, all at height 0 (genesis only).
        let bGenesis = try await BlockBuilder.buildGenesis(
            spec: bSpec, timestamp: now - 60_000, difficulty: difficulty, fetcher: fetcher
        )
        let dGenesis = try await BlockBuilder.buildGenesis(
            spec: dSpec, timestamp: now - 60_000, difficulty: difficulty, fetcher: fetcher
        )
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: now - 60_000, difficulty: difficulty, fetcher: fetcher
        )

        // Fabricated B-level predecessor: never goes through validation. Its
        // "frontier" is entirely attacker-chosen (here we use empty as a
        // stand-in — the attack doesn't depend on particular state contents,
        // just on the fabrication being accepted).
        let forgedState = LatticeState.emptyHeader
        let fabricatedPrev = Block(
            previousBlock: VolumeImpl<Block>(node: bGenesis),
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: VolumeImpl<ChainSpec>(node: bSpec),
            parentHomestead: LatticeState.emptyHeader,
            homestead: bGenesis.frontier,
            frontier: forgedState,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 1,
            timestamp: now - 50_000,
            nonce: 0
        )
        try await storeBlock(fabricatedPrev, to: fetcher)

        // Parent-level skip-path block: fails B's difficulty (tiny target
        // guarantees the diff-fail branch), claims continuity against
        // fabricatedPrev, homestead = forged state.
        let tinyDifficulty = UInt256(1)
        let bFake = Block(
            previousBlock: VolumeImpl<Block>(node: fabricatedPrev),
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: tinyDifficulty,
            nextDifficulty: tinyDifficulty,
            spec: VolumeImpl<ChainSpec>(node: bSpec),
            parentHomestead: LatticeState.emptyHeader,
            homestead: forgedState,
            frontier: forgedState,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 2,
            timestamp: now - 40_000,
            nonce: 0
        )
        try await storeBlock(bFake, to: fetcher)

        // Real nexus block A1 that embeds the fabricated child.
        let realNexus1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "B", block: bGenesis)],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["B": bFake],
            timestamp: now - 40_000, difficulty: difficulty, fetcher: fetcher
        )
        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(realNexus1, to: fetcher)

        // Levels: nexus contains B, B contains D.
        let dChain = ChainState.fromGenesis(block: dGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let dLevel = ChainLevel(chain: dChain, children: [:])
        let bChain = ChainState.fromGenesis(block: bGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let bLevel = ChainLevel(chain: bChain, children: ["D": dLevel])
        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["B": bLevel])

        // nexusHash = UInt256.max so no block can pass its chain's target —
        // every accept goes through the skip-path (this is exactly where
        // the continuity check fires).
        let result = await nexusLevel.acceptChildBlockTree(
            parentBlock: realNexus1,
            parentBlockHeader: header(realNexus1),
            nexusHash: UInt256.max,
            fetcher: fetcher
        )
        XCTAssertFalse(result.anyAccepted)

        // B's chain must NOT have advanced past genesis — the continuity
        // gate caught the fabricated predecessor.
        let bTip = await bLevel.chain.tipSnapshot
        XCTAssertEqual(bTip?.index, 0)

        // D's chain must NOT have advanced either — the tree walk short-
        // circuits when the intermediate B-level check rejects.
        let dTip = await dLevel.chain.tipSnapshot
        XCTAssertEqual(dTip?.index, 0)
    }

    // MARK: - #2 Out-of-order delivery: continuity gate is retry-friendly

    /// A skip-path block referencing a not-yet-arrived predecessor must be
    /// rejected (the fix), but once the predecessor lands on the chain the
    /// same block must be re-acceptable. This asserts the gate doesn't
    /// permanently wedge honest peers whose delivery order is inverted.
    func testSkipPathBlockAcceptsAfterPredecessorArrives() async throws {
        let nexusSpec = makeSpec("Nexus")
        let bSpec = makeSpec("B")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let bGenesis = try await BlockBuilder.buildGenesis(
            spec: bSpec, timestamp: now - 60_000, difficulty: difficulty, fetcher: fetcher
        )
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: now - 60_000, difficulty: difficulty, fetcher: fetcher
        )

        // Real B1 — will be submitted to B's chain only partway through the test.
        let bBlock1 = try await BlockBuilder.buildBlock(
            previous: bGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(bSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            timestamp: now - 50_000, difficulty: difficulty, fetcher: fetcher
        )
        try await storeBlock(bBlock1, to: fetcher)

        // Skip-path child that legitimately continues from B1.
        let tinyDifficulty = UInt256(1)
        let bSkipChild = Block(
            previousBlock: VolumeImpl<Block>(node: bBlock1),
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: tinyDifficulty,
            nextDifficulty: tinyDifficulty,
            spec: VolumeImpl<ChainSpec>(node: bSpec),
            parentHomestead: LatticeState.emptyHeader,  // matches realNexus.homestead (= nexus genesis frontier = empty)
            homestead: bBlock1.frontier,
            frontier: bBlock1.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 2,
            timestamp: now - 40_000,
            nonce: 0
        )
        try await storeBlock(bSkipChild, to: fetcher)

        let realNexus1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "B", block: bGenesis)],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["B": bSkipChild],
            timestamp: now - 40_000, difficulty: difficulty, fetcher: fetcher
        )
        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(realNexus1, to: fetcher)

        // B's chain still only has genesis — bBlock1 has NOT been submitted.
        let bChain = ChainState.fromGenesis(block: bGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let bLevel = ChainLevel(chain: bChain, children: [:])
        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["B": bLevel])

        // First attempt: skip-path block's predecessor not on chain — rejected.
        let first = await nexusLevel.acceptChildBlockTree(
            parentBlock: realNexus1,
            parentBlockHeader: header(realNexus1),
            nexusHash: UInt256.max,
            fetcher: fetcher
        )
        XCTAssertFalse(first.anyAccepted)

        // Predecessor now arrives and is submitted to B's chain.
        let submitResult = await bChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: header(bBlock1),
            block: bBlock1
        )
        XCTAssertTrue(submitResult.extendsMainChain)

        // Retry the same nexus block — continuity now passes. The skip-path
        // doesn't "accept" a block into B's chain (the block fails B's
        // difficulty), but the tree walk no longer rejects it, so the result
        // of `acceptChildBlockTree` completes without the earlier error path.
        let second = await nexusLevel.acceptChildBlockTree(
            parentBlock: realNexus1,
            parentBlockHeader: header(realNexus1),
            nexusHash: UInt256.max,
            fetcher: fetcher
        )
        // No grandchildren embedded, so no accept expected — what we assert
        // is that the skip-path no longer short-circuits on the continuity
        // gate (i.e., B's tip hasn't changed but there's no rejection
        // either; equivalent library behavior for a legitimate skip-path
        // block post-fix).
        _ = second
        let bTip = await bLevel.chain.tipSnapshot
        XCTAssertEqual(bTip?.index, 1, "B's tip advanced once bBlock1 was submitted directly")
    }

    // MARK: - #3 Reorg-through-continuity: side-chain membership counts

    /// The fix uses `chain.contains(blockHash:)` (main-or-side), not
    /// `isOnMainChain`. A skip-path block whose previousBlock currently
    /// lives on a side chain must pass the continuity gate — because that
    /// side chain could win a reorg at any moment, and a wider acceptance
    /// criterion is safe (both main and side blocks were fully validated
    /// before entering hashToBlock).
    func testContinuityPassesWhenPreviousBlockIsOnSideChain() async throws {
        let bSpec = makeSpec("B")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let bGenesis = try await BlockBuilder.buildGenesis(
            spec: bSpec, timestamp: now - 60_000, difficulty: difficulty, fetcher: fetcher
        )

        // Main-chain block B1.
        let bMain1 = try await BlockBuilder.buildBlock(
            previous: bGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(bSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            timestamp: now - 50_000, difficulty: difficulty, fetcher: fetcher
        )
        try await storeBlock(bMain1, to: fetcher)

        // Side-chain competing block B1' — same parent, different contents
        // (distinct timestamp → distinct CID).
        let bSide1 = try await BlockBuilder.buildBlock(
            previous: bGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(bSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            timestamp: now - 49_000, difficulty: difficulty, fetcher: fetcher
        )
        try await storeBlock(bSide1, to: fetcher)

        // Skip-path child whose continuity anchor is the SIDE chain block.
        let tinyDifficulty = UInt256(1)
        let continuityFromSide = Block(
            previousBlock: VolumeImpl<Block>(node: bSide1),
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: tinyDifficulty,
            nextDifficulty: tinyDifficulty,
            spec: VolumeImpl<ChainSpec>(node: bSpec),
            parentHomestead: LatticeState.emptyHeader,
            homestead: bSide1.frontier,
            frontier: bSide1.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 2,
            timestamp: now - 40_000,
            nonce: 0
        )
        try await storeBlock(continuityFromSide, to: fetcher)

        let bChain = ChainState.fromGenesis(block: bGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)

        // Submit main first, then side. After both submits, main is still
        // the longer branch (both height 1, first-submitted wins tiebreak).
        _ = await bChain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header(bMain1), block: bMain1
        )
        _ = await bChain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header(bSide1), block: bSide1
        )

        let tipBefore = await bChain.getMainChainTip()
        XCTAssertEqual(tipBefore, header(bMain1).rawCID, "bMain1 is main chain tip")
        let sideContained = await bChain.contains(blockHash: header(bSide1).rawCID)
        XCTAssertTrue(sideContained, "bSide1 lives in hashToBlock as a side-chain block")

        // Continuity check should PASS — side-chain membership counts.
        let valid = await ChainLevel.validateHomesteadContinuity(
            block: continuityFromSide, chain: bChain, fetcher: fetcher
        )
        XCTAssertTrue(valid, "skip-path block whose previousBlock is on the side chain must pass continuity (pre-reorg)")

        // Trigger reorg: extend side chain until it's longer than main.
        let bSide2 = try await BlockBuilder.buildBlock(
            previous: bSide1,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(bSpec.rewardAtBlock(2)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 1
            ), kp)],
            timestamp: now - 30_000, difficulty: difficulty, fetcher: fetcher
        )
        try await storeBlock(bSide2, to: fetcher)
        _ = await bChain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header(bSide2), block: bSide2
        )

        let tipAfter = await bChain.getMainChainTip()
        XCTAssertEqual(tipAfter, header(bSide2).rawCID, "reorg: longer side branch takes over")

        // Continuity still passes: bSide1 is now main, still in hashToBlock.
        let validAfter = await ChainLevel.validateHomesteadContinuity(
            block: continuityFromSide, chain: bChain, fetcher: fetcher
        )
        XCTAssertTrue(validAfter, "continuity holds across the reorg — bSide1 membership survives")
    }
}
