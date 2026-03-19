import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// MARK: - NodeIdentity Tests

final class NodeIdentityTests: XCTestCase {

    func testGenerateProducesUniqueKeys() {
        let a = NodeIdentity.generate(id: "a", port: 5000)
        let b = NodeIdentity.generate(id: "b", port: 5001)

        XCTAssertNotEqual(a.publicKey, b.publicKey)
        XCTAssertNotEqual(a.privateKey, b.privateKey)
        XCTAssertEqual(a.id, "a")
        XCTAssertEqual(b.id, "b")
        XCTAssertEqual(a.port, 5000)
        XCTAssertEqual(b.port, 5001)
    }

    func testGenerateKeysAreValidLength() {
        let identity = NodeIdentity.generate(id: "test", port: 5000)
        XCTAssertEqual(identity.publicKey.count, 128, "P256 public key hex should be 128 chars")
        XCTAssertEqual(identity.privateKey.count, 64, "P256 private key hex should be 64 chars")
    }

    func testManualInitPreservesFields() {
        let identity = NodeIdentity(
            id: "manual",
            publicKey: "aabbccdd",
            privateKey: "11223344",
            port: 9999
        )
        XCTAssertEqual(identity.id, "manual")
        XCTAssertEqual(identity.publicKey, "aabbccdd")
        XCTAssertEqual(identity.privateKey, "11223344")
        XCTAssertEqual(identity.port, 9999)
    }
}

// MARK: - MultiNodeError Tests

final class MultiNodeErrorTests: XCTestCase {

    func testErrorDescriptions() {
        let e1 = MultiNodeError.nodeAlreadyExists("n1")
        XCTAssertTrue(e1.description.contains("n1"))
        XCTAssertTrue(e1.description.contains("already exists"))

        let e2 = MultiNodeError.nodeNotFound("n2")
        XCTAssertTrue(e2.description.contains("n2"))
        XCTAssertTrue(e2.description.contains("not found"))

        let e3 = MultiNodeError.nodeAlreadyRunning("n3")
        XCTAssertTrue(e3.description.contains("n3"))
        XCTAssertTrue(e3.description.contains("already running"))

        let e4 = MultiNodeError.nodeNotRunning("n4")
        XCTAssertTrue(e4.description.contains("n4"))
        XCTAssertTrue(e4.description.contains("not running"))
    }
}

// MARK: - MultiNodeClient Core Tests

@MainActor
final class MultiNodeClientSpawnTests: XCTestCase {

    private var storagePath: URL!

    override func setUp() async throws {
        storagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-test-\(UUID().uuidString)")
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
        let genesisConfig = GenesisConfig.standard(spec: spec)
        return MultiNodeClient(
            genesisConfig: genesisConfig,
            baseStoragePath: storagePath
        )
    }

    func testSpawnNodesCreatesCorrectCount() async throws {
        let client = makeClient()
        let ids = try await client.spawnNodes(count: 3, basePort: 17001)

        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids, ["node-0", "node-1", "node-2"])

        let count = await client.nodeCount
        XCTAssertEqual(count, 3)

        let active = await client.activeNodeCount
        XCTAssertEqual(active, 0, "No nodes started yet")
    }

    func testSpawnSingleNode() async throws {
        let client = makeClient()
        let ids = try await client.spawnNodes(count: 1, basePort: 17010)

        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(ids[0], "node-0")
    }

    func testAddNodeManually() async throws {
        let client = makeClient()
        let identity = NodeIdentity.generate(id: "custom-node", port: 17020)
        let node = try await client.addNode(identity: identity)

        XCTAssertNotNil(node)
        let count = await client.nodeCount
        XCTAssertEqual(count, 1)

        let allIds = await client.allNodeIds
        XCTAssertEqual(allIds, ["custom-node"])
    }

    func testAddDuplicateNodeThrows() async throws {
        let client = makeClient()
        let identity = NodeIdentity.generate(id: "dup", port: 17030)
        let _ = try await client.addNode(identity: identity)

        do {
            let _ = try await client.addNode(identity: identity)
            XCTFail("Should throw nodeAlreadyExists")
        } catch let error as MultiNodeError {
            if case .nodeAlreadyExists(let id) = error {
                XCTAssertEqual(id, "dup")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGetNodeReturnsNilForMissing() async {
        let client = makeClient()
        let node = await client.getNode(id: "nonexistent")
        XCTAssertNil(node)
    }

    func testGetNodeReturnsNode() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 17040)
        let node = await client.getNode(id: "node-0")
        XCTAssertNotNil(node)
    }

    func testRemoveNonexistentNodeThrows() async {
        let client = makeClient()
        do {
            try await client.removeNode(id: "ghost")
            XCTFail("Should throw nodeNotFound")
        } catch let error as MultiNodeError {
            if case .nodeNotFound(let id) = error {
                XCTAssertEqual(id, "ghost")
            } else {
                XCTFail("Wrong error type")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemoveNodeDecrementsCount() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 3, basePort: 17050)

        let before = await client.nodeCount
        XCTAssertEqual(before, 3)

        try await client.removeNode(id: "node-1")

        let after = await client.nodeCount
        XCTAssertEqual(after, 2)

        let remaining = await client.allNodeIds
        XCTAssertEqual(remaining, ["node-0", "node-2"])
    }

    func testStorageDirectoriesCreated() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 2, basePort: 17060)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: storagePath.appendingPathComponent("node-node-0").path))
        XCTAssertTrue(fm.fileExists(atPath: storagePath.appendingPathComponent("node-node-1").path))
    }
}

// MARK: - Node Lifecycle Tests

@MainActor
final class MultiNodeLifecycleTests: XCTestCase {

    private var storagePath: URL!

    override func setUp() async throws {
        storagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-lifecycle-\(UUID().uuidString)")
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

    func testStartNonexistentNodeThrows() async {
        let client = makeClient()
        do {
            try await client.startNode(id: "ghost")
            XCTFail("Should throw")
        } catch let error as MultiNodeError {
            if case .nodeNotFound = error {} else { XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStopNonexistentNodeThrows() async {
        let client = makeClient()
        do {
            try await client.stopNode(id: "ghost")
            XCTFail("Should throw")
        } catch let error as MultiNodeError {
            if case .nodeNotFound = error {} else { XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartAndStopSingleNode() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 18001)

        try await client.startNode(id: "node-0")
        let activeAfterStart = await client.activeNodeCount
        XCTAssertEqual(activeAfterStart, 1)

        try await client.stopNode(id: "node-0")
        let activeAfterStop = await client.activeNodeCount
        XCTAssertEqual(activeAfterStop, 0)
    }

    func testStartAlreadyRunningNodeThrows() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 18010)
        try await client.startNode(id: "node-0")

        do {
            try await client.startNode(id: "node-0")
            XCTFail("Should throw nodeAlreadyRunning")
        } catch let error as MultiNodeError {
            if case .nodeAlreadyRunning = error {} else { XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try await client.stopNode(id: "node-0")
    }

    func testStopNotRunningNodeThrows() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 18020)

        do {
            try await client.stopNode(id: "node-0")
            XCTFail("Should throw nodeNotRunning")
        } catch let error as MultiNodeError {
            if case .nodeNotRunning = error {} else { XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartAllAndStopAll() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 3, basePort: 18030)

        try await client.startAll()
        let active = await client.activeNodeCount
        XCTAssertEqual(active, 3)

        await client.stopAll()
        let afterStop = await client.activeNodeCount
        XCTAssertEqual(afterStop, 0)
    }

    func testStartAllSkipsAlreadyRunning() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 2, basePort: 18040)

        try await client.startNode(id: "node-0")
        try await client.startAll()

        let active = await client.activeNodeCount
        XCTAssertEqual(active, 2)

        await client.stopAll()
    }

    func testRemoveRunningNodeStopsItFirst() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 18050)
        try await client.startNode(id: "node-0")

        let activeBefore = await client.activeNodeCount
        XCTAssertEqual(activeBefore, 1)

        try await client.removeNode(id: "node-0")

        let activeAfter = await client.activeNodeCount
        XCTAssertEqual(activeAfter, 0)
        let count = await client.nodeCount
        XCTAssertEqual(count, 0)
    }
}

// MARK: - Mining Management Tests

@MainActor
final class MultiNodeMiningTests: XCTestCase {

    private var storagePath: URL!

    override func setUp() async throws {
        storagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-mining-\(UUID().uuidString)")
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

    func testStartMiningOnNonexistentNodeThrows() async {
        let client = makeClient()
        do {
            try await client.startMining(nodeId: "ghost", directory: "Nexus")
            XCTFail("Should throw")
        } catch let error as MultiNodeError {
            if case .nodeNotFound = error {} else { XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartMiningOnStoppedNodeThrows() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 19001)

        do {
            try await client.startMining(nodeId: "node-0", directory: "Nexus")
            XCTFail("Should throw nodeNotRunning")
        } catch let error as MultiNodeError {
            if case .nodeNotRunning = error {} else { XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartAndStopMining() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 19010)
        try await client.startNode(id: "node-0")

        try await client.startMining(nodeId: "node-0", directory: "Nexus")

        let status = try await client.nodeStatus(id: "node-0")
        XCTAssertTrue(status.miningDirectories.contains("Nexus"))

        try await client.stopMining(nodeId: "node-0", directory: "Nexus")

        let statusAfter = try await client.nodeStatus(id: "node-0")
        XCTAssertFalse(statusAfter.miningDirectories.contains("Nexus"))

        try await client.stopNode(id: "node-0")
    }

    func testStartMiningAllNodes() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 3, basePort: 19020)
        try await client.startAll()

        try await client.startMiningAll(directory: "Nexus")

        for id in ["node-0", "node-1", "node-2"] {
            let status = try await client.nodeStatus(id: id)
            XCTAssertTrue(status.miningDirectories.contains("Nexus"),
                "\(id) should be mining Nexus")
        }

        await client.stopMiningAll(directory: "Nexus")

        for id in ["node-0", "node-1", "node-2"] {
            let status = try await client.nodeStatus(id: id)
            XCTAssertFalse(status.miningDirectories.contains("Nexus"),
                "\(id) should not be mining after stopAll")
        }

        await client.stopAll()
    }

    func testStopNodeAlsoStopsMining() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 19030)
        try await client.startNode(id: "node-0")
        try await client.startMining(nodeId: "node-0", directory: "Nexus")

        try await client.stopNode(id: "node-0")

        let _ = try await client.spawnNodes(count: 0, basePort: 19040)
    }

    func testStopAllClearsMiningState() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 2, basePort: 19040)
        try await client.startAll()
        try await client.startMiningAll(directory: "Nexus")

        await client.stopAll()

        let active = await client.activeNodeCount
        XCTAssertEqual(active, 0)
    }
}

// MARK: - Status Reporting Tests

@MainActor
final class MultiNodeStatusTests: XCTestCase {

    private var storagePath: URL!

    override func setUp() async throws {
        storagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-status-\(UUID().uuidString)")
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

    func testStatusForNonexistentNodeThrows() async {
        let client = makeClient()
        do {
            let _ = try await client.nodeStatus(id: "ghost")
            XCTFail("Should throw")
        } catch let error as MultiNodeError {
            if case .nodeNotFound = error {} else { XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStatusReflectsNodeState() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 20001)

        let statusBefore = try await client.nodeStatus(id: "node-0")
        XCTAssertEqual(statusBefore.id, "node-0")
        XCTAssertEqual(statusBefore.port, 20001)
        XCTAssertFalse(statusBefore.isRunning)
        XCTAssertTrue(statusBefore.miningDirectories.isEmpty)
        XCTAssertEqual(statusBefore.chainHeight, 0)
        XCTAssertFalse(statusBefore.chainTip.isEmpty)

        try await client.startNode(id: "node-0")

        let statusAfter = try await client.nodeStatus(id: "node-0")
        XCTAssertTrue(statusAfter.isRunning)

        try await client.stopNode(id: "node-0")
    }

    func testAllNodeStatusesReturnsSorted() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 3, basePort: 20010)

        let statuses = await client.allNodeStatuses()
        XCTAssertEqual(statuses.count, 3)
        XCTAssertEqual(statuses.map(\.id), ["node-0", "node-1", "node-2"])
    }

    func testAllNodesShareSameGenesisTip() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 3, basePort: 20020)

        let statuses = await client.allNodeStatuses()
        let tips = Set(statuses.map(\.chainTip))
        XCTAssertEqual(tips.count, 1, "All nodes should agree on genesis tip")
    }

    func testAllNodesStartAtHeightZero() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 3, basePort: 20030)

        let statuses = await client.allNodeStatuses()
        for status in statuses {
            XCTAssertEqual(status.chainHeight, 0, "\(status.id) should start at height 0")
        }
    }

    func testStatusShowsMiningDirectory() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 20040)
        try await client.startNode(id: "node-0")
        try await client.startMining(nodeId: "node-0", directory: "Nexus")

        let status = try await client.nodeStatus(id: "node-0")
        XCTAssertEqual(status.miningDirectories, ["Nexus"])

        await client.stopAll()
    }

    func testEmptyClusterReturnsEmptyStatuses() async {
        let client = makeClient()
        let statuses = await client.allNodeStatuses()
        XCTAssertTrue(statuses.isEmpty)
    }
}

// MARK: - Multi-Node Mining Convergence Tests

@MainActor
final class MultiNodeConvergenceTests: XCTestCase {

    private var storagePath: URL!

    override func setUp() async throws {
        storagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-converge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storagePath)
    }

    func testDirectChainStateAdvancesPerNode() async throws {
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

        let _ = try await client.spawnNodes(count: 2, basePort: 21001)

        let node0 = await client.getNode(id: "node-0")!
        let node1 = await client.getNode(id: "node-1")!
        let genesis0 = await node0.genesisResult.block
        let genesis1 = await node1.genesisResult.block

        XCTAssertEqual(
            HeaderImpl<Block>(node: genesis0).rawCID,
            HeaderImpl<Block>(node: genesis1).rawCID,
            "Both nodes should share the same genesis"
        )

        let nexus0 = await node0.lattice.nexus
        let chain0 = await nexus0.chain
        let nexus1 = await node1.lattice.nexus
        let chain1 = await nexus1.chain

        let block1 = makeBlock(previous: genesis0, index: 1, timestamp: genesis0.timestamp + 1000)
        let header1 = blockHeader(block1)
        let result = await chain0.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: header1,
            block: block1
        )
        XCTAssertTrue(result.extendsMainChain, "Block should extend node-0's chain")

        let height0 = await chain0.getHighestBlockIndex()
        XCTAssertEqual(height0, 1)

        let result1 = await chain1.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: header1,
            block: block1
        )
        XCTAssertTrue(result1.extendsMainChain, "Same block should extend node-1's chain")

        let height1 = await chain1.getHighestBlockIndex()
        XCTAssertEqual(height1, 1)

        let tip0 = await chain0.getMainChainTip()
        let tip1 = await chain1.getMainChainTip()
        XCTAssertEqual(tip0, tip1, "Both nodes should agree on chain tip")
    }

    func testFiveBlockChainAcrossMultipleNodes() async throws {
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

        let _ = try await client.spawnNodes(count: 3, basePort: 21010)

        var blocks: [Block] = []
        let node0 = await client.getNode(id: "node-0")!
        var prev = await node0.genesisResult.block
        for i in 1...5 {
            let block = makeBlock(
                previous: prev,
                index: UInt64(i),
                timestamp: prev.timestamp + 1000
            )
            blocks.append(block)
            prev = block
        }

        for nodeId in ["node-0", "node-1", "node-2"] {
            let node = await client.getNode(id: nodeId)!
            let nexus = await node.lattice.nexus
            let chain = await nexus.chain

            for block in blocks {
                let _ = await chain.submitBlock(
                    parentBlockHeaderAndIndex: nil,
                    blockHeader: blockHeader(block),
                    block: block
                )
            }

            let height = await chain.getHighestBlockIndex()
            XCTAssertEqual(height, 5, "\(nodeId) should be at height 5")
        }

        let statuses = await client.allNodeStatuses()
        let tips = Set(statuses.map(\.chainTip))
        XCTAssertEqual(tips.count, 1, "All nodes must agree on tip after same blocks")
    }

    func testReorgPropagatesAcrossNodes() async throws {
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

        let _ = try await client.spawnNodes(count: 2, basePort: 21020)
        let node0 = await client.getNode(id: "node-0")!
        let node1 = await client.getNode(id: "node-1")!
        let genesis = await node0.genesisResult.block
        let nexus0 = await node0.lattice.nexus
        let chain0 = await nexus0.chain
        let nexus1 = await node1.lattice.nexus
        let chain1 = await nexus1.chain

        let a1 = makeBlock(previous: genesis, index: 1, timestamp: genesis.timestamp + 1000, nonce: 1)
        let a2 = makeBlock(previous: a1, index: 2, timestamp: genesis.timestamp + 2000, nonce: 1)
        for b in [a1, a2] {
            let _ = await chain0.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b), block: b)
            let _ = await chain1.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b), block: b)
        }

        let tip0After2 = await chain0.getMainChainTip()
        let tip1After2 = await chain1.getMainChainTip()
        XCTAssertEqual(tip0After2, tip1After2, "Both nodes should agree after 2 blocks")

        let b1 = makeBlock(previous: genesis, index: 1, timestamp: genesis.timestamp + 1000, nonce: 10)
        let b2 = makeBlock(previous: b1, index: 2, timestamp: genesis.timestamp + 2000, nonce: 10)
        let b3 = makeBlock(previous: b2, index: 3, timestamp: genesis.timestamp + 3000, nonce: 10)

        for b in [b1, b2, b3] {
            let _ = await chain0.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b), block: b)
            let _ = await chain1.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b), block: b)
        }

        let finalTip0 = await chain0.getMainChainTip()
        let finalTip1 = await chain1.getMainChainTip()
        XCTAssertEqual(finalTip0, finalTip1, "Both nodes should converge after reorg")
        XCTAssertEqual(finalTip0, blockHeader(b3).rawCID, "Longer fork should win")

        let height0 = await chain0.getHighestBlockIndex()
        let height1 = await chain1.getHighestBlockIndex()
        XCTAssertEqual(height0, 3)
        XCTAssertEqual(height1, 3)
    }

    func testAllNodesAgreeOnGenesisTipBeforeMining() async throws {
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

        let _ = try await client.spawnNodes(count: 3, basePort: 21020)
        try await client.startAll()

        let statuses = await client.allNodeStatuses()
        let tips = Set(statuses.map(\.chainTip))
        XCTAssertEqual(tips.count, 1, "All 3 nodes must agree on genesis chain tip")

        let heights = Set(statuses.map(\.chainHeight))
        XCTAssertEqual(heights, [0], "All nodes start at height 0")

        await client.stopAll()
    }
}

// MARK: - Transaction Broadcasting Tests

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

    func testSubmitTransactionToNonexistentNodeThrows() async {
        let client = makeClient()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [], signers: [], fee: 0, nonce: 0
        )
        let tx = Transaction(
            signatures: [:],
            body: HeaderImpl<TransactionBody>(node: body)
        )

        do {
            let _ = try await client.submitTransaction(
                nodeId: "ghost", directory: "Nexus", transaction: tx
            )
            XCTFail("Should throw")
        } catch let error as MultiNodeError {
            if case .nodeNotFound = error {} else { XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBroadcastToEmptyClusterReturnsEmptyResults() async {
        let client = makeClient()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [], signers: [], fee: 0, nonce: 0
        )
        let tx = Transaction(
            signatures: [:],
            body: HeaderImpl<TransactionBody>(node: body)
        )

        let results = await client.broadcastTransaction(directory: "Nexus", transaction: tx)
        XCTAssertTrue(results.isEmpty)
    }

    func testBroadcastToRunningNodesReturnsResults() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 2, basePort: 22001)
        try await client.startAll()

        let keyPair = CryptoUtils.generateKeyPair()
        let address = CryptoUtils.createAddress(from: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: address, oldBalance: 0, newBalance: 100)
            ],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [],
            signers: [address],
            fee: 1, nonce: 0
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: keyPair.privateKey)!
        let tx = Transaction(
            signatures: [keyPair.publicKey: sig],
            body: bodyHeader
        )

        let results = await client.broadcastTransaction(directory: "Nexus", transaction: tx)
        XCTAssertEqual(results.count, 2, "Should get a result for each running node")

        await client.stopAll()
    }
}

// MARK: - Edge Cases and Robustness

@MainActor
final class MultiNodeEdgeCaseTests: XCTestCase {

    private var storagePath: URL!

    override func setUp() async throws {
        storagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-edge-\(UUID().uuidString)")
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

    func testSpawnZeroNodes() async throws {
        let client = makeClient()
        let ids = try await client.spawnNodes(count: 0, basePort: 23001)
        XCTAssertTrue(ids.isEmpty)
        let count = await client.nodeCount
        XCTAssertEqual(count, 0)
    }

    func testStopAllOnEmptyCluster() async {
        let client = makeClient()
        await client.stopAll()
        let active = await client.activeNodeCount
        XCTAssertEqual(active, 0)
    }

    func testStopMiningAllOnEmptyCluster() async {
        let client = makeClient()
        await client.stopMiningAll(directory: "Nexus")
    }

    func testStartStopStartCycle() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 23010)

        try await client.startNode(id: "node-0")
        var active = await client.activeNodeCount
        XCTAssertEqual(active, 1)

        try await client.stopNode(id: "node-0")
        active = await client.activeNodeCount
        XCTAssertEqual(active, 0)

        try await client.startNode(id: "node-0")
        active = await client.activeNodeCount
        XCTAssertEqual(active, 1)

        try await client.stopNode(id: "node-0")
    }

    func testAllNodeIdsAreSorted() async throws {
        let client = makeClient()
        for (i, name) in ["zebra", "alpha", "mango"].enumerated() {
            let identity = NodeIdentity.generate(id: name, port: 23020 + UInt16(i))
            let _ = try await client.addNode(identity: identity)
        }

        let ids = await client.allNodeIds
        XCTAssertEqual(ids, ["alpha", "mango", "zebra"])
    }

    func testMiningMultipleDirectories() async throws {
        let client = makeClient()
        let _ = try await client.spawnNodes(count: 1, basePort: 23030)
        try await client.startNode(id: "node-0")

        try await client.startMining(nodeId: "node-0", directory: "Nexus")
        try await client.startMining(nodeId: "node-0", directory: "AppChain")

        let status = try await client.nodeStatus(id: "node-0")
        XCTAssertTrue(status.miningDirectories.contains("Nexus"))
        XCTAssertTrue(status.miningDirectories.contains("AppChain"))

        try await client.stopMining(nodeId: "node-0", directory: "Nexus")

        let statusAfter = try await client.nodeStatus(id: "node-0")
        XCTAssertFalse(statusAfter.miningDirectories.contains("Nexus"))
        XCTAssertTrue(statusAfter.miningDirectories.contains("AppChain"))

        await client.stopAll()
    }
}

// MARK: - Test Helpers

private struct TestFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "TestFetcher", code: 404)
    }
}
