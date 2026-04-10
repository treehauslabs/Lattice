import XCTest
@testable import Lattice
import UInt256

// MARK: - Test Helpers

func makeBlockMeta(
    hash: String,
    previousHash: String? = nil,
    index: UInt64,
    parentChainBlocks: [String: UInt64?] = [:],
    childBlockHashes: [String] = [],
    work: UInt256 = UInt256(1)
) -> BlockMeta {
    BlockMeta(
        blockInfo: BlockInfoImpl(
            blockHash: hash,
            previousBlockHash: previousHash,
            blockIndex: index,
            work: work
        ),
        parentChainBlocks: parentChainBlocks,
        childBlockHashes: childBlockHashes
    )
}

func makeChain(
    blocks: [BlockMeta],
    mainChainHashes: Set<String>? = nil,
    parentChainMap: [String: String] = [:]
) -> ChainState {
    let tip = blocks.max(by: { a, b in
        if mainChainHashes != nil {
            let aOnMain = mainChainHashes!.contains(a.blockHash)
            let bOnMain = mainChainHashes!.contains(b.blockHash)
            if aOnMain != bOnMain { return !aOnMain }
        }
        return a.blockIndex < b.blockIndex
    })!
    let mainHashes = mainChainHashes ?? Set(blocks.map { $0.blockHash })
    var indexMap: [UInt64: Set<String>] = [:]
    var hashMap: [String: BlockMeta] = [:]
    for block in blocks {
        indexMap[block.blockIndex, default: Set()].insert(block.blockHash)
        hashMap[block.blockHash] = block
    }
    return ChainState(
        chainTip: tip.blockHash,
        mainChainHashes: mainHashes,
        indexToBlockHash: indexMap,
        hashToBlock: hashMap,
        parentChainBlockHashToBlockHash: parentChainMap
    )
}

func makeLinearChain(length: Int, prefix: String = "block") -> (ChainState, [BlockMeta]) {
    var blocks: [BlockMeta] = []
    for i in 0..<length {
        let hash = "\(prefix)_\(i)"
        let prevHash: String? = i == 0 ? nil : "\(prefix)_\(i - 1)"
        let meta = makeBlockMeta(hash: hash, previousHash: prevHash, index: UInt64(i))
        blocks.append(meta)
    }
    for i in 0..<(blocks.count - 1) {
        blocks[i].childBlockHashes = [blocks[i + 1].blockHash]
    }
    let chain = makeChain(blocks: blocks)
    return (chain, blocks)
}

// MARK: - compareWork Tests

final class CompareWorkTests: XCTestCase {

    func testMoreWorkWinsWithNoParent() {
        XCTAssertTrue(compareWork((UInt256(5), nil), (UInt256(10), nil)))
        XCTAssertFalse(compareWork((UInt256(10), nil), (UInt256(5), nil)))
    }

    func testEqualWorkNoParentIsNotBetter() {
        XCTAssertFalse(compareWork((UInt256(10), nil), (UInt256(10), nil)))
    }

    func testParentAnchoringBeatsNoAnchoring() {
        XCTAssertTrue(compareWork((UInt256(100), nil), (UInt256(5), 50)))
    }

    func testNoAnchoringCannotBeatAnchoring() {
        XCTAssertFalse(compareWork((UInt256(5), 50), (UInt256(100), nil)))
    }

    func testLowerParentIndexWins() {
        XCTAssertTrue(compareWork((UInt256(10), 100), (UInt256(10), 50)))
        XCTAssertFalse(compareWork((UInt256(10), 50), (UInt256(10), 100)))
    }

    func testEqualParentIndexHigherWorkWins() {
        XCTAssertTrue(compareWork((UInt256(10), 50), (UInt256(20), 50)))
        XCTAssertFalse(compareWork((UInt256(20), 50), (UInt256(10), 50)))
    }

    func testParentIndexZeroBeatsAll() {
        XCTAssertTrue(compareWork((UInt256(1000), 1), (UInt256(1), 0)))
    }

    func testAsymmetry() {
        XCTAssertTrue(compareWork((UInt256(10), nil), (UInt256(20), nil)))
        XCTAssertFalse(compareWork((UInt256(20), nil), (UInt256(10), nil)))
    }
}

// MARK: - BlockMeta Weights Tests

final class BlockMetaWeightsTests: XCTestCase {

    func testWeightsWithNoParent() {
        let meta = makeBlockMeta(hash: "a", index: 42)
        XCTAssertEqual(meta.weights, [0, 42])
    }

    func testWeightsWithParent() {
        let meta = makeBlockMeta(hash: "a", index: 42, parentChainBlocks: ["p1": 10])
        XCTAssertEqual(meta.weights, [UInt64.max - 10, 42])
    }

    func testWeightsWithMultipleParents() {
        let meta = makeBlockMeta(hash: "a", index: 42, parentChainBlocks: ["p1": 100, "p2": 50, "p3": 200])
        XCTAssertEqual(meta.parentIndex, 50)
        XCTAssertEqual(meta.weights, [UInt64.max - 50, 42])
    }

    func testWeightsWithNilParentValues() {
        let meta = makeBlockMeta(hash: "a", index: 42, parentChainBlocks: ["p1": nil, "p2": 30])
        XCTAssertEqual(meta.parentIndex, 30)
    }

    func testWeightsAllNilParentValues() {
        let meta = makeBlockMeta(hash: "a", index: 42, parentChainBlocks: ["p1": nil])
        XCTAssertNil(meta.parentIndex)
        XCTAssertEqual(meta.weights, [0, 42])
    }
}

// MARK: - minOptional Tests

final class MinOptionalTests: XCTestCase {
    func testBothPresent() { XCTAssertEqual(minOptional(3, 7), 3) }
    func testLeftOnly() { XCTAssertEqual(minOptional(5, nil), 5) }
    func testRightOnly() { XCTAssertEqual(minOptional(nil, 9), 9) }
    func testBothNil() { XCTAssertNil(minOptional(nil, nil) as UInt64?) }
}

// MARK: - ChainState Tests (async, run via @MainActor)

@MainActor
final class ChainStateGenesisTests: XCTestCase {

    func testFromGenesisCreatesValidState() async {
        let (chain, _) = makeLinearChain(length: 1)
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "block_0")
        let highest = await chain.getHighestBlockIndex()
        XCTAssertEqual(highest, 0)
        let contains = await chain.contains(blockHash: "block_0")
        XCTAssertTrue(contains)
        let onMain = await chain.isOnMainChain(hash: "block_0")
        XCTAssertTrue(onMain)
    }

    func testFromGenesisDoesNotContainOtherBlocks() async {
        let (chain, _) = makeLinearChain(length: 1)
        let contains = await chain.contains(blockHash: "nonexistent")
        XCTAssertFalse(contains)
    }
}

@MainActor
final class LinearChainTests: XCTestCase {

    func testLinearChainTipIsHighest() async {
        let (chain, _) = makeLinearChain(length: 5)
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "block_4")
        let highest = await chain.getHighestBlockIndex()
        XCTAssertEqual(highest, 4)
    }

    func testAllBlocksOnMainChain() async {
        let (chain, blocks) = makeLinearChain(length: 5)
        for block in blocks {
            let onMain = await chain.isOnMainChain(hash: block.blockHash)
            XCTAssertTrue(onMain, "\(block.blockHash) should be on main chain")
        }
    }

    func testGetConsensusBlock() async {
        let (chain, _) = makeLinearChain(length: 3)
        let block = await chain.getConsensusBlock(hash: "block_1")
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.blockIndex, 1)
        XCTAssertEqual(block?.previousBlockHash, "block_0")
    }

    func testGetConsensusBlockNotFound() async {
        let (chain, _) = makeLinearChain(length: 3)
        let block = await chain.getConsensusBlock(hash: "nonexistent")
        XCTAssertNil(block)
    }
}

@MainActor
final class ForkChoiceTests: XCTestCase {

    func testLongerForkTriggersReorg() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2, childBlockHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", index: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2, childBlockHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", index: 3, childBlockHashes: ["B4"])
        let b4 = makeBlockMeta(hash: "B4", previousHash: "B3", index: 4)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, b1, b2, b3, b4],
            mainChainHashes: Set(["G", "A1", "A2", "A3"])
        )

        let block = await chain.getConsensusBlock(hash: "B4")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        XCTAssertTrue(reorg!.mainChainBlocksAdded.keys.contains("B4"))
        XCTAssertTrue(reorg!.mainChainBlocksRemoved.contains("A3"))

        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, "B4")
    }

    func testShorterForkDoesNotReorg() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2, childBlockHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", index: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, b1, b2],
            mainChainHashes: Set(["G", "A1", "A2", "A3"])
        )

        let block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNil(reorg)
    }

    func testEqualLengthForkDoesNotReorg() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, b1, b2],
            mainChainHashes: Set(["G", "A1", "A2"])
        )

        let block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNil(reorg)
    }

    func testParentAnchoredForkBeatsLongerChain() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2, childBlockHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", index: 3, childBlockHashes: ["A4"])
        let a4 = makeBlockMeta(hash: "A4", previousHash: "A3", index: 4)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, parentChainBlocks: ["p5": 5], childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, a4, b1, b2],
            mainChainHashes: Set(["G", "A1", "A2", "A3", "A4"]),
            parentChainMap: ["p5": "B1"]
        )

        let block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, "B2")
    }

    func testLowerParentIndexWinsForkChoice() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, parentChainBlocks: ["p100": 100], childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, parentChainBlocks: ["p50": 50], childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, b1, b2],
            mainChainHashes: Set(["G", "A1", "A2"]),
            parentChainMap: ["p100": "A1", "p50": "B1"]
        )

        let block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, "B2")
    }
}

@MainActor
final class OrphanDetectionTests: XCTestCase {

    func testOrphanConnectedToMainChain() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2, childBlockHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", index: 3)

        let chain = makeChain(
            blocks: [g, a1, b1, b2, b3],
            mainChainHashes: Set(["G", "A1"])
        )

        let earliest = await chain.findEarliestOrphanConnectedToMainChain(blockHeader: "B3")
        XCTAssertEqual(earliest, "B1")
    }

    func testOrphanWithMissingAncestorReturnsNil() async {
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2, childBlockHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", index: 3)

        let chain = makeChain(blocks: [b2, b3], mainChainHashes: Set())
        let earliest = await chain.findEarliestOrphanConnectedToMainChain(blockHeader: "B3")
        XCTAssertNil(earliest)
    }

    func testGenesisBlockIsValidOrphanRoot() async {
        let g = makeBlockMeta(hash: "alt_g", index: 0, childBlockHashes: ["B1"])
        let b1 = makeBlockMeta(hash: "B1", previousHash: "alt_g", index: 1)

        let chain = makeChain(blocks: [g, b1], mainChainHashes: Set())
        let earliest = await chain.findEarliestOrphanConnectedToMainChain(blockHeader: "B1")
        XCTAssertEqual(earliest, "alt_g")
    }
}

@MainActor
final class ParentReorgPropagationTests: XCTestCase {

    func testPropagateParentReorgUpdatesReferences() async {
        let g = makeBlockMeta(hash: "CG", index: 0, childBlockHashes: ["C1"])
        let c1 = makeBlockMeta(hash: "C1", previousHash: "CG", index: 1, parentChainBlocks: ["P_5": 5])

        let chain = makeChain(
            blocks: [g, c1],
            mainChainHashes: Set(["CG", "C1"]),
            parentChainMap: ["P_5": "C1"]
        )

        let reorg = Reorganization(mainChainBlocksAdded: ["P_new": 3], mainChainBlocksRemoved: Set(["P_5"]))
        let childReorg = await chain.propagateParentReorg(reorg: reorg)
        XCTAssertNil(childReorg)

        let c1Block = await chain.getConsensusBlock(hash: "C1")!
        XCTAssertNil(c1Block.parentChainBlocks["P_5"] as Any?)
    }

    func testPropagateParentReorgTriggersChildReorg() async {
        let g = makeBlockMeta(hash: "CG", index: 0, childBlockHashes: ["CA1", "CB1"])
        let ca1 = makeBlockMeta(hash: "CA1", previousHash: "CG", index: 1)
        let cb1 = makeBlockMeta(hash: "CB1", previousHash: "CG", index: 1, parentChainBlocks: [:])

        let chain = makeChain(
            blocks: [g, ca1, cb1],
            mainChainHashes: Set(["CG", "CA1"]),
            parentChainMap: ["P_new": "CB1"]
        )

        let reorg = Reorganization(mainChainBlocksAdded: ["P_new": 10], mainChainBlocksRemoved: Set())
        let childReorg = await chain.propagateParentReorg(reorg: reorg)
        XCTAssertNotNil(childReorg)
        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, "CB1")
    }

    func testPropagateNoAffectedBlocksReturnsNil() async {
        let g = makeBlockMeta(hash: "G", index: 0)
        let chain = makeChain(blocks: [g])

        let reorg = Reorganization(mainChainBlocksAdded: ["unrelated": 5], mainChainBlocksRemoved: Set(["also_unrelated"]))
        let result = await chain.propagateParentReorg(reorg: reorg)
        XCTAssertNil(result)
    }
}

@MainActor
final class DuplicateBlockTests: XCTestCase {

    func testDuplicateWithoutParentInfoDiscarded() async {
        let (chain, _) = makeLinearChain(length: 3)
        let result = await chain.handleDuplicateBlock(parentBlockHeaderAndIndex: nil, blockHash: "block_1")
        XCTAssertFalse(result.addedBlock)
        XCTAssertNil(result.reorganization)
    }

    func testDuplicateAddsParentChainReference() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1)

        let chain = makeChain(
            blocks: [g, a1, b1],
            mainChainHashes: Set(["G", "A1"])
        )

        let result = await chain.handleDuplicateBlock(parentBlockHeaderAndIndex: ("parent_10", 10), blockHash: "B1")
        XCTAssertNotNil(result.reorganization)
        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, "B1")
    }

    func testDuplicateAlreadyOnMainChainDiscarded() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1)

        let chain = makeChain(blocks: [g, a1], mainChainHashes: Set(["G", "A1"]))
        let result = await chain.handleDuplicateBlock(parentBlockHeaderAndIndex: ("parent_10", 10), blockHash: "A1")
        XCTAssertFalse(result.addedBlock)
        XCTAssertNil(result.reorganization)
    }
}

@MainActor
final class ChainWithMostWorkTests: XCTestCase {

    func testSingleBlockChain() async {
        let g = makeBlockMeta(hash: "G", index: 0)
        let chain = makeChain(blocks: [g])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertEqual(work.cumulativeWork, UInt256(1))
        XCTAssertNil(work.parentIndex)
        XCTAssertEqual(work.blocks, Set(["G"]))
    }

    func testLinearChainWork() async {
        let (chain, blocks) = makeLinearChain(length: 4)
        let work = await chain.chainWithMostWork(startingBlock: blocks[0])
        XCTAssertEqual(work.cumulativeWork, UInt256(4))
        XCTAssertEqual(work.blocks.count, 4)
    }

    func testForkedChainPicksMoreWork() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2, childBlockHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", index: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertEqual(work.cumulativeWork, UInt256(4))
        XCTAssertTrue(work.blocks.contains("B3"))
        XCTAssertFalse(work.blocks.contains("A1"))
    }

    func testForkedChainPicksParentAnchored() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2, childBlockHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", index: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, parentChainBlocks: ["p": 5])

        let chain = makeChain(blocks: [g, a1, a2, a3, b1])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertEqual(work.parentIndex, 5)
        XCTAssertTrue(work.blocks.contains("B1"))
        XCTAssertFalse(work.blocks.contains("A1"))
    }
}

// MARK: - Smoke Tests / Invariant Checks

@MainActor
final class ChainInvariantTests: XCTestCase {

    func testTipAlwaysOnMainChain() async {
        let (chain, _) = makeLinearChain(length: 10)
        let tip = await chain.getMainChainTip()
        let onMain = await chain.isOnMainChain(hash: tip)
        XCTAssertTrue(onMain)
    }

    func testTipAlwaysInBlockMap() async {
        let (chain, _) = makeLinearChain(length: 10)
        let tip = await chain.getMainChainTip()
        let block = await chain.getConsensusBlock(hash: tip)
        XCTAssertNotNil(block)
    }

    func testMainChainConnectivity() async {
        let (chain, blocks) = makeLinearChain(length: 10)
        for block in blocks {
            if let prevHash = block.previousBlockHash {
                let prevOnMain = await chain.isOnMainChain(hash: prevHash)
                let currentOnMain = await chain.isOnMainChain(hash: block.blockHash)
                if currentOnMain {
                    XCTAssertTrue(prevOnMain, "\(block.blockHash) on main but parent \(prevHash) not")
                }
            }
        }
    }

    func testReorgTipIsHighestInWinningFork() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2, childBlockHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", index: 3)

        let chain = makeChain(blocks: [g, a1, b1, b2, b3], mainChainHashes: Set(["G", "A1"]))
        let block = await chain.getConsensusBlock(hash: "B3")!
        let _ = await chain.checkForReorg(block: block)

        let tip = await chain.getMainChainTip()
        let tipBlock = await chain.getConsensusBlock(hash: tip)!
        let highest = await chain.getHighestBlockIndex()
        XCTAssertEqual(tipBlock.blockIndex, highest)
    }

    func testReorgRemovesOldMainChainBlocks() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2, childBlockHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", index: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3], mainChainHashes: Set(["G", "A1", "A2"]))
        let block = await chain.getConsensusBlock(hash: "B3")!
        let _ = await chain.checkForReorg(block: block)

        let a1OnMain = await chain.isOnMainChain(hash: "A1")
        XCTAssertFalse(a1OnMain)
        let a2OnMain = await chain.isOnMainChain(hash: "A2")
        XCTAssertFalse(a2OnMain)
        let gOnMain = await chain.isOnMainChain(hash: "G")
        XCTAssertTrue(gOnMain)
    }

    func testReorgStructContents() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2)

        let chain = makeChain(blocks: [g, a1, b1, b2], mainChainHashes: Set(["G", "A1"]))
        let block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: block)

        XCTAssertNotNil(reorg)
        XCTAssertTrue(reorg!.mainChainBlocksAdded.keys.contains("B1"))
        XCTAssertTrue(reorg!.mainChainBlocksAdded.keys.contains("B2"))
        XCTAssertFalse(reorg!.mainChainBlocksAdded.keys.contains("G"))
        XCTAssertTrue(reorg!.mainChainBlocksRemoved.contains("A1"))
        XCTAssertFalse(reorg!.mainChainBlocksRemoved.contains("G"))
    }
}

// MARK: - Nakamoto Consensus / Industry Standard Tests

@MainActor
final class NakamotoConsensusTests: XCTestCase {

    func testNakamotoLongestChainRule() async {
        let (chain, _) = makeLinearChain(length: 6, prefix: "main")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "main_5")
        for i in 0..<6 {
            let onMain = await chain.isOnMainChain(hash: "main_\(i)")
            XCTAssertTrue(onMain)
        }
    }

    func testSelfishMiningReorg() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["P1", "H1"])
        let p1 = makeBlockMeta(hash: "P1", previousHash: "G", index: 1, childBlockHashes: ["P2"])
        let p2 = makeBlockMeta(hash: "P2", previousHash: "P1", index: 2, childBlockHashes: ["P3"])
        let p3 = makeBlockMeta(hash: "P3", previousHash: "P2", index: 3)
        let h1 = makeBlockMeta(hash: "H1", previousHash: "G", index: 1, childBlockHashes: ["H2"])
        let h2 = makeBlockMeta(hash: "H2", previousHash: "H1", index: 2, childBlockHashes: ["H3"])
        let h3 = makeBlockMeta(hash: "H3", previousHash: "H2", index: 3, childBlockHashes: ["H4"])
        let h4 = makeBlockMeta(hash: "H4", previousHash: "H3", index: 4)

        let chain = makeChain(blocks: [g, p1, p2, p3, h1, h2, h3, h4], mainChainHashes: Set(["G", "P1", "P2", "P3"]))
        let block = await chain.getConsensusBlock(hash: "H4")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let selfishTip = await chain.getMainChainTip()
        XCTAssertEqual(selfishTip, "H4")

        for name in ["P1", "P2", "P3"] {
            let onMain = await chain.isOnMainChain(hash: name)
            XCTAssertFalse(onMain, "\(name) should be off main chain")
        }
        for name in ["H1", "H2", "H3", "H4"] {
            let onMain = await chain.isOnMainChain(hash: name)
            XCTAssertTrue(onMain, "\(name) should be on main chain")
        }
        let gOnMainSelfish = await chain.isOnMainChain(hash: "G")
        XCTAssertTrue(gOnMainSelfish)
    }

    func testFirstSeenTieBreaking() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2, childBlockHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", index: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2, childBlockHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", index: 3)

        let chain = makeChain(blocks: [g, a1, a2, a3, b1, b2, b3], mainChainHashes: Set(["G", "A1", "A2", "A3"]))
        let block = await chain.getConsensusBlock(hash: "B3")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNil(reorg, "Equal-length fork must not trigger reorg")
        let tieTip = await chain.getMainChainTip()
        XCTAssertEqual(tieTip, "A3")
    }

    func testDeepReorgFromGenesis() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["M1", "F1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G", index: 1, childBlockHashes: ["M2"])
        let m2 = makeBlockMeta(hash: "M2", previousHash: "M1", index: 2)
        let f1 = makeBlockMeta(hash: "F1", previousHash: "G", index: 1, childBlockHashes: ["F2"])
        let f2 = makeBlockMeta(hash: "F2", previousHash: "F1", index: 2, childBlockHashes: ["F3"])
        let f3 = makeBlockMeta(hash: "F3", previousHash: "F2", index: 3, childBlockHashes: ["F4"])
        let f4 = makeBlockMeta(hash: "F4", previousHash: "F3", index: 4, childBlockHashes: ["F5"])
        let f5 = makeBlockMeta(hash: "F5", previousHash: "F4", index: 5)

        let chain = makeChain(blocks: [g, m1, m2, f1, f2, f3, f4, f5], mainChainHashes: Set(["G", "M1", "M2"]))
        let block = await chain.getConsensusBlock(hash: "F5")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let deepTip = await chain.getMainChainTip()
        XCTAssertEqual(deepTip, "F5")
        let deepHighest = await chain.getHighestBlockIndex()
        XCTAssertEqual(deepHighest, 5)
    }

    func testMultipleConcurrentForks() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1", "C1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2, childBlockHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", index: 3)
        let c1 = makeBlockMeta(hash: "C1", previousHash: "G", index: 1)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3, c1], mainChainHashes: Set(["G", "A1", "A2"]))
        let block = await chain.getConsensusBlock(hash: "B3")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let concurrentTip = await chain.getMainChainTip()
        XCTAssertEqual(concurrentTip, "B3")
    }

    func testMidChainFork() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["M1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G", index: 1, childBlockHashes: ["M2"])
        let m2 = makeBlockMeta(hash: "M2", previousHash: "M1", index: 2, childBlockHashes: ["M3", "F1"])
        let m3 = makeBlockMeta(hash: "M3", previousHash: "M2", index: 3)
        let f1 = makeBlockMeta(hash: "F1", previousHash: "M2", index: 3, childBlockHashes: ["F2"])
        let f2 = makeBlockMeta(hash: "F2", previousHash: "F1", index: 4, childBlockHashes: ["F3"])
        let f3 = makeBlockMeta(hash: "F3", previousHash: "F2", index: 5)

        let chain = makeChain(blocks: [g, m1, m2, m3, f1, f2, f3], mainChainHashes: Set(["G", "M1", "M2", "M3"]))
        let block = await chain.getConsensusBlock(hash: "F3")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let midTip = await chain.getMainChainTip()
        XCTAssertEqual(midTip, "F3")
        let m1OnMain = await chain.isOnMainChain(hash: "M1")
        XCTAssertTrue(m1OnMain)
        let m2OnMain = await chain.isOnMainChain(hash: "M2")
        XCTAssertTrue(m2OnMain)
        let m3OnMain = await chain.isOnMainChain(hash: "M3")
        XCTAssertFalse(m3OnMain)
    }
}

// MARK: - Lattice-Specific Consensus Tests

@MainActor
final class LatticeConsensusTests: XCTestCase {

    func testParentChainOverridesLength() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2, childBlockHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", index: 3, childBlockHashes: ["A4"])
        let a4 = makeBlockMeta(hash: "A4", previousHash: "A3", index: 4, childBlockHashes: ["A5"])
        let a5 = makeBlockMeta(hash: "A5", previousHash: "A4", index: 5)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, parentChainBlocks: ["p10": 10])

        let chain = makeChain(
            blocks: [g, a1, a2, a3, a4, a5, b1],
            mainChainHashes: Set(["G", "A1", "A2", "A3", "A4", "A5"]),
            parentChainMap: ["p10": "B1"]
        )

        let block = await chain.getConsensusBlock(hash: "B1")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg, "Parent-anchored block should beat 5-block unanchored chain")
        let parentOverrideTip = await chain.getMainChainTip()
        XCTAssertEqual(parentOverrideTip, "B1")
    }

    func testEarlierAnchoringWins() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, parentChainBlocks: ["p200": 200], childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, parentChainBlocks: ["p50": 50])

        let chain = makeChain(
            blocks: [g, a1, a2, b1],
            mainChainHashes: Set(["G", "A1", "A2"]),
            parentChainMap: ["p200": "A1", "p50": "B1"]
        )

        let block = await chain.getConsensusBlock(hash: "B1")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let earlierTip = await chain.getMainChainTip()
        XCTAssertEqual(earlierTip, "B1")
    }

    func testSameParentIndexIncumbentHolds() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, parentChainBlocks: ["p50a": 50])
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, parentChainBlocks: ["p50b": 50])

        let chain = makeChain(
            blocks: [g, a1, b1],
            mainChainHashes: Set(["G", "A1"]),
            parentChainMap: ["p50a": "A1", "p50b": "B1"]
        )

        let block = await chain.getConsensusBlock(hash: "B1")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNil(reorg)
    }

    func testLateAnchoringTriggersReorg() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1)

        let chain = makeChain(
            blocks: [g, a1, a2, b1],
            mainChainHashes: Set(["G", "A1", "A2"])
        )

        let block = await chain.getConsensusBlock(hash: "B1")!
        let lateReorg = await chain.checkForReorg(block: block)
        XCTAssertNil(lateReorg)

        let result = await chain.handleDuplicateBlock(parentBlockHeaderAndIndex: ("parent_5", 5), blockHash: "B1")
        XCTAssertNotNil(result.reorganization)
        let lateTip = await chain.getMainChainTip()
        XCTAssertEqual(lateTip, "B1")
    }

    func testAnchoringAtZeroBeatsAll() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, parentChainBlocks: ["p1": 1], childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, parentChainBlocks: ["p0": 0])

        let chain = makeChain(
            blocks: [g, a1, a2, b1],
            mainChainHashes: Set(["G", "A1", "A2"]),
            parentChainMap: ["p1": "A1", "p0": "B1"]
        )

        let block = await chain.getConsensusBlock(hash: "B1")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let zeroTip = await chain.getMainChainTip()
        XCTAssertEqual(zeroTip, "B1")
    }
}

// MARK: - Edge Case Tests

@MainActor
final class EdgeCaseTests: XCTestCase {

    func testSingleBlockNoForks() async {
        let g = makeBlockMeta(hash: "G", index: 0)
        let chain = makeChain(blocks: [g])
        let singleTip = await chain.getMainChainTip()
        XCTAssertEqual(singleTip, "G")
        let singleHighest = await chain.getHighestBlockIndex()
        XCTAssertEqual(singleHighest, 0)
    }

    func testNonexistentBlockReturnsNil() async {
        let (chain, _) = makeLinearChain(length: 1)
        let nope = await chain.getConsensusBlock(hash: "nope")
        XCTAssertNil(nope)
    }

    func testManyForksFromSameParent() async {
        var allBlocks: [BlockMeta] = []
        var genesisChildren: [String] = []

        for i in 0..<10 {
            let hash = "F\(i)_1"
            genesisChildren.append(hash)
            if i == 5 {
                allBlocks.append(makeBlockMeta(hash: hash, previousHash: "G", index: 1, childBlockHashes: ["F5_2"]))
                allBlocks.append(makeBlockMeta(hash: "F5_2", previousHash: "F5_1", index: 2, childBlockHashes: ["F5_3"]))
                allBlocks.append(makeBlockMeta(hash: "F5_3", previousHash: "F5_2", index: 3))
            } else {
                allBlocks.append(makeBlockMeta(hash: hash, previousHash: "G", index: 1))
            }
        }

        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: genesisChildren)
        allBlocks.insert(g, at: 0)

        let chain = makeChain(blocks: allBlocks, mainChainHashes: Set(["G", "F0_1"]))
        let block = await chain.getConsensusBlock(hash: "F5_3")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let manyForksTip = await chain.getMainChainTip()
        XCTAssertEqual(manyForksTip, "F5_3")
    }

    func testLongLinearChain() async {
        let length = 500
        let (chain, _) = makeLinearChain(length: length)
        let longTip = await chain.getMainChainTip()
        XCTAssertEqual(longTip, "block_\(length - 1)")
        let longHighest = await chain.getHighestBlockIndex()
        XCTAssertEqual(longHighest, UInt64(length - 1))
        let containsFirst = await chain.contains(blockHash: "block_0")
        XCTAssertTrue(containsFirst)
        let containsLast = await chain.contains(blockHash: "block_\(length - 1)")
        XCTAssertTrue(containsLast)
    }
}
