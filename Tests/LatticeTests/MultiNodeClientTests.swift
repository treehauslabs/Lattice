import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// MARK: - Pure Unit Tests (no nodes, no I/O)

final class NodeIdentityTests: XCTestCase {

    func testGenerateProducesUniqueKeysWithValidLength() {
        let a = NodeIdentity.generate(id: "a", port: 5000)
        let b = NodeIdentity.generate(id: "b", port: 5001)

        XCTAssertNotEqual(a.publicKey, b.publicKey)
        XCTAssertNotEqual(a.privateKey, b.privateKey)
        XCTAssertEqual(a.id, "a")
        XCTAssertEqual(b.port, 5001)
        XCTAssertEqual(a.publicKey.count, 128)
        XCTAssertEqual(a.privateKey.count, 64)
    }

    func testManualInitPreservesFields() {
        let identity = NodeIdentity(id: "manual", publicKey: "aabb", privateKey: "1122", port: 9999)
        XCTAssertEqual(identity.id, "manual")
        XCTAssertEqual(identity.publicKey, "aabb")
        XCTAssertEqual(identity.port, 9999)
    }
}

final class MultiNodeErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertTrue(MultiNodeError.nodeAlreadyExists("n1").description.contains("already exists"))
        XCTAssertTrue(MultiNodeError.nodeNotFound("n2").description.contains("not found"))
        XCTAssertTrue(MultiNodeError.nodeAlreadyRunning("n3").description.contains("already running"))
        XCTAssertTrue(MultiNodeError.nodeNotRunning("n4").description.contains("not running"))
    }
}

// MARK: - Error Path Tests (cheap client, no nodes spawned)

@MainActor
final class MultiNodeErrorPathTests: XCTestCase {

    private func makeClient() -> MultiNodeClient {
        let spec = ChainSpec(
            directory: "Nexus",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialRewardExponent: 10
        )
        return MultiNodeClient(
            genesisConfig: GenesisConfig.standard(spec: spec),
            baseStoragePath: FileManager.default.temporaryDirectory
        )
    }

    func testOperationsOnNonexistentNodes() async throws {
        let client = makeClient()

        let ghost = await client.getNode(id: "ghost")
        XCTAssertNil(ghost)

        do { try await client.startNode(id: "ghost"); XCTFail() }
        catch let e as MultiNodeError { if case .nodeNotFound = e {} else { XCTFail() } }
        catch { XCTFail() }

        do { try await client.stopNode(id: "ghost"); XCTFail() }
        catch let e as MultiNodeError { if case .nodeNotFound = e {} else { XCTFail() } }
        catch { XCTFail() }

        do { try await client.removeNode(id: "ghost"); XCTFail() }
        catch let e as MultiNodeError { if case .nodeNotFound = e {} else { XCTFail() } }
        catch { XCTFail() }

        do { try await client.startMining(nodeId: "ghost", directory: "Nexus"); XCTFail() }
        catch let e as MultiNodeError { if case .nodeNotFound = e {} else { XCTFail() } }
        catch { XCTFail() }

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [], signers: [], fee: 0, nonce: 0
        )
        let tx = Transaction(signatures: [:], body: HeaderImpl<TransactionBody>(node: body))
        do { let _ = try await client.submitTransaction(nodeId: "ghost", directory: "Nexus", transaction: tx); XCTFail() }
        catch let e as MultiNodeError { if case .nodeNotFound = e {} else { XCTFail() } }
        catch { XCTFail() }

        do { let _ = try await client.nodeStatus(id: "ghost"); XCTFail() }
        catch let e as MultiNodeError { if case .nodeNotFound = e {} else { XCTFail() } }
        catch { XCTFail() }
    }

    func testEmptyClusterOperations() async {
        let client = makeClient()

        await client.stopAll()
        await client.stopMiningAll(directory: "Nexus")

        let active = await client.activeNodeCount
        XCTAssertEqual(active, 0)

        let statuses = await client.allNodeStatuses()
        XCTAssertTrue(statuses.isEmpty)

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [], signers: [], fee: 0, nonce: 0
        )
        let tx = Transaction(signatures: [:], body: HeaderImpl<TransactionBody>(node: body))
        let results = await client.broadcastTransaction(directory: "Nexus", transaction: tx)
        XCTAssertTrue(results.isEmpty)
    }

    func testSpawnZeroNodes() async throws {
        let client = makeClient()
        let ids = try await client.spawnNodes(count: 0, basePort: 23001)
        XCTAssertTrue(ids.isEmpty)
        let zeroCount = await client.nodeCount
        XCTAssertEqual(zeroCount, 0)
    }
}

// MARK: - Spawn & Management Tests (single node, minimal I/O)

@MainActor
final class MultiNodeSpawnTests: XCTestCase {

    private var storagePath: URL!

    override func setUp() async throws {
        storagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-spawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storagePath)
    }

    private func makeClient() -> MultiNodeClient {
        let spec = ChainSpec(
            directory: "Nexus",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialRewardExponent: 10
        )
        return MultiNodeClient(
            genesisConfig: GenesisConfig.standard(spec: spec),
            baseStoragePath: storagePath
        )
    }

    func testSpawnAndManageNodes() async throws {
        let client = makeClient()
        let ids = try await client.spawnNodes(count: 2, basePort: 17001)

        XCTAssertEqual(ids, ["node-0", "node-1"])
        var count = await client.nodeCount
        XCTAssertEqual(count, 2)
        let active = await client.activeNodeCount
        XCTAssertEqual(active, 0)
        let node = await client.getNode(id: "node-0")
        XCTAssertNotNil(node)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: storagePath.appendingPathComponent("node-node-0").path))
        XCTAssertTrue(fm.fileExists(atPath: storagePath.appendingPathComponent("node-node-1").path))

        try await client.removeNode(id: "node-1")
        count = await client.nodeCount
        XCTAssertEqual(count, 1)
        let remainingIds = await client.allNodeIds
        XCTAssertEqual(remainingIds, ["node-0"])
    }

    func testAddDuplicateNodeThrows() async throws {
        let client = makeClient()
        let identity = NodeIdentity.generate(id: "dup", port: 17030)
        let _ = try await client.addNode(identity: identity)

        do {
            let _ = try await client.addNode(identity: identity)
            XCTFail("Should throw nodeAlreadyExists")
        } catch let e as MultiNodeError {
            if case .nodeAlreadyExists(let id) = e { XCTAssertEqual(id, "dup") }
            else { XCTFail("Wrong error") }
        } catch { XCTFail("Unexpected error") }
    }

    func testNodeIdsAreSorted() async throws {
        let client = makeClient()
        for (i, name) in ["zebra", "alpha", "mango"].enumerated() {
            let identity = NodeIdentity.generate(id: name, port: 17040 + UInt16(i))
            let _ = try await client.addNode(identity: identity)
        }
        let sortedIds = await client.allNodeIds
        XCTAssertEqual(sortedIds, ["alpha", "mango", "zebra"])
    }

    func testAllNodesShareSameGenesisTip() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 2, basePort: 17050)
        let statuses = await client.allNodeStatuses()
        let tips = Set(statuses.map(\.chainTip))
        XCTAssertEqual(tips.count, 1)
        for s in statuses {
            XCTAssertEqual(s.chainHeight, 0)
        }
    }
}

// MARK: - Lifecycle & Mining Tests (1 node, started)

@MainActor
final class MultiNodeLifecycleTests: XCTestCase {

    private var storagePath: URL!

    override func setUp() async throws {
        storagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-life-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storagePath)
    }

    private func makeClient() -> MultiNodeClient {
        let spec = ChainSpec(
            directory: "Nexus",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialRewardExponent: 10
        )
        return MultiNodeClient(
            genesisConfig: GenesisConfig.standard(spec: spec),
            baseStoragePath: storagePath
        )
    }

    func testStartStopCycleAndStatus() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 18001)

        let statusBefore = try await client.nodeStatus(id: "node-0")
        XCTAssertFalse(statusBefore.isRunning)
        XCTAssertEqual(statusBefore.port, 18001)
        XCTAssertEqual(statusBefore.chainHeight, 0)

        try await client.startNode(id: "node-0")
        var activeCount = await client.activeNodeCount
        XCTAssertEqual(activeCount, 1)
        let runningStatus = try await client.nodeStatus(id: "node-0")
        XCTAssertTrue(runningStatus.isRunning)

        do { try await client.startNode(id: "node-0"); XCTFail() }
        catch let e as MultiNodeError { if case .nodeAlreadyRunning = e {} else { XCTFail() } }
        catch { XCTFail() }

        try await client.stopNode(id: "node-0")
        activeCount = await client.activeNodeCount
        XCTAssertEqual(activeCount, 0)

        do { try await client.stopNode(id: "node-0"); XCTFail() }
        catch let e as MultiNodeError { if case .nodeNotRunning = e {} else { XCTFail() } }
        catch { XCTFail() }

        try await client.startNode(id: "node-0")
        activeCount = await client.activeNodeCount
        XCTAssertEqual(activeCount, 1)
        try await client.stopNode(id: "node-0")
    }

    func testMiningStartStopAndStatus() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 18010)

        do { try await client.startMining(nodeId: "node-0", directory: "Nexus"); XCTFail() }
        catch let e as MultiNodeError { if case .nodeNotRunning = e {} else { XCTFail() } }
        catch { XCTFail() }

        try await client.startNode(id: "node-0")
        try await client.startMining(nodeId: "node-0", directory: "Nexus")

        let status = try await client.nodeStatus(id: "node-0")
        XCTAssertTrue(status.miningDirectories.contains("Nexus"))

        try await client.startMining(nodeId: "node-0", directory: "AppChain")
        let status2 = try await client.nodeStatus(id: "node-0")
        XCTAssertTrue(status2.miningDirectories.contains("Nexus"))
        XCTAssertTrue(status2.miningDirectories.contains("AppChain"))

        try await client.stopMining(nodeId: "node-0", directory: "Nexus")
        let status3 = try await client.nodeStatus(id: "node-0")
        XCTAssertFalse(status3.miningDirectories.contains("Nexus"))
        XCTAssertTrue(status3.miningDirectories.contains("AppChain"))

        try await client.stopNode(id: "node-0")
    }

    func testRemoveRunningNodeStopsIt() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 18020)
        try await client.startNode(id: "node-0")
        try await client.startMining(nodeId: "node-0", directory: "Nexus")

        try await client.removeNode(id: "node-0")
        let activeAfter = await client.activeNodeCount
        XCTAssertEqual(activeAfter, 0)
        let nodeCountAfter = await client.nodeCount
        XCTAssertEqual(nodeCountAfter, 0)
    }

    func testStartAllStopAll() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 2, basePort: 18030)

        try await client.startNode(id: "node-0")
        try await client.startAll()
        var ac = await client.activeNodeCount
        XCTAssertEqual(ac, 2)

        try await client.startMiningAll(directory: "Nexus")
        for id in ["node-0", "node-1"] {
            let s = try await client.nodeStatus(id: id)
            XCTAssertTrue(s.miningDirectories.contains("Nexus"))
        }

        await client.stopMiningAll(directory: "Nexus")
        for id in ["node-0", "node-1"] {
            let s = try await client.nodeStatus(id: id)
            XCTAssertFalse(s.miningDirectories.contains("Nexus"))
        }

        await client.stopAll()
        ac = await client.activeNodeCount
        XCTAssertEqual(ac, 0)
    }
}

// MARK: - Transaction Broadcasting Tests (2 nodes)

@MainActor
final class MultiNodeTransactionTests: XCTestCase {

    private var storagePath: URL!

    override func setUp() async throws {
        storagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-tx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storagePath)
    }

    func testBroadcastToRunningNodes() async throws {
        let spec = ChainSpec(
            directory: "Nexus",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialRewardExponent: 10
        )
        let client = MultiNodeClient(
            genesisConfig: GenesisConfig.standard(spec: spec),
            baseStoragePath: storagePath
        )
        let _ = try await client.spawnNodes(count: 2, basePort: 22001)
        try await client.startAll()

        let keyPair = CryptoUtils.generateKeyPair()
        let address = CryptoUtils.createAddress(from: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: address, oldBalance: 0, newBalance: 100)],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [],
            signers: [address], fee: 1, nonce: 0
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: keyPair.privateKey)!
        let tx = Transaction(signatures: [keyPair.publicKey: sig], body: bodyHeader)

        let results = await client.broadcastTransaction(directory: "Nexus", transaction: tx)
        XCTAssertEqual(results.count, 2)

        await client.stopAll()
    }
}

// MARK: - Convergence Tests (no real nodes — lightweight ChainState only)

@MainActor
final class MultiNodeConvergenceTests: XCTestCase {

    func testBlockPropagatesAcrossTwoChains() async {
        let genesis = makeGenesisBlock()
        let chain0 = ChainState.fromGenesis(block: genesis)
        let chain1 = ChainState.fromGenesis(block: genesis)

        let block1 = makeBlock(previous: genesis, index: 1, timestamp: genesis.timestamp + 1000)
        let header1 = blockHeader(block1)

        let r0 = await chain0.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header1, block: block1)
        XCTAssertTrue(r0.extendsMainChain)

        let r1 = await chain1.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header1, block: block1)
        XCTAssertTrue(r1.extendsMainChain)

        let tip0 = await chain0.getMainChainTip()
        let tip1 = await chain1.getMainChainTip()
        XCTAssertEqual(tip0, tip1)
        let h = await chain0.getHighestBlockIndex()
        XCTAssertEqual(h, 1)
    }

    func testFiveBlockChainConverges() async {
        let genesis = makeGenesisBlock()
        let chains = (0..<3).map { _ in ChainState.fromGenesis(block: genesis) }

        var blocks: [Block] = []
        var prev = genesis
        for i in 1...5 {
            let block = makeBlock(previous: prev, index: UInt64(i), timestamp: prev.timestamp + 1000)
            blocks.append(block)
            prev = block
        }

        for chain in chains {
            for block in blocks {
                let _ = await chain.submitBlock(
                    parentBlockHeaderAndIndex: nil,
                    blockHeader: blockHeader(block),
                    block: block
                )
            }
            let height = await chain.getHighestBlockIndex()
            XCTAssertEqual(height, 5)
        }

        let tips = Set(await chains.asyncMap { await $0.getMainChainTip() })
        XCTAssertEqual(tips.count, 1)
    }

    func testReorgConvergesAcrossChains() async {
        let genesis = makeGenesisBlock()
        let chain0 = ChainState.fromGenesis(block: genesis)
        let chain1 = ChainState.fromGenesis(block: genesis)

        let a1 = makeBlock(previous: genesis, index: 1, timestamp: genesis.timestamp + 1000, nonce: 1)
        let a2 = makeBlock(previous: a1, index: 2, timestamp: genesis.timestamp + 2000, nonce: 1)
        for b in [a1, a2] {
            let _ = await chain0.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b), block: b)
            let _ = await chain1.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b), block: b)
        }

        let b1 = makeBlock(previous: genesis, index: 1, timestamp: genesis.timestamp + 1000, nonce: 10)
        let b2 = makeBlock(previous: b1, index: 2, timestamp: genesis.timestamp + 2000, nonce: 10)
        let b3 = makeBlock(previous: b2, index: 3, timestamp: genesis.timestamp + 3000, nonce: 10)
        for b in [b1, b2, b3] {
            let _ = await chain0.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b), block: b)
            let _ = await chain1.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b), block: b)
        }

        let tip0 = await chain0.getMainChainTip()
        let tip1 = await chain1.getMainChainTip()
        XCTAssertEqual(tip0, tip1)
        XCTAssertEqual(tip0, blockHeader(b3).rawCID)
        let h0 = await chain0.getHighestBlockIndex()
        let h1 = await chain1.getHighestBlockIndex()
        XCTAssertEqual(h0, 3)
        XCTAssertEqual(h1, 3)
    }
}

// MARK: - Helpers

private extension Array where Element: Sendable {
    func asyncMap<T: Sendable>(_ transform: @Sendable (Element) async -> T) async -> [T] {
        var results: [T] = []
        for element in self {
            results.append(await transform(element))
        }
        return results
    }
}
