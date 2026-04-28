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

// MARK: - Tests

@MainActor
final class ChildBlockParentHomesteadTests: XCTestCase {

    // MARK: - Positive: valid non-genesis child block passes

    func testValidNonGenesisChildBlockPasses() async throws {
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

        // Nexus block 1: embed child genesis
        let ts1 = now - 30_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "Payments", block: childGenesis)],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["Payments": childGenesis],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        // Child block 1: extends child genesis, parent is nexusBlock1
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0  // nonce 0 on child chain
            ), kp)],
            parentChainBlock: nexusBlock1,
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(childGenesis, to: fetcher)
        try await storeBlock(childBlock1, to: fetcher)

        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let valid = await childLevel.validateChildBlock(
            childBlock: childBlock1,
            parentBlock: nexusBlock1,
            ancestorSpecs: [nexusSpec],
            chainPath: ["Nexus", "Payments"],
            fetcher: fetcher
        )
        XCTAssertTrue(valid, "Correctly built non-genesis child block should pass validation")
    }

    // MARK: - parentHomestead mismatch for non-genesis child

    func testNonGenesisChildWithWrongParentHomesteadRejected() async throws {
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

        // Nexus block 1: coinbase (advances nexus state)
        let ts1 = now - 40_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "Payments", block: childGenesis)],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["Payments": childGenesis],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        // Nexus block 2: coinbase (further advances nexus state)
        let ts2 = now - 30_000
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(2)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 1
            ), kp)],
            timestamp: ts2, difficulty: difficulty, fetcher: fetcher
        )

        // Tampered child block: references nexusBlock1.homestead instead of nexusBlock2.homestead
        let tamperedChild = Block(
            previousBlock: VolumeImpl<Block>(node: childGenesis),
            transactions: BlockBuilder.buildTransactionsDictionary([sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: VolumeImpl<ChainSpec>(node: childSpec),
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
        try await storeBlock(tamperedChild, to: fetcher)

        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let valid = await childLevel.validateChildBlock(
            childBlock: tamperedChild,
            parentBlock: nexusBlock2,
            ancestorSpecs: [nexusSpec],
            chainPath: ["Nexus", "Payments"],
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Non-genesis child with wrong parentHomestead must be rejected")
    }

    func testNonGenesisChildWithEmptyParentHomesteadRejected() async throws {
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

        // Nexus block 1 with transactions (so homestead != empty)
        let ts1 = now - 30_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "Payments", block: childGenesis)],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["Payments": childGenesis],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        // Tampered child: empty parentHomestead instead of nexusBlock1.homestead
        let tamperedChild = Block(
            previousBlock: VolumeImpl<Block>(node: childGenesis),
            transactions: BlockBuilder.buildTransactionsDictionary([sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: VolumeImpl<ChainSpec>(node: childSpec),
            parentHomestead: LatticeState.emptyHeader, // WRONG: empty instead of nexusBlock1.homestead
            homestead: childGenesis.frontier,
            frontier: childGenesis.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 1,
            timestamp: ts1,
            nonce: 0
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(childGenesis, to: fetcher)
        try await storeBlock(tamperedChild, to: fetcher)

        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let valid = await childLevel.validateChildBlock(
            childBlock: tamperedChild,
            parentBlock: nexusBlock1,
            ancestorSpecs: [nexusSpec],
            chainPath: ["Nexus", "Payments"],
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Non-genesis child with empty parentHomestead must be rejected")
    }

    // MARK: - Timestamp mismatch

    func testChildBlockWithWrongTimestampRejected() async throws {
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
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["Payments": childGenesis],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        // Tampered child: wrong timestamp
        let wrongTimestamp = ts1 - 5_000
        let tamperedChild = Block(
            previousBlock: VolumeImpl<Block>(node: childGenesis),
            transactions: BlockBuilder.buildTransactionsDictionary([sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: VolumeImpl<ChainSpec>(node: childSpec),
            parentHomestead: nexusBlock1.homestead,
            homestead: childGenesis.frontier,
            frontier: childGenesis.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 1,
            timestamp: wrongTimestamp, // WRONG: doesn't match parent
            nonce: 0
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(childGenesis, to: fetcher)
        try await storeBlock(tamperedChild, to: fetcher)

        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let valid = await childLevel.validateChildBlock(
            childBlock: tamperedChild,
            parentBlock: nexusBlock1,
            ancestorSpecs: [nexusSpec],
            chainPath: ["Nexus", "Payments"],
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Child block with timestamp != parent timestamp must be rejected")
    }

    // MARK: - Genesis child block checks

    func testGenesisChildWithWrongParentHomesteadRejected() async throws {
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: now - 50_000, difficulty: difficulty, fetcher: fetcher
        )

        // Nexus block 1: coinbase (advances state from empty)
        let ts1 = now - 40_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        // Nexus block 2: coinbase (further advances state, so block2.homestead != block1.homestead)
        let ts2 = now - 30_000
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(2)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 1
            ), kp)],
            timestamp: ts2, difficulty: difficulty, fetcher: fetcher
        )

        // Genesis child referencing nexusBlock1.homestead, but parent is nexusBlock2
        // nexusBlock2.homestead = nexusBlock1.frontier (has block1 reward applied)
        // nexusBlock1.homestead = nexusGenesis.frontier (empty)
        // These differ because nexusBlock1 had transactions
        let tamperedGenesis = Block(
            previousBlock: nil,
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: VolumeImpl<ChainSpec>(node: childSpec),
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
        try await storeBlock(tamperedGenesis, to: fetcher)

        let childChain = ChainState.fromGenesis(block: tamperedGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let valid = await childLevel.validateChildBlock(
            childBlock: tamperedGenesis,
            parentBlock: nexusBlock2,
            ancestorSpecs: [nexusSpec],
            chainPath: ["Nexus", "Payments"],
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Genesis child with wrong parentHomestead must be rejected")
    }

    func testGenesisChildTimestampMismatchRejected() async throws {
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
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        // Genesis child with wrong timestamp
        let tamperedGenesis = Block(
            previousBlock: nil,
            transactions: BlockBuilder.buildTransactionsDictionary([]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: VolumeImpl<ChainSpec>(node: childSpec),
            parentHomestead: nexusBlock1.homestead,
            homestead: LatticeState.emptyHeader,
            frontier: LatticeState.emptyHeader,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 0,
            timestamp: ts1 - 5_000, // WRONG: doesn't match parent
            nonce: 0
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(tamperedGenesis, to: fetcher)

        let childChain = ChainState.fromGenesis(block: tamperedGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let valid = await childLevel.validateChildBlock(
            childBlock: tamperedGenesis,
            parentBlock: nexusBlock1,
            ancestorSpecs: [nexusSpec],
            chainPath: ["Nexus", "Payments"],
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Genesis child with timestamp != parent timestamp must be rejected")
    }

    // MARK: - Stale parent homestead (previous parent, not current)

    func testNonGenesisChildWithStaleParentHomesteadRejected() async throws {
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

        // Nexus block 1
        let ts1 = now - 40_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "Payments", block: childGenesis)],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            childBlocks: ["Payments": childGenesis],
            timestamp: ts1, difficulty: difficulty, fetcher: fetcher
        )

        // Nexus block 2
        let ts2 = now - 30_000
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(2)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 1
            ), kp)],
            timestamp: ts2, difficulty: difficulty, fetcher: fetcher
        )

        // Nexus block 3 (further advances state)
        let ts3 = now - 20_000
        let nexusBlock3 = try await BlockBuilder.buildBlock(
            previous: nexusBlock2,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(3)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 2
            ), kp)],
            timestamp: ts3, difficulty: difficulty, fetcher: fetcher
        )

        // Child block 1 correctly built against nexusBlock2
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0  // nonce 0 on child chain
            ), kp)],
            parentChainBlock: nexusBlock2,
            timestamp: ts2, difficulty: difficulty, fetcher: fetcher
        )

        // Child block 2 tampered: references nexusBlock2.homestead (stale) but parent is nexusBlock3
        let tamperedChild2 = Block(
            previousBlock: VolumeImpl<Block>(node: childBlock1),
            transactions: BlockBuilder.buildTransactionsDictionary([sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.rewardAtBlock(2)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 1  // nonce 1 on child chain
            ), kp)]),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: VolumeImpl<ChainSpec>(node: childSpec),
            parentHomestead: nexusBlock2.homestead, // STALE: should be nexusBlock3.homestead
            homestead: childBlock1.frontier,
            frontier: childBlock1.frontier,
            childBlocks: BlockBuilder.buildChildBlocksDictionary([:]),
            index: 2,
            timestamp: ts3,
            nonce: 0
        )

        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(nexusBlock2, to: fetcher)
        try await storeBlock(nexusBlock3, to: fetcher)
        try await storeBlock(childGenesis, to: fetcher)
        try await storeBlock(childBlock1, to: fetcher)
        try await storeBlock(tamperedChild2, to: fetcher)

        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: RECENT_BLOCK_DISTANCE)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let valid = await childLevel.validateChildBlock(
            childBlock: tamperedChild2,
            parentBlock: nexusBlock3,
            ancestorSpecs: [nexusSpec],
            chainPath: ["Nexus", "Payments"],
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Non-genesis child referencing stale parent homestead must be rejected")
    }
}
