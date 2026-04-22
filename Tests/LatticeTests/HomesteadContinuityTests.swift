import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// MARK: - Helpers

private let difficulty = UInt256(1000)

private func makeSpec(_ dir: String = "Nexus", premine: UInt64 = 0) -> ChainSpec {
    ChainSpec(directory: dir, maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
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

/// Tests covering `ChainLevel.validateHomesteadContinuity`, the cheap check
/// used when a block fails its chain's PoW target. The only property that
/// matters for tree-walk safety is that the block's own homestead is real
/// (came from its previous block's frontier), so grandchildren anchoring
/// `parentHomestead` against this homestead can trust it.
@MainActor
final class HomesteadContinuityTests: XCTestCase {

    // MARK: - Genesis (previousBlock == nil)

    func testGenesisValidPasses() async throws {
        let childSpec = makeSpec("Payments")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let genesis = Block(
            previousBlock: nil,
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: HeaderImpl<ChainSpec>(node: childSpec),
            parentHomestead: LatticeState.emptyHeader,
            homestead: LatticeState.emptyHeader,
            frontier: LatticeState.emptyHeader,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 0,
            timestamp: now,
            nonce: 0
        )
        try await storeBlock(genesis, to: fetcher)

        let valid = await ChainLevel.validateHomesteadContinuity(block: genesis, fetcher: fetcher)
        XCTAssertTrue(valid)
    }

    func testGenesisWithNonZeroIndexRejected() async throws {
        let childSpec = makeSpec("Payments")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let forged = Block(
            previousBlock: nil,
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: HeaderImpl<ChainSpec>(node: childSpec),
            parentHomestead: LatticeState.emptyHeader,
            homestead: LatticeState.emptyHeader,
            frontier: LatticeState.emptyHeader,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 7, // WRONG: genesis must be index 0
            timestamp: now,
            nonce: 0
        )
        try await storeBlock(forged, to: fetcher)

        let valid = await ChainLevel.validateHomesteadContinuity(block: forged, fetcher: fetcher)
        XCTAssertFalse(valid)
    }

    func testGenesisWithNonEmptyHomesteadRejected() async throws {
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        // Build a real non-empty state root to use as a fake homestead.
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: now - 30_000, difficulty: difficulty, fetcher: fetcher
        )
        let ts1 = now - 20_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                peerActions: [], receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        let forged = Block(
            previousBlock: nil,
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: HeaderImpl<ChainSpec>(node: childSpec),
            parentHomestead: LatticeState.emptyHeader,
            homestead: nexusBlock1.frontier, // WRONG: genesis must have empty homestead
            frontier: nexusBlock1.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 0,
            timestamp: now,
            nonce: 0
        )
        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(forged, to: fetcher)

        let valid = await ChainLevel.validateHomesteadContinuity(block: forged, fetcher: fetcher)
        XCTAssertFalse(valid)
    }

    // MARK: - Non-genesis (previousBlock != nil)

    func testNonGenesisValidPasses() async throws {
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: now - 40_000, difficulty: difficulty, fetcher: fetcher
        )
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: now - 40_000, difficulty: difficulty, fetcher: fetcher
        )

        let ts1 = now - 30_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "Payments", block: childGenesis)],
                peerActions: [], receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["Payments": childGenesis],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                peerActions: [], receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            parentChainBlock: nexusBlock1,
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(childGenesis, to: fetcher)
        try await storeBlock(childBlock1, to: fetcher)

        let valid = await ChainLevel.validateHomesteadContinuity(block: childBlock1, fetcher: fetcher)
        XCTAssertTrue(valid)
    }

    func testNonGenesisForgedHomesteadRejected() async throws {
        // Block claims a homestead that doesn't match its previous block's
        // frontier — the critical case, since grandchildren would anchor
        // against this fabricated state.
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: now - 50_000, difficulty: difficulty, fetcher: fetcher
        )
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: now - 50_000, difficulty: difficulty, fetcher: fetcher
        )
        let ts1 = now - 40_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "Payments", block: childGenesis)],
                peerActions: [], receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["Payments": childGenesis],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        let realChildBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                peerActions: [], receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            parentChainBlock: nexusBlock1,
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        let ts2 = now - 30_000
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(2)))],
                actions: [], depositActions: [], genesisActions: [],
                peerActions: [], receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 1
            ), kp)],
            timestamp: ts2, difficulty: difficulty, fetcher: fetcher
        )

        let forged = Block(
            previousBlock: VolumeImpl<Block>(node: realChildBlock1),
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: HeaderImpl<ChainSpec>(node: childSpec),
            parentHomestead: nexusBlock2.homestead,
            homestead: childGenesis.frontier, // WRONG: should equal realChildBlock1.frontier
            frontier: childGenesis.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 2,
            timestamp: ts2,
            nonce: 0
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(nexusBlock2, to: fetcher)
        try await storeBlock(childGenesis, to: fetcher)
        try await storeBlock(realChildBlock1, to: fetcher)
        try await storeBlock(forged, to: fetcher)

        let valid = await ChainLevel.validateHomesteadContinuity(block: forged, fetcher: fetcher)
        XCTAssertFalse(valid)
    }

    func testNonGenesisParentHomesteadIgnoredByHelper() async throws {
        // The helper itself only covers previous.frontier → homestead continuity.
        // The cross-chain parentHomestead check lives alongside the helper call
        // in acceptChildBlockTree (see testDiffFailingChildWithForgedParentHomesteadRejected).
        let childSpec = makeSpec("Payments")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: now - 40_000, difficulty: difficulty, fetcher: fetcher
        )

        // parentHomestead is deliberately bogus; continuity is still correct.
        let weirdChild = Block(
            previousBlock: VolumeImpl<Block>(node: childGenesis),
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: HeaderImpl<ChainSpec>(node: childSpec),
            parentHomestead: LatticeState.emptyHeader,
            homestead: childGenesis.frontier,
            frontier: childGenesis.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 1,
            timestamp: now - 30_000,
            nonce: 0
        )
        try await storeBlock(childGenesis, to: fetcher)
        try await storeBlock(weirdChild, to: fetcher)

        let valid = await ChainLevel.validateHomesteadContinuity(block: weirdChild, fetcher: fetcher)
        XCTAssertTrue(valid)
    }

    // MARK: - Integration: acceptChildBlockTree catches forged parentHomestead on diff-fail path

    /// Even though validateHomesteadContinuity is agnostic to parentHomestead,
    /// acceptChildBlockTree adds an inline check so a structurally malformed
    /// child block gets rejected before its subtree is walked.
    func testDiffFailingChildWithForgedParentHomesteadRejected() async throws {
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: now - 40_000, difficulty: difficulty, fetcher: fetcher
        )
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: now - 40_000, difficulty: difficulty, fetcher: fetcher
        )
        let ts1 = now - 30_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "Payments", block: childGenesis)],
                peerActions: [], receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["Payments": childGenesis],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        // Child block with forged parentHomestead (empty, not nexusBlock1.homestead).
        // Continuity IS correct. Use a tiny difficulty so the block fails PoW.
        let tinyDifficulty = UInt256(1)
        let forgedChild = Block(
            previousBlock: VolumeImpl<Block>(node: childGenesis),
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: tinyDifficulty,
            nextDifficulty: tinyDifficulty,
            spec: HeaderImpl<ChainSpec>(node: childSpec),
            parentHomestead: LatticeState.emptyHeader, // FORGED
            homestead: childGenesis.frontier,
            frontier: childGenesis.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 1,
            timestamp: ts1,
            nonce: 0
        )

        // Rebuild nexusBlock1 with this forged child in its childBlocks dict.
        let parentWithForgedChild = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "Payments", block: childGenesis)],
                peerActions: [], receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["Payments": forgedChild],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(parentWithForgedChild, to: fetcher)
        try await storeBlock(childGenesis, to: fetcher)
        try await storeBlock(forgedChild, to: fetcher)

        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        // nexusHash = UInt256.max guarantees the child's PoW cannot meet
        // its target (any difficulty < max → diff-fail branch).
        let result = await nexusLevel.acceptChildBlockTree(
            parentBlock: parentWithForgedChild,
            parentBlockHeader: VolumeImpl<Block>(node: parentWithForgedChild),
            nexusHash: UInt256.max,
            fetcher: fetcher
        )
        XCTAssertFalse(result.anyAccepted)

        // Child chain should NOT have advanced past its genesis.
        let childTip = await childLevel.chain.tipSnapshot
        XCTAssertEqual(childTip?.index, 0, "Forged diff-fail child must not advance the child chain")
    }
}
