import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation
import Acorn
import Ivy
import Tally
import NIOPosix

// MARK: - CID Round-Trip Tests

@MainActor
final class CIDRoundTripTests: XCTestCase {

    func testAcornFetcherStoresUnderCashewCID() async throws {
        let worker = TestCASWorker()
        let fetcher = AcornFetcher(worker: worker)

        let testData = "block data".data(using: .utf8)!
        let cashewCID = "baguqeera_test_cid_12345"

        await fetcher.store(rawCid: cashewCID, data: testData)

        let fetched = try await fetcher.fetch(rawCid: cashewCID)
        XCTAssertEqual(fetched, testData, "Must be retrievable by cashew CID")
    }

    func testAcornFetcherStoresUnderContentHash() async throws {
        let worker = TestCASWorker()
        let fetcher = AcornFetcher(worker: worker)

        let testData = "block data".data(using: .utf8)!
        let cashewCID = "baguqeera_test_cid"
        let contentCID = ContentIdentifier(for: testData)

        await fetcher.store(rawCid: cashewCID, data: testData)

        let hasContent = await worker.has(cid: contentCID)
        XCTAssertTrue(hasContent, "Must also be stored under content hash for Acorn lookups")
    }

    func testBlockSerializeDeserializeRoundTrip() async throws {
        let spec = ChainSpec(
            directory: "Test",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialRewardExponent: 10
        )
        let localFetcher = LocalTestFetcher()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 0, difficulty: UInt256(1000), fetcher: localFetcher
        )

        let genesisHeader = HeaderImpl<Block>(node: genesis)
        let genesisData = genesis.toData()
        XCTAssertNotNil(genesisData)

        let deserialized = Block(data: genesisData!)
        XCTAssertNotNil(deserialized, "Block must round-trip through serialization")

        let deserializedHeader = HeaderImpl<Block>(node: deserialized!)
        XCTAssertEqual(genesisHeader.rawCID, deserializedHeader.rawCID,
            "Deserialized block must produce same CID")
    }

    func testBlockStoredAndResolvedThroughFetcher() async throws {
        let worker = TestCASWorker()
        let fetcher = AcornFetcher(worker: worker)
        let localFetcher = LocalTestFetcher()

        let spec = ChainSpec(
            directory: "Test",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialRewardExponent: 10
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 0, difficulty: UInt256(1000), fetcher: localFetcher
        )
        let header = HeaderImpl<Block>(node: genesis)
        let blockData = genesis.toData()!

        await fetcher.store(rawCid: header.rawCID, data: blockData)

        let resolved = try await header.resolve(fetcher: fetcher)
        XCTAssertNotNil(resolved.node, "Block must be resolvable from fetcher after store")
    }

    func testChainBuiltAndResolvedThroughFetcher() async throws {
        let worker = TestCASWorker()
        let fetcher = AcornFetcher(worker: worker)
        let localFetcher = LocalTestFetcher()

        let spec = ChainSpec(
            directory: "Test",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialRewardExponent: 10
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 0, difficulty: UInt256(1000), fetcher: localFetcher
        )
        let genesisHeader = HeaderImpl<Block>(node: genesis)
        await fetcher.store(rawCid: genesisHeader.rawCID, data: genesis.toData()!)

        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: 1000, difficulty: UInt256(1000),
            nonce: 1, fetcher: localFetcher
        )
        let header1 = HeaderImpl<Block>(node: block1)
        await fetcher.store(rawCid: header1.rawCID, data: block1.toData()!)

        let result = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header1, block: block1
        )
        XCTAssertTrue(result.extendsMainChain)

        let storedHeader = HeaderImpl<Block>(rawCID: header1.rawCID)
        let resolved = try await storedHeader.resolve(fetcher: fetcher)
        XCTAssertNotNil(resolved.node)
        XCTAssertEqual(resolved.node?.index, 1)
    }
}

// MARK: - Two-Node Block Exchange Simulation

@MainActor
final class TwoNodeExchangeTests: XCTestCase {

    func testNodeAMinesNodeBReceives() async throws {
        let localFetcher = LocalTestFetcher()
        let spec = ChainSpec(
            directory: "Nexus",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialRewardExponent: 10
        )
        let genesisConfig = GenesisConfig.standard(spec: spec)

        let genesisA = try await GenesisCeremony.create(config: genesisConfig, fetcher: localFetcher)
        let genesisB = try await GenesisCeremony.create(config: genesisConfig, fetcher: localFetcher)

        XCTAssertEqual(genesisA.blockHash, genesisB.blockHash)

        let workerA = TestCASWorker()
        let fetcherA = AcornFetcher(worker: workerA)
        await fetcherA.store(rawCid: genesisA.blockHash, data: genesisA.block.toData()!)

        let workerB = TestCASWorker()
        let fetcherB = AcornFetcher(worker: workerB)
        await fetcherB.store(rawCid: genesisB.blockHash, data: genesisB.block.toData()!)

        var prev = genesisA.block
        var blocks: [Block] = []
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: Int64(i) * 1000,
                difficulty: UInt256.max, nonce: UInt64(i), fetcher: localFetcher
            )
            let header = HeaderImpl<Block>(node: block)
            await fetcherA.store(rawCid: header.rawCID, data: block.toData()!)

            let result = await genesisA.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
            )
            XCTAssertTrue(result.extendsMainChain)
            blocks.append(block)
            prev = block
        }

        let tipA = await genesisA.chainState.getMainChainTip()
        let heightA = await genesisA.chainState.getHighestBlockIndex()
        XCTAssertEqual(heightA, 5)

        for block in blocks {
            let header = HeaderImpl<Block>(node: block)
            let blockData = block.toData()!

            await fetcherB.store(rawCid: header.rawCID, data: blockData)

            let result = await genesisB.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
            )
            XCTAssertTrue(result.addedBlock, "Block \(block.index) should be accepted by node B")
        }

        let tipB = await genesisB.chainState.getMainChainTip()
        let heightB = await genesisB.chainState.getHighestBlockIndex()

        XCTAssertEqual(tipA, tipB, "Both nodes must agree on chain tip")
        XCTAssertEqual(heightA, heightB, "Both nodes must agree on height")
    }

    func testNodeBReorgsToNodeALongerChain() async throws {
        let localFetcher = LocalTestFetcher()
        let spec = ChainSpec(
            directory: "Nexus",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialRewardExponent: 10
        )
        let genesisConfig = GenesisConfig.standard(spec: spec)
        let genesisA = try await GenesisCeremony.create(config: genesisConfig, fetcher: localFetcher)
        let genesisB = try await GenesisCeremony.create(config: genesisConfig, fetcher: localFetcher)

        let blockA1 = try await BlockBuilder.buildBlock(
            previous: genesisA.block, timestamp: 1_000,
            difficulty: UInt256.max, nonce: 1, fetcher: localFetcher
        )
        let blockA2 = try await BlockBuilder.buildBlock(
            previous: blockA1, timestamp: 2_000,
            difficulty: UInt256.max, nonce: 2, fetcher: localFetcher
        )
        let blockA3 = try await BlockBuilder.buildBlock(
            previous: blockA2, timestamp: 3_000,
            difficulty: UInt256.max, nonce: 3, fetcher: localFetcher
        )

        for block in [blockA1, blockA2, blockA3] {
            let _ = await genesisA.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl(node: block), block: block
            )
        }

        let blockB1 = try await BlockBuilder.buildBlock(
            previous: genesisB.block, timestamp: 1_000,
            difficulty: UInt256.max, nonce: 100, fetcher: localFetcher
        )
        let _ = await genesisB.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl(node: blockB1), block: blockB1
        )

        let tipB_before = await genesisB.chainState.getMainChainTip()
        XCTAssertEqual(tipB_before, HeaderImpl<Block>(node: blockB1).rawCID)

        var sawReorg = false
        for block in [blockA1, blockA2, blockA3] {
            let result = await genesisB.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl(node: block), block: block
            )
            if result.reorganization != nil { sawReorg = true }
        }

        XCTAssertTrue(sawReorg, "Node B should reorg to A's longer chain")

        let tipA = await genesisA.chainState.getMainChainTip()
        let tipB = await genesisB.chainState.getMainChainTip()
        XCTAssertEqual(tipA, tipB, "Nodes must converge")
    }

    func testOutOfOrderBlockDeliveryConverges() async throws {
        let localFetcher = LocalTestFetcher()
        let spec = ChainSpec(
            directory: "Nexus",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialRewardExponent: 10
        )
        let genesisConfig = GenesisConfig.standard(spec: spec)
        let genesisA = try await GenesisCeremony.create(config: genesisConfig, fetcher: localFetcher)
        let genesisB = try await GenesisCeremony.create(config: genesisConfig, fetcher: localFetcher)

        let b1 = try await BlockBuilder.buildBlock(
            previous: genesisA.block, timestamp: 1_000,
            difficulty: UInt256.max, nonce: 1, fetcher: localFetcher
        )
        let b2 = try await BlockBuilder.buildBlock(
            previous: b1, timestamp: 2_000,
            difficulty: UInt256.max, nonce: 2, fetcher: localFetcher
        )
        let b3 = try await BlockBuilder.buildBlock(
            previous: b2, timestamp: 3_000,
            difficulty: UInt256.max, nonce: 3, fetcher: localFetcher
        )

        for block in [b1, b2, b3] {
            let _ = await genesisA.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl(node: block), block: block
            )
        }

        let r3 = await genesisB.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl(node: b3), block: b3
        )
        XCTAssertTrue(r3.needsChildBlock, "Block 3 before 1,2 should need parent")

        let _ = await genesisB.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl(node: b1), block: b1
        )
        let _ = await genesisB.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl(node: b2), block: b2
        )

        let tipA = await genesisA.chainState.getMainChainTip()
        let tipB = await genesisB.chainState.getMainChainTip()
        XCTAssertEqual(tipA, tipB, "Out-of-order delivery must still converge")
    }
}

// MARK: - Test Helpers

private struct LocalTestFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw FetcherError.notFound(rawCid)
    }
}

private actor TestCASWorker: AcornCASWorker {
    var near: (any AcornCASWorker)?
    var far: (any AcornCASWorker)?
    var timeout: Duration? { nil }
    private var store: [ContentIdentifier: Data] = [:]

    func has(cid: ContentIdentifier) -> Bool { store[cid] != nil }
    func getLocal(cid: ContentIdentifier) async -> Data? { store[cid] }
    func storeLocal(cid: ContentIdentifier, data: Data) async { store[cid] = data }
}
