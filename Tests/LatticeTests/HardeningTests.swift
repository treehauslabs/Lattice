import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation
import Acorn
import Ivy
import Tally
import NIOPosix

private struct LocalFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw FetcherError.notFound(rawCid)
    }
}
private let fetcher = LocalFetcher()

private func hardeningSpec() -> ChainSpec {
    ChainSpec(
        directory: "Nexus",
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialRewardExponent: 10
    )
}

// MARK: - #1: Chain State Persistence Tests

@MainActor
final class ChainStatePersistenceTests: XCTestCase {

    func testPersistAndRestore() async throws {
        let genesisConfig = GenesisConfig.standard(spec: hardeningSpec())
        let genesis = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)

        var prev = genesis.block
        for i in 1...10 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: Int64(i) * 1000,
                difficulty: UInt256.max, nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await genesis.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl(node: block), block: block
            )
            prev = block
        }

        let tipBefore = await genesis.chainState.getMainChainTip()
        let heightBefore = await genesis.chainState.getHighestBlockIndex()
        XCTAssertEqual(heightBefore, 10)

        let persisted = await genesis.chainState.persist()

        let restored = ChainState.restore(from: persisted)
        let tipAfter = await restored.getMainChainTip()
        let heightAfter = await restored.getHighestBlockIndex()

        XCTAssertEqual(tipBefore, tipAfter, "Tip must survive persist/restore")
        XCTAssertEqual(heightBefore, heightAfter, "Height must survive persist/restore")

        let genesisOnMain = await restored.isOnMainChain(hash: genesis.blockHash)
        XCTAssertTrue(genesisOnMain, "Genesis must be on main chain after restore")
    }

    func testPersistToDiskAndLoad() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let persister = ChainStatePersister(storagePath: tmpDir, directory: "Nexus")

        let genesisConfig = GenesisConfig.standard(spec: hardeningSpec())
        let genesis = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis.block, timestamp: 1_000,
            difficulty: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let _ = await genesis.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl(node: block1), block: block1
        )

        let state = await genesis.chainState.persist()
        try await persister.save(state)

        let loaded = try await persister.load()
        XCTAssertNotNil(loaded)

        let restored = ChainState.restore(from: loaded!)
        let tip = await restored.getMainChainTip()
        XCTAssertEqual(tip, HeaderImpl<Block>(node: block1).rawCID)
    }

    func testRestorePreservesBlockMetadata() async throws {
        let genesisConfig = GenesisConfig.standard(spec: hardeningSpec())
        let genesis = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis.block, timestamp: 1_000,
            difficulty: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let _ = await genesis.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl(node: block1), block: block1
        )

        let persisted = await genesis.chainState.persist()
        let restored = ChainState.restore(from: persisted)

        let block1Hash = HeaderImpl<Block>(node: block1).rawCID
        let meta = await restored.getConsensusBlock(hash: block1Hash)
        XCTAssertNotNil(meta)
        XCTAssertEqual(meta?.blockIndex, 1)
        XCTAssertEqual(meta?.previousBlockHash, genesis.blockHash)
    }

    func testRestoredChainAcceptsNewBlocks() async throws {
        let genesisConfig = GenesisConfig.standard(spec: hardeningSpec())
        let genesis = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis.block, timestamp: 1_000,
            difficulty: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let _ = await genesis.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl(node: block1), block: block1
        )

        let persisted = await genesis.chainState.persist()
        let restored = ChainState.restore(from: persisted)

        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, timestamp: 2_000,
            difficulty: UInt256.max, nonce: 2, fetcher: fetcher
        )
        let result = await restored.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl(node: block2), block: block2
        )
        XCTAssertTrue(result.extendsMainChain, "Restored chain must accept new blocks")

        let height = await restored.getHighestBlockIndex()
        XCTAssertEqual(height, 2)
    }
}

// MARK: - #2: Mempool Gossip Tests

@MainActor
final class MempoolGossipTests: XCTestCase {

    func testTransactionAnnouncedAfterSubmission() async {
        let mempool = Mempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [], signers: [signerCID], fee: 50, nonce: 1
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)

        let added = await mempool.add(transaction: tx)
        XCTAssertTrue(added)

        let txCID = tx.body.rawCID
        let contains = await mempool.contains(txCID: txCID)
        XCTAssertTrue(contains, "Transaction should be in mempool for announcement")
    }

    func testMempoolSharedBetweenMinerAndRelay() async {
        let mempool = Mempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        for i: UInt64 in 0..<5 {
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

        let selected = await mempool.selectTransactions(maxCount: 3)
        XCTAssertEqual(selected.count, 3)
        let fees = selected.compactMap { $0.body.node?.fee }
        XCTAssertTrue(fees[0] >= fees[1], "Highest fee first for miners")

        let all = await mempool.allTransactions()
        XCTAssertEqual(all.count, 5, "All transactions available for gossip")
    }
}

// MARK: - #3: Rate Limiting Tests

@MainActor
final class BlockReceptionRateLimitTests: XCTestCase {

    func testDeduplicateRecentBlocks() async throws {
        let genesisConfig = GenesisConfig.standard(spec: hardeningSpec())
        let genesis = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis.block, timestamp: 1_000,
            difficulty: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let header = HeaderImpl<Block>(node: block1)

        let result1 = await genesis.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header, block: block1
        )
        XCTAssertTrue(result1.addedBlock)

        let result2 = await genesis.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header, block: block1
        )
        XCTAssertFalse(result2.addedBlock, "Duplicate CID should be rejected at ChainState level")
    }

    func testRapidSubmissionsHandledGracefully() async throws {
        let genesisConfig = GenesisConfig.standard(spec: hardeningSpec())
        let genesis = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)

        var prev = genesis.block
        for i in 1...50 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: Int64(i) * 1000,
                difficulty: UInt256.max, nonce: UInt64(i), fetcher: fetcher
            )
            let result = await genesis.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl(node: block), block: block
            )
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend")
            prev = block
        }

        let height = await genesis.chainState.getHighestBlockIndex()
        XCTAssertEqual(height, 50)
    }
}

// MARK: - #4: Real TCP Integration Test

@MainActor
final class TCPIntegrationTests: XCTestCase {

    func testTwoIvyNodesExchangeBlock() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        addTeardownBlock { try? group.syncShutdownGracefully() }

        let kpA = CryptoUtils.generateKeyPair()
        let kpB = CryptoUtils.generateKeyPair()

        let nodeA = Ivy(config: IvyConfig(
            publicKey: kpA.publicKey, listenPort: 15001,
            bootstrapPeers: [], enableLocalDiscovery: false
        ), group: group)

        let receivedExpectation = XCTestExpectation(description: "Node B receives block")
        let delegateA = BlockReceiver(expectation: receivedExpectation)
        await nodeA.setDelegate(delegateA)

        try await nodeA.start()

        let nodeB = Ivy(config: IvyConfig(
            publicKey: kpB.publicKey, listenPort: 15002,
            bootstrapPeers: [], enableLocalDiscovery: false
        ), group: group)
        try await nodeB.start()

        try await nodeB.connect(to: PeerEndpoint(publicKey: kpA.publicKey, host: "127.0.0.1", port: 15001))
        try await Task.sleep(for: .seconds(1))

        let testCID = "test_block_cid_12345"
        let testData = "block payload data".data(using: .utf8)!
        await nodeB.broadcastBlock(cid: testCID, data: testData)

        await fulfillment(of: [receivedExpectation], timeout: 10.0)

        let receivedCID = await delegateA.lastReceivedCID
        let receivedData = await delegateA.lastReceivedData
        XCTAssertEqual(receivedCID, testCID, "CID must match")
        XCTAssertEqual(receivedData, testData, "Data must match")

        await nodeA.stop()
        await nodeB.stop()
    }

    func testTwoIvyNodesExchangeMultipleBlocks() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        addTeardownBlock { try? group.syncShutdownGracefully() }

        let kpA = CryptoUtils.generateKeyPair()
        let kpB = CryptoUtils.generateKeyPair()

        let allReceived = XCTestExpectation(description: "All blocks received")
        allReceived.expectedFulfillmentCount = 3

        let nodeA = Ivy(config: IvyConfig(
            publicKey: kpA.publicKey, listenPort: 15003,
            bootstrapPeers: [], enableLocalDiscovery: false
        ), group: group)
        let delegateA = BlockReceiver(expectation: allReceived)
        await nodeA.setDelegate(delegateA)
        try await nodeA.start()

        let nodeB = Ivy(config: IvyConfig(
            publicKey: kpB.publicKey, listenPort: 15004,
            bootstrapPeers: [], enableLocalDiscovery: false
        ), group: group)
        try await nodeB.start()

        try await nodeB.connect(to: PeerEndpoint(publicKey: kpA.publicKey, host: "127.0.0.1", port: 15003))
        try await Task.sleep(for: .seconds(1))

        for i in 0..<3 {
            await nodeB.broadcastBlock(cid: "block_\(i)", data: "payload_\(i)".data(using: .utf8)!)
            try await Task.sleep(for: .milliseconds(200))
        }

        await fulfillment(of: [allReceived], timeout: 10.0)

        let count = await delegateA.receivedCount
        XCTAssertEqual(count, 3)

        await nodeA.stop()
        await nodeB.stop()
    }
}

actor BlockReceiver: IvyDelegate {
    let expectation: XCTestExpectation
    var lastReceivedCID: String?
    var lastReceivedData: Data?
    var receivedCount: Int = 0

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    nonisolated func ivy(_ ivy: Ivy, didConnect peer: PeerID) {}
    nonisolated func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {}
    nonisolated func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {}

    nonisolated func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {
        Task { await self.recordBlock(cid: cid, data: data) }
    }

    func recordBlock(cid: String, data: Data) {
        lastReceivedCID = cid
        lastReceivedData = data
        receivedCount += 1
        expectation.fulfill()
    }
}

extension Ivy {
    func setDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}
