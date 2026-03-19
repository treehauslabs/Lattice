import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation
import Acorn

@MainActor
final class LatticeNodeUnitTests: XCTestCase {

    // MARK: - ChainLevel Extensions

    func testChildDirectoriesEmpty() async {
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
        let genesis = try! await BlockBuilder.buildGenesis(
            spec: spec, timestamp: Int64(Date().timeIntervalSince1970 * 1000) - 10_000,
            difficulty: UInt256(1000), fetcher: TestNodeFetcher()
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let level = ChainLevel(chain: chain, children: [:])

        let dirs = await level.childDirectories()
        XCTAssertTrue(dirs.isEmpty)
    }

    func testChildDirectoriesAfterRegister() async {
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
        let childSpec = ChainSpec(directory: "Child", maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let fetcher = TestNodeFetcher()

        let genesis = try! await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try! await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let level = ChainLevel(chain: chain, children: [:])

        await level.registerChildChain(directory: "Child", genesisBlock: childGenesis)

        let dirs = await level.childDirectories()
        XCTAssertEqual(dirs, ["Child"])
    }

    func testRestoreChildChain() async {
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
        let childSpec = ChainSpec(directory: "Restored", maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let fetcher = TestNodeFetcher()

        let genesis = try! await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try! await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let nexusChain = ChainState.fromGenesis(block: genesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let level = ChainLevel(chain: nexusChain, children: [:])

        let childLevel = ChainLevel(chain: childChain, children: [:])
        await level.restoreChildChain(directory: "Restored", level: childLevel)

        let dirs = await level.childDirectories()
        XCTAssertEqual(dirs, ["Restored"])

        let height = await level.children["Restored"]?.chain.getHighestBlockIndex()
        XCTAssertEqual(height, 0)
    }

    func testRestoreChildChainIgnoresDuplicate() async {
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let fetcher = TestNodeFetcher()

        let genesis = try! await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let nexusChain = ChainState.fromGenesis(block: genesis)
        let child1 = ChainLevel(chain: ChainState.fromGenesis(block: genesis), children: [:])
        let child2 = ChainLevel(chain: ChainState.fromGenesis(block: genesis), children: [:])
        let level = ChainLevel(chain: nexusChain, children: [:])

        await level.restoreChildChain(directory: "X", level: child1)
        await level.restoreChildChain(directory: "X", level: child2)

        let dirs = await level.childDirectories()
        XCTAssertEqual(dirs.count, 1)
    }

    // MARK: - Chain Status

    func testChainStatusIncludesNexus() async throws {
        let fetcher = TestNodeFetcher()
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let level = ChainLevel(chain: chain, children: [:])
        let lattice = Lattice(nexus: level)

        let height = await lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertEqual(height, 0)

        let tip = await lattice.nexus.chain.getMainChainTip()
        XCTAssertFalse(tip.isEmpty)
    }

    // MARK: - NexusGenesis Integration

    func testNexusGenesisConfigIsUsable() async throws {
        let config = NexusGenesis.config
        XCTAssertEqual(config.timestamp, 0)
        XCTAssertEqual(config.difficulty, UInt256.max)
        XCTAssertTrue(NexusGenesis.spec.isValid)
    }

    func testNexusGenesisCreatesValidBlock() async throws {
        let fetcher = TestNodeFetcher()
        let result = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertEqual(result.block.index, 0)
        XCTAssertNotNil(result.chainState)
    }

    // MARK: - Merged Mining Flow

    func testMergedMiningDistributesBlocksToChildren() async throws {
        let fetcher = TestNodeFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 20_000
        let nexusSpec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
        let childSpec = ChainSpec(directory: "Child", maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialRewardExponent: 10, difficultyAdjustmentWindow: 5)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Child": childLevel])

        let nexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 0)

        let childHeight = await childChain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 0)

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Child": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: nexusBlock1), block: nexusBlock1
        )

        let newNexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(newNexusHeight, 1)
    }

    // MARK: - Persistence Roundtrip for Node State

    func testPersistAndRestoreChainState() async throws {
        let fetcher = TestNodeFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 20_000
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialRewardExponent: 10, difficultyAdjustmentWindow: 5)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: b1), block: b1
        )

        let persisted = await chain.persist()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: data)
        let restored = ChainState.restore(from: decoded)

        let restoredHeight = await restored.getHighestBlockIndex()
        let originalHeight = await chain.getHighestBlockIndex()
        XCTAssertEqual(restoredHeight, originalHeight)
        XCTAssertEqual(restoredHeight, 1)

        let restoredTip = await restored.getMainChainTip()
        let originalTip = await chain.getMainChainTip()
        XCTAssertEqual(restoredTip, originalTip)
    }

    func testRestoredChainAcceptsNewBlocks() async throws {
        let fetcher = TestNodeFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 20_000
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialRewardExponent: 10, difficultyAdjustmentWindow: 5)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: b1), block: b1
        )

        let persisted = await chain.persist()
        let restored = ChainState.restore(from: persisted)

        let b2 = try await BlockBuilder.buildBlock(
            previous: b1, timestamp: t + 2000,
            difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let result = await restored.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: b2), block: b2
        )
        XCTAssertTrue(result.extendsMainChain)

        let height = await restored.getHighestBlockIndex()
        XCTAssertEqual(height, 2)
    }

    // MARK: - Mining Control

    func testMinerLoopStartStop() async throws {
        let fetcher = TestNodeFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialRewardExponent: 10, difficultyAdjustmentWindow: 5)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let mempool = Mempool(maxSize: 100)

        let miner = MinerLoop(chainState: chain, mempool: mempool, fetcher: fetcher, spec: spec)

        let isMining = await miner.isMining
        XCTAssertFalse(isMining)

        await miner.start()
        let isNowMining = await miner.isMining
        XCTAssertTrue(isNowMining)

        await miner.stop()
        let isStopped = await miner.isMining
        XCTAssertFalse(isStopped)
    }
}

private struct TestNodeFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "TestNodeFetcher", code: 1)
    }
}
