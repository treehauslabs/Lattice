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

/// Tests covering `ChainLevel.validateChildHomesteadLinkage`, the cheap check used
/// when a block fails its chain's PoW target. A grandchild block's `parentHomestead`
/// references this block's homestead; if we accepted a forged homestead just because
/// PoW failed, withdrawals processed by grandchildren could reference fabricated
/// state. The helper must catch all forgery shapes without running full validation.
@MainActor
final class ChildHomesteadLinkageTests: XCTestCase {

    // MARK: - Genesis (previousBlock == nil)

    func testGenesisChildValidPasses() async throws {
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

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

        let childGenesis = Block(
            previousBlock: nil,
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: HeaderImpl<ChainSpec>(node: childSpec),
            parentHomestead: nexusBlock1.homestead,
            homestead: LatticeState.emptyHeader,
            frontier: LatticeState.emptyHeader,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 0,
            timestamp: ts1,
            nonce: 0
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(childGenesis, to: fetcher)

        let valid = await ChainLevel.validateChildHomesteadLinkage(
            childBlock: childGenesis, parentBlock: nexusBlock1, fetcher: fetcher
        )
        XCTAssertTrue(valid)
    }

    func testGenesisChildForgedParentHomesteadRejected() async throws {
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: now - 40_000, difficulty: difficulty, fetcher: fetcher
        )
        let ts1 = now - 30_000
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
        let ts2 = now - 20_000
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
            previousBlock: nil,
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: HeaderImpl<ChainSpec>(node: childSpec),
            parentHomestead: nexusBlock1.homestead, // WRONG: should be nexusBlock2.homestead
            homestead: LatticeState.emptyHeader,
            frontier: LatticeState.emptyHeader,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 0,
            timestamp: ts2,
            nonce: 0
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(nexusBlock2, to: fetcher)
        try await storeBlock(forged, to: fetcher)

        let valid = await ChainLevel.validateChildHomesteadLinkage(
            childBlock: forged, parentBlock: nexusBlock2, fetcher: fetcher
        )
        XCTAssertFalse(valid)
    }

    func testGenesisChildWithNonZeroIndexRejected() async throws {
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

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
            parentHomestead: nexusBlock1.homestead,
            homestead: LatticeState.emptyHeader,
            frontier: LatticeState.emptyHeader,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 7, // WRONG: genesis must be index 0
            timestamp: ts1,
            nonce: 0
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(forged, to: fetcher)

        let valid = await ChainLevel.validateChildHomesteadLinkage(
            childBlock: forged, parentBlock: nexusBlock1, fetcher: fetcher
        )
        XCTAssertFalse(valid)
    }

    func testGenesisChildWithNonEmptyHomesteadRejected() async throws {
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

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

        // Forged genesis: claims a non-empty homestead so withdrawals could reference
        // any fabricated balance state.
        let forged = Block(
            previousBlock: nil,
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: HeaderImpl<ChainSpec>(node: childSpec),
            parentHomestead: nexusBlock1.homestead,
            homestead: nexusBlock1.frontier, // WRONG: genesis must have empty homestead
            frontier: nexusBlock1.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 0,
            timestamp: ts1,
            nonce: 0
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(forged, to: fetcher)

        let valid = await ChainLevel.validateChildHomesteadLinkage(
            childBlock: forged, parentBlock: nexusBlock1, fetcher: fetcher
        )
        XCTAssertFalse(valid)
    }

    // MARK: - Non-genesis (previousBlock != nil)

    func testNonGenesisChildValidPasses() async throws {
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

        let valid = await ChainLevel.validateChildHomesteadLinkage(
            childBlock: childBlock1, parentBlock: nexusBlock1, fetcher: fetcher
        )
        XCTAssertTrue(valid)
    }

    func testNonGenesisChildForgedParentHomesteadRejected() async throws {
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

        // Tampered: parentHomestead points at the older nexus block.
        let forged = Block(
            previousBlock: VolumeImpl<Block>(node: childGenesis),
            transactions: BlockBuilder.buildTransactionsDictionary([sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                peerActions: [], receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: HeaderImpl<ChainSpec>(node: childSpec),
            parentHomestead: nexusBlock1.homestead, // WRONG: should be nexusBlock2.homestead
            homestead: childGenesis.frontier,
            frontier: childGenesis.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 1,
            timestamp: ts2,
            nonce: 0
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(nexusBlock2, to: fetcher)
        try await storeBlock(childGenesis, to: fetcher)
        try await storeBlock(forged, to: fetcher)

        let valid = await ChainLevel.validateChildHomesteadLinkage(
            childBlock: forged, parentBlock: nexusBlock2, fetcher: fetcher
        )
        XCTAssertFalse(valid)
    }

    func testNonGenesisChildForgedHomesteadRejected() async throws {
        // The child claims a homestead that doesn't match its previous block's
        // frontier. Without this check, it could fabricate balance state for
        // grandchild withdrawals to reference.
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

        // Real previous child block we'll reference but lie about what its frontier is.
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

        let valid = await ChainLevel.validateChildHomesteadLinkage(
            childBlock: forged, parentBlock: nexusBlock2, fetcher: fetcher
        )
        XCTAssertFalse(valid)
    }

}
