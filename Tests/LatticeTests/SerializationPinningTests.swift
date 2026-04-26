import XCTest
@testable import Lattice
import cashew
import UInt256

@MainActor
final class SerializationPinningTests: XCTestCase {

    private func deterministicSpec() -> ChainSpec {
        ChainSpec(
            directory: "Nexus",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 210_000,
            difficultyAdjustmentWindow: 120
        )
    }

    private func deterministicGenesis() async throws -> (block: Block, cid: String) {
        let fetcher = StorableFetcher()
        let spec = deterministicSpec()
        let block = try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: 1_000_000_000_000,
            difficulty: UInt256.max,
            nonce: 0,
            version: 1,
            fetcher: fetcher
        )
        let cid = VolumeImpl<Block>(node: block).rawCID
        return (block, cid)
    }

    // MARK: - Genesis block CID is deterministic

    func testGenesisCIDIsDeterministic() async throws {
        let (_, cid1) = try await deterministicGenesis()
        let (_, cid2) = try await deterministicGenesis()
        XCTAssertEqual(cid1, cid2, "same inputs must produce the same genesis CID")
    }

    // MARK: - Block serialization round-trip preserves identity

    func testBlockSerializationRoundTrip() async throws {
        let (block, originalCID) = try await deterministicGenesis()

        guard let data = block.toData() else {
            return XCTFail("block.toData() returned nil")
        }
        guard let restored = Block(data: data) else {
            return XCTFail("Block(data:) returned nil")
        }

        let restoredCID = VolumeImpl<Block>(node: restored).rawCID
        XCTAssertEqual(originalCID, restoredCID,
            "round-tripped block must have identical CID")
    }

    // MARK: - PoW hash is deterministic

    func testPoWHashIsDeterministic() async throws {
        let (block1, _) = try await deterministicGenesis()
        let (block2, _) = try await deterministicGenesis()
        XCTAssertEqual(
            block1.getDifficultyHash(),
            block2.getDifficultyHash(),
            "same block must produce identical PoW hash"
        )
    }

    // MARK: - Golden CID pinning

    func testGenesisCIDMatchesGolden() async throws {
        let (_, cid) = try await deterministicGenesis()

        let golden = "baguqeeranl5klzkj5psorfq62jbeb2nbinvmbrrrontirzou4n5qmbjuu5ta"
        XCTAssertEqual(cid, golden,
            "genesis CID changed — this is a consensus-breaking change. If intentional, update the golden value.")
    }

    // MARK: - Golden PoW hash pinning

    func testPoWHashMatchesGolden() async throws {
        let (block, _) = try await deterministicGenesis()
        let hash = block.getDifficultyHash()
        let hashHex = hash.toHexString()

        let golden = "d267fedac08730cb7359ac8aeea2e5201adf61a1b27ea7d393098eb95092f63f"
        XCTAssertEqual(hashHex, golden,
            "PoW hash changed — the preimage construction changed. If intentional, update the golden value.")
    }

    // MARK: - Serialization byte stability

    func testSerializedBytesAreStable() async throws {
        let (block, _) = try await deterministicGenesis()
        guard let data1 = block.toData() else { return XCTFail("toData nil") }
        guard let data2 = block.toData() else { return XCTFail("toData nil") }
        XCTAssertEqual(data1, data2,
            "repeated serialization of the same block must produce identical bytes")
    }

    // MARK: - childBlocks CID stability

    func testChildBlocksCIDStability() async throws {
        let emptyChildren1 = BlockBuilder.buildChildBlocksDictionary([:])
        let emptyChildren2 = BlockBuilder.buildChildBlocksDictionary([:])
        XCTAssertEqual(emptyChildren1.rawCID, emptyChildren2.rawCID,
            "empty childBlocks dict must have a stable CID")
    }

    func testChildBlocksCIDWithContent() async throws {
        let fetcher = StorableFetcher()
        let childSpec = ChainSpec(
            directory: "Child",
            maxNumberOfTransactionsPerBlock: 50,
            maxStateGrowth: 50_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 512,
            halvingInterval: 100_000
        )
        let child = try await BlockBuilder.buildGenesis(
            spec: childSpec,
            timestamp: 1_000_000_000_000,
            difficulty: UInt256.max,
            nonce: 0,
            fetcher: fetcher
        )

        let dict1 = BlockBuilder.buildChildBlocksDictionary(["Child": child])
        let dict2 = BlockBuilder.buildChildBlocksDictionary(["Child": child])
        XCTAssertEqual(dict1.rawCID, dict2.rawCID,
            "childBlocks dict with same content must have identical CID")
    }

    // MARK: - Block with child blocks has stable preimage

    func testBlockWithChildrenHasStablePoW() async throws {
        let fetcher = StorableFetcher()
        let spec = deterministicSpec()
        let childSpec = ChainSpec(
            directory: "Child",
            maxNumberOfTransactionsPerBlock: 50,
            maxStateGrowth: 50_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 512,
            halvingInterval: 100_000
        )

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000_000_000,
            difficulty: UInt256.max, nonce: 0, fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: 1_000_000_000_000,
            difficulty: UInt256.max, nonce: 0, fetcher: fetcher
        )

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis,
            childBlocks: ["Child": childGenesis],
            timestamp: 1_000_000_001_000,
            fetcher: fetcher
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: genesis,
            childBlocks: ["Child": childGenesis],
            timestamp: 1_000_000_001_000,
            fetcher: fetcher
        )

        XCTAssertEqual(
            block1.getDifficultyHash(),
            block2.getDifficultyHash(),
            "block with child blocks must produce identical PoW hash from same inputs"
        )
        XCTAssertEqual(
            block1.childBlocks.rawCID,
            block2.childBlocks.rawCID,
            "childBlocks CID must be deterministic"
        )

        let cid1 = VolumeImpl<Block>(node: block1).rawCID
        let cid2 = VolumeImpl<Block>(node: block2).rawCID
        XCTAssertEqual(cid1, cid2,
            "block CID with embedded children must be deterministic")
    }

    // MARK: - Version field preserved across round-trip

    func testVersionFieldPreserved() async throws {
        let (block, _) = try await deterministicGenesis()
        XCTAssertEqual(block.version, 1)

        guard let data = block.toData(), let restored = Block(data: data) else {
            return XCTFail("round-trip failed")
        }
        XCTAssertEqual(restored.version, 1,
            "version field must survive serialization round-trip")
    }
}
