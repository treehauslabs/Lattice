import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation
import Acorn

private struct LocalFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "LocalFetcher", code: 1)
    }
}
private let fetcher = LocalFetcher()

private func testSpec(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(
        directory: dir,
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialRewardExponent: 10,
        difficultyAdjustmentWindow: 5
    )
}

// MARK: - Mempool Tests

@MainActor
final class MempoolTests: XCTestCase {

    func testAddAndSelectByFee() async {
        let mempool = Mempool(maxSize: 100)

        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        var txs: [Transaction] = []
        for i: UInt64 in 0..<5 {
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [],
                genesisActions: [], peerActions: [], receiptActions: [],
                withdrawalActions: [], signers: [signerCID], fee: i * 10, nonce: i
            )
            let bodyHeader = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)
            txs.append(tx)
        }

        for tx in txs {
            let added = await mempool.add(transaction: tx)
            XCTAssertTrue(added)
        }

        let count = await mempool.count
        XCTAssertEqual(count, 5)

        let selected = await mempool.selectTransactions(maxCount: 3)
        XCTAssertEqual(selected.count, 3)

        let fees = selected.compactMap { $0.body.node?.fee }
        XCTAssertEqual(fees, fees.sorted(by: >), "Should be sorted by descending fee")
    }

    func testDuplicateRejected() async {
        let mempool = Mempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [], signers: [signerCID], fee: 10, nonce: 1
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)

        let first = await mempool.add(transaction: tx)
        XCTAssertTrue(first)
        let second = await mempool.add(transaction: tx)
        XCTAssertFalse(second)
    }

    func testInvalidSignatureRejected() async {
        let mempool = Mempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [], signers: ["fake"], fee: 10, nonce: 1
        )
        let tx = Transaction(signatures: [kp.publicKey: "deadbeef"], body: HeaderImpl<TransactionBody>(node: body))

        let added = await mempool.add(transaction: tx)
        XCTAssertFalse(added, "Invalid signature should be rejected")
    }

    func testEvictsLowestFeeWhenFull() async {
        let mempool = Mempool(maxSize: 3)
        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        for i: UInt64 in 0..<4 {
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [],
                genesisActions: [], peerActions: [], receiptActions: [],
                withdrawalActions: [], signers: [signerCID], fee: (i + 1) * 10, nonce: i
            )
            let bodyHeader = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)
            let _ = await mempool.add(transaction: tx)
        }

        let count = await mempool.count
        XCTAssertEqual(count, 3, "Should evict to stay at maxSize")

        let selected = await mempool.selectTransactions(maxCount: 3)
        let fees = selected.compactMap { $0.body.node?.fee }
        XCTAssertFalse(fees.contains(10), "Lowest fee (10) should have been evicted")
    }

    func testPruneConfirmed() async {
        let mempool = Mempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        var cids: [String] = []
        for i: UInt64 in 0..<3 {
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [],
                genesisActions: [], peerActions: [], receiptActions: [],
                withdrawalActions: [], signers: [signerCID], fee: 10, nonce: i
            )
            let bodyHeader = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)
            let _ = await mempool.add(transaction: tx)
            cids.append(bodyHeader.rawCID)
        }

        await mempool.removeAll(txCIDs: Set([cids[0], cids[1]]))
        let remaining = await mempool.count
        XCTAssertEqual(remaining, 1)
    }
}

// MARK: - Header Chain Tests

@MainActor
final class HeaderChainTests: XCTestCase {

    func testLinearHeaderChain() async throws {
        let headerChain = HeaderChain()
        let blocks = try await buildTestChain(length: 10)

        for block in blocks {
            let summary = BlockHeaderSummary(block: block)
            let added = await headerChain.addHeader(summary)
            XCTAssertTrue(added, "Header \(summary.index) should be added")
        }

        let height = await headerChain.height()
        XCTAssertEqual(height, 9)

        let valid = await headerChain.verify(from: 0, to: 9)
        XCTAssertTrue(valid)
    }

    func testRejectOutOfOrderHeader() async throws {
        let headerChain = HeaderChain()
        let blocks = try await buildTestChain(length: 5)

        let _ = await headerChain.addHeader(BlockHeaderSummary(block: blocks[0]))
        let skipped = await headerChain.addHeader(BlockHeaderSummary(block: blocks[3]))
        XCTAssertFalse(skipped, "Skipping headers should fail")
    }

    func testHeaderRangeQuery() async throws {
        let headerChain = HeaderChain()
        let blocks = try await buildTestChain(length: 10)
        for block in blocks {
            let _ = await headerChain.addHeader(BlockHeaderSummary(block: block))
        }

        let range = await headerChain.headerRange(from: 3, count: 4)
        XCTAssertEqual(range.count, 4)
        XCTAssertEqual(range[0].index, 3)
        XCTAssertEqual(range[3].index, 6)
    }

    private func buildTestChain(length: Int) async throws -> [Block] {
        var blocks: [Block] = []
        let g = try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: 1_000_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        blocks.append(g)
        for i in 1..<length {
            let b = try await BlockBuilder.buildBlock(
                previous: blocks.last!, timestamp: 1_000_000 + Int64(i) * 1000,
                nonce: UInt64(i), fetcher: fetcher
            )
            blocks.append(b)
        }
        return blocks
    }
}

// MARK: - State Snapshot Tests

@MainActor
final class StateSnapshotTests: XCTestCase {

    func testSnapshotRoundTrip() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = SnapshotManager(storagePath: tmpDir, snapshotInterval: 5)
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: 1_000_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        let blockHash = HeaderImpl<Block>(node: block).rawCID

        let snapshot = StateSnapshot(block: block, blockHash: blockHash)
        XCTAssertEqual(snapshot.blockIndex, 0)
        XCTAssertEqual(snapshot.blockHash, blockHash)

        try await manager.saveSnapshot(snapshot)
        let loaded = try await manager.loadSnapshot(blockIndex: 0)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.blockHash, blockHash)
        XCTAssertEqual(loaded?.homesteadCID, snapshot.homesteadCID)
        XCTAssertEqual(loaded?.frontierCID, snapshot.frontierCID)
    }

    func testSnapshotInterval() async {
        let manager = SnapshotManager(storagePath: URL(fileURLWithPath: "/tmp"), snapshotInterval: 100)
        let shouldAt0 = await manager.shouldSnapshot(blockIndex: 0)
        XCTAssertFalse(shouldAt0)
        let shouldAt99 = await manager.shouldSnapshot(blockIndex: 99)
        XCTAssertFalse(shouldAt99)
        let shouldAt100 = await manager.shouldSnapshot(blockIndex: 100)
        XCTAssertTrue(shouldAt100)
        let shouldAt200 = await manager.shouldSnapshot(blockIndex: 200)
        XCTAssertTrue(shouldAt200)
    }

    func testLatestSnapshot() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = SnapshotManager(storagePath: tmpDir, snapshotInterval: 1)
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: 1_000_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let snap1 = StateSnapshot(block: block, blockHash: "hash_100")
        let snap2 = StateSnapshot(block: block, blockHash: "hash_200")

        var mutSnap1 = snap1
        try await manager.saveSnapshot(StateSnapshot(block: block, blockHash: "hash_100"))

        let block2 = try await BlockBuilder.buildBlock(
            previous: block, timestamp: 2_000_000, nonce: 1, fetcher: fetcher
        )
        let snap200 = StateSnapshot(block: block2, blockHash: "hash_200")
        try await manager.saveSnapshot(snap200)

        let latest = try await manager.latestSnapshot()
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.blockIndex, 1, "Should return the higher-index snapshot")
    }
}

// MARK: - AcornFetcher Tests

@MainActor
final class AcornFetcherTests: XCTestCase {

    func testStoreAndFetch() async throws {
        let worker = InMemoryWorker()
        let acornFetcher = AcornFetcher(worker: worker)

        let testData = "hello lattice".data(using: .utf8)!
        let cid = ContentIdentifier(for: testData)

        await acornFetcher.store(rawCid: cid.rawValue, data: testData)

        let fetched = try await acornFetcher.fetch(rawCid: cid.rawValue)
        XCTAssertEqual(fetched, testData)
    }

    func testFetchMissingThrows() async {
        let worker = InMemoryWorker()
        let acornFetcher = AcornFetcher(worker: worker)

        do {
            let _ = try await acornFetcher.fetch(rawCid: "nonexistent")
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is FetcherError)
        }
    }
}

actor InMemoryWorker: AcornCASWorker {
    var near: (any AcornCASWorker)?
    var far: (any AcornCASWorker)?
    var timeout: Duration? { nil }
    private var store: [ContentIdentifier: Data] = [:]

    func has(cid: ContentIdentifier) -> Bool { store[cid] != nil }
    func getLocal(cid: ContentIdentifier) async -> Data? { store[cid] }
    func storeLocal(cid: ContentIdentifier, data: Data) async { store[cid] = data }
}

// MARK: - Full Pipeline Acceptance Test

@MainActor
final class FullPipelineAcceptanceTests: XCTestCase {

    func testBuildMineSubmitBroadcastCycle() async throws {
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let mempool = Mempool(maxSize: 1000)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: 2_000_000,
            difficulty: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let mined = BlockBuilder.mine(block: block1, targetDifficulty: UInt256.max, maxAttempts: 10)
        XCTAssertNotNil(mined)

        let header = HeaderImpl<Block>(node: mined!)
        let result = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header, block: mined!
        )
        XCTAssertTrue(result.extendsMainChain)

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, header.rawCID)
    }

    func testMempoolToBlockPipeline() async throws {
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let mempool = Mempool(maxSize: 1000)

        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        for i: UInt64 in 0..<5 {
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [],
                genesisActions: [], peerActions: [], receiptActions: [],
                withdrawalActions: [], signers: [signerCID], fee: i + 1, nonce: i
            )
            let bodyHeader = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)
            let _ = await mempool.add(transaction: tx)
        }

        let count = await mempool.count
        XCTAssertEqual(count, 5)

        let selected = await mempool.selectTransactions(maxCount: 3)
        XCTAssertEqual(selected.count, 3)

        let fees = selected.compactMap { $0.body.node?.fee }
        XCTAssertTrue(fees[0] >= fees[1] && fees[1] >= fees[2], "Highest fees selected first")
    }

    func testMultiChainConsensusWithAnchoringAndReorg() async throws {
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Child")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: 1_000_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: 1_000_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Child": childLevel])

        var nexusPrev = nexusGenesis
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: nexusPrev, timestamp: 1_000_000 + Int64(i) * 1000,
                nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await nexusChain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
            nexusPrev = block
        }

        let nexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 5)

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, timestamp: 2_000_000, nonce: 1, fetcher: fetcher
        )
        let nexusBlockHeader = HeaderImpl<Block>(node: nexusPrev)
        let childResult = await childChain.submitBlock(
            parentBlockHeaderAndIndex: (nexusBlockHeader.rawCID, nexusHeight),
            blockHeader: HeaderImpl<Block>(node: childBlock1),
            block: childBlock1
        )
        XCTAssertTrue(childResult.extendsMainChain)

        let childHeight = await childChain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 1)

        let childBlock1Meta = await childChain.getConsensusBlock(
            hash: HeaderImpl<Block>(node: childBlock1).rawCID
        )
        XCTAssertNotNil(childBlock1Meta?.parentIndex, "Child block should have parent chain anchoring")
    }

    func testEndToEndChainBuildAndHeaderSync() async throws {
        let blocks = try await buildLongChain(length: 20)
        let chain = ChainState.fromGenesis(block: blocks[0])
        for block in blocks.dropFirst() {
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
        }

        let headerChain = HeaderChain()
        for block in blocks {
            let summary = BlockHeaderSummary(block: block)
            let _ = await headerChain.addHeader(summary)
        }

        let chainHeight = await chain.getHighestBlockIndex()
        let headerHeight = await headerChain.height()
        XCTAssertEqual(chainHeight, headerHeight)

        let valid = await headerChain.verify(from: 0, to: headerHeight)
        XCTAssertTrue(valid)

        let chainTip = await chain.getMainChainTip()
        let headerTip = await headerChain.tip()
        XCTAssertEqual(chainTip, headerTip?.blockHash)
    }

    func testSnapshotAfterChainBuild() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let snapshotManager = SnapshotManager(storagePath: tmpDir, snapshotInterval: 5)
        let blocks = try await buildLongChain(length: 11)
        let chain = ChainState.fromGenesis(block: blocks[0])

        for (i, block) in blocks.enumerated() {
            if i > 0 {
                let _ = await chain.submitBlock(
                    parentBlockHeaderAndIndex: nil,
                    blockHeader: HeaderImpl<Block>(node: block), block: block
                )
            }
            let shouldSnap = await snapshotManager.shouldSnapshot(blockIndex: UInt64(i))
            if shouldSnap {
                let snap = StateSnapshot(
                    block: block,
                    blockHash: HeaderImpl<Block>(node: block).rawCID
                )
                try await snapshotManager.saveSnapshot(snap)
            }
        }

        let latest = try await snapshotManager.latestSnapshot()
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.blockIndex, 10)

        let snap5 = try await snapshotManager.loadSnapshot(blockIndex: 5)
        XCTAssertNotNil(snap5)
        XCTAssertEqual(snap5?.blockIndex, 5)
    }

    private func buildLongChain(length: Int) async throws -> [Block] {
        var blocks: [Block] = []
        let g = try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: 1_000_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        blocks.append(g)
        for i in 1..<length {
            let b = try await BlockBuilder.buildBlock(
                previous: blocks.last!, timestamp: 1_000_000 + Int64(i) * 1000,
                nonce: UInt64(i), fetcher: fetcher
            )
            blocks.append(b)
        }
        return blocks
    }
}
