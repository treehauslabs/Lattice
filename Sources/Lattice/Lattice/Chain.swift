import cashew

public protocol Chain {
    func getMainChainTip() async throws -> String
    func isOnMainChain(hash: String) async throws -> Bool
    func getBlockHashes(index: UInt64) async throws -> Bool
    func getConsensusBlock(hash: String) async throws -> ConsensusBlock
    func getBlockHashForParentChainBlockHash(hash: String) async throws -> String
    func getParentChainBlocks(hash: String) async throws -> [String: UInt64?]
    func getParentChainIndexForBlock(hash: String) async throws -> UInt64
    func isParentChainBlock(hash: String) async throws -> Bool
    
    func update(block: ConsensusBlock, parentBlockHashAndMainChainIndex: (String, UInt64?)?, parentChainBlocksAdded: [String: String], parentChainBlocksRemoved: [String: String]) async throws -> Set<String>
    func insertBlock(block: ConsensusBlock, parentBlockHashAndMainChainIndex: (String, UInt64?)?) async throws -> Set<String>
    func addParentChainBlock(hash: String, parentChainBlock: String) async throws -> Bool
    func removeParentChainBlock(hash: String, parentChainBlock: String) async throws -> Bool
}

extension Chain {
    func getHighestBlock() async throws -> ConsensusBlock {
        let mainChainTip = try await getMainChainTip()
        return try await getConsensusBlock(hash: mainChainTip)
    }
    
    func getHighestBlockIndex() async throws -> UInt64 {
        let mainChainTip = try await getMainChainTip()
        let blockInfo = try await getConsensusBlock(hash: mainChainTip).blockInfo
        return blockInfo.blockIndex
    }
    
    func addAllParentChainBlocks(parentChainBlocksAdded: [String: String]) async throws -> Set<String> {
        var modifiedBlocks: Set<String> = Set()
        for (parentChainBlock, hash) in parentChainBlocksAdded {
            if try await addParentChainBlock(hash: hash, parentChainBlock: parentChainBlock) {
                modifiedBlocks.insert(hash)
            }
        }
        return modifiedBlocks
    }
    
    func removeAllParentChainBlocks(parentChainBlocksRemoved: [String: String]) async throws -> Set<String> {
        var modifiedBlocks: Set<String> = Set()
        for (parentChainBlock, hash) in parentChainBlocksRemoved {
            if try await removeParentChainBlock(hash: hash, parentChainBlock: parentChainBlock) {
                modifiedBlocks.insert(hash)
            }
        }
        return modifiedBlocks
    }
    
    func update(block: ConsensusBlock, parentBlockHashAndMainChainIndex: (String, UInt64?)?, parentChainBlocksAdded: [String: String], parentChainBlocksRemoved: [String: String]) async throws -> Set<String> {
        let modifiedBlocksAfterInsert = try await insertBlock(block: block, parentBlockHashAndMainChainIndex: parentBlockHashAndMainChainIndex)
        let modifiedBlocksAfterAdding = try await addAllParentChainBlocks(parentChainBlocksAdded: parentChainBlocksAdded)
        let modifiedBlocksAfterRemoving = try await removeAllParentChainBlocks(parentChainBlocksRemoved: parentChainBlocksRemoved)
        return modifiedBlocksAfterInsert.union(modifiedBlocksAfterAdding.union(modifiedBlocksAfterRemoving))
    }

    
}

public protocol ConsensusBlock {
    var blockInfo: BlockInfo { get }
    var weights: [UInt64] { get }
}

public protocol BlockInfo {
    var blockHash: String { get }
    var previousBlockHash: String { get }
    var blockIndex: UInt64 { get }
}

//public struct BlockMeta: ConsensusBlock {
//    
//}

//public let RECENT_BLOCK_DISTANCE = UInt64(1000)
//public typealias BlockHeader = HeaderImpl<Block>
//
//public actor Chain {
//    var chainTip: String
//    var mainChainHashes: Set<String>
//    var indexToBlockHash: [UInt64: Set<String>]
//    var hashToBlock: [String: BlockMeta]
//    var parentChainBlockHashToBlockHash: [String: String]
//    var highestBlock: BlockMeta {
//        return hashToBlock[chainTip]!
//    }
//    var highestBlockIndex: UInt64 {
//        return highestBlock.blockIndex
//    }
//    
//    init(chainTip: String, mainChainHashes: Set<String>, indexToBlockHash: [UInt64: Set<String>], hashToBlock: [String : BlockMeta], parentChainBlockHashToBlockHash: [String: String]) {
//        self.chainTip = chainTip
//        self.mainChainHashes = mainChainHashes
//        self.indexToBlockHash = indexToBlockHash
//        self.hashToBlock = hashToBlock
//        self.parentChainBlockHashToBlockHash = parentChainBlockHashToBlockHash
//    }
//    
//    func contains(blockHash: String) -> Bool {
//        return hashToBlock.keys.contains(blockHash)
//    }
//    
//    func submitBlock(parentBlockHeaderAndIndex: (String, UInt64?)?, blockHeader: BlockHeader, block: Block) -> SubmissionResult {
//        if block.index < highestBlockIndex - RECENT_BLOCK_DISTANCE { return SubmissionResult.discarded() }
//        if parentBlockHeaderAndIndex == nil && block.previousBlock == nil { return SubmissionResult.discarded() }
//        let resultAfterInsertingBlock = insertBlock(parentBlockHeaderAndIndex: parentBlockHeaderAndIndex, blockHeader: blockHeader.rawCID, block: block)
//        if !resultAfterInsertingBlock.addedBlock { return resultAfterInsertingBlock }
//        if let parentBlockHeaderAndIndex = parentBlockHeaderAndIndex {
//            addParentBlockHeaderAndIndex(parentBlockHeader: parentBlockHeaderAndIndex.0, parentIndex: parentBlockHeaderAndIndex.1, blockHeader: blockHeader)
//        }
//        if resultAfterInsertingBlock.extendsMainChain { return SubmissionResult.extendsMainChain() }
//        if let previousBlockHeader = block.previousBlock {
//            if mainChainHashes.contains(blockHeader.rawCID) {
//                if chainTip != blockHeader.rawCID {
//                    return SubmissionResult(addedBlock: true, extendsMainChain: true, needsChildBlock: false, reorganization: Reorganization(mainChainBlocksAdded: getMainChainBlocks(blockIndex: block.index), mainChainBlocksRemoved: Set()))
//                }
//                return SubmissionResult.extendsMainChain()
//            }
//            else {
//                if !resultAfterInsertingBlock.needsChildBlock {
//                    if let reorg = checkForReorg(block: BlockMeta(blockIndex: block.index, previousBlockHash: previousBlockHeader.rawCID, blockHash: blockHeader.rawCID, parentChainBlocks: parentBlockHeaderAndIndex == nil ? [:] : [parentBlockHeaderAndIndex!.0: parentBlockHeaderAndIndex!.1], parentBlocks: getParents(hash: blockHeader.rawCID, block: block))) {
//                        return SubmissionResult(addedBlock: true, extendsMainChain: false, needsChildBlock: false, reorganization: reorg)
//                    }
//                }
//                return resultAfterInsertingBlock
//            }
//        }
//        if let reorg = checkForReorg(block: BlockMeta(blockIndex: block.index, previousBlockHash: nil, blockHash: blockHeader.rawCID, parentChainBlocks: parentBlockHeaderAndIndex == nil ? [:] : [parentBlockHeaderAndIndex!.0: parentBlockHeaderAndIndex!.1], parentBlocks: getParents(hash: blockHeader.rawCID, block: block))) {
//            return SubmissionResult(addedBlock: true, extendsMainChain: false, needsChildBlock: false, reorganization: reorg)
//        }
//        return SubmissionResult(addedBlock: true, extendsMainChain: false, needsChildBlock: false, reorganization: nil)
//    }
//    
//    func addParentBlockHeaderAndIndex(parentBlockHeader: String, parentIndex: UInt64?, blockHeader: BlockHeader) {
//        parentChainBlockHashToBlockHash[parentBlockHeader] = blockHeader.rawCID
//        hashToBlock[blockHeader.rawCID]!.parentChainBlocks[parentBlockHeader] = parentIndex
//    }
//    
//    func applyParentReorg(reorg: Reorganization, parentBlockHeaderAndIndex: (String, UInt64?)?, blockHash: String, block: Block) -> SubmissionResult {
//        var tempResult: SubmissionResult
//        if block.index >= highestBlockIndex - RECENT_BLOCK_DISTANCE && (reorg.mainChainBlocksAdded[blockHash] != nil || block.previousBlock != nil && hashToBlock[blockHash] == nil) {
//            tempResult = insertBlock(parentBlockHeaderAndIndex: parentBlockHeaderAndIndex, blockHeader: blockHash, block: block)
//        }
//        updateParentsForReorg(reorg: reorg)
//        var mainChainBlocks = reorg.mainChainBlocksAdded.keys.map { parentChainBlockHashToBlockHash[$0]! }
//        mainChainBlocks.append(blockHash)
//        let earliestOrphanBlocks = getEarliestOrphanBlocksConnectedToMainChain(blockHeaders: mainChainBlocks.filter { !mainChainHashes.contains($0) })
//        let mainChainWorkAtIndexes = getWorkAtMainChainIndexes(indexes: earliestOrphanBlocks.map { $0.blockIndex })
//        let mainChainHighestIndex = highestBlockIndex
//        var currentHighestIndex: UInt64? = nil
//        var currentParent: UInt64? = nil
//        var currentIndex: UInt64 = 0
//        var currentBlocks: Set<String> = Set()
//        
//        for earliestOrphanBlock in earliestOrphanBlocks {
//            let chainWithMostWork = getChainWithMostWork(startingBlock: earliestOrphanBlock)
//            if Chain.compareWork((mainChainHighestIndex, mainChainWorkAtIndexes[earliestOrphanBlock.blockIndex]), (chainWithMostWork.highestIndex, chainWithMostWork.parent)) {
//                if var currentHighestIndex {
//                    if Chain.compareWork((currentHighestIndex, currentParent), (chainWithMostWork.highestIndex, chainWithMostWork.parent)) {
//                        currentHighestIndex = chainWithMostWork.highestIndex
//                        currentParent = chainWithMostWork.parent
//                        currentBlocks = chainWithMostWork.blocks
//                        currentIndex = earliestOrphanBlock.blockIndex
//                    }
//                }
//                else {
//                    currentHighestIndex = chainWithMostWork.highestIndex
//                    currentParent = chainWithMostWork.parent
//                    currentBlocks = chainWithMostWork.blocks
//                    currentIndex = earliestOrphanBlock.blockIndex
//                }
//            }
//        }
//        if currentHighestIndex != nil {
//            return SubmissionResult(addedBlock: tempResult.addedBlock, extendsMainChain: tempResult.extendsMainChain, needsChildBlock: tempResult.needsChildBlock, reorganization: Reorganization(mainChainBlocksAdded: getIndexesForBlocks(blocks: currentBlocks), mainChainBlocksRemoved: getMainChainHashes(blockIndex: currentIndex)))
//        }
//        return tempResult
//    }
//    
//    func getIndexesForBlocks(blocks: Set<String>) -> [String: UInt64] {
//        var blockIndex: [String: UInt64] = [:]
//        for block in blocks {
//            blockIndex[block] = hashToBlock[block]!.blockIndex
//        }
//        return blockIndex
//    }
//    
//    func getMainChainHashes(blockIndex: UInt64) -> Set<String> {
//        var hashes: Set<String> = Set()
//        var currentBlockHeader = chainTip
//        var currentBlock = highestBlock
//        hashes.insert(currentBlockHeader)
//        while (currentBlock.blockIndex > blockIndex) {
//            currentBlockHeader = currentBlock.previousBlockHash!
//            currentBlock = hashToBlock[currentBlockHeader]!
//            hashes.insert(currentBlockHeader)
//        }
//        return hashes
//    }
//    
//    func updateParentsForReorg(reorg: Reorganization) {
//        removeParents(mainChainBlocksRemoved: reorg.mainChainBlocksRemoved)
//        addParents(mainChainBlocksAdded: reorg.mainChainBlocksAdded)
//    }
//    
//    func insertBlock(parentBlockHeaderAndIndex: (String, UInt64?)?, blockHeader: String, block: Block) -> SubmissionResult {
//        addToBlockIndex(hash: blockHeader, block: block)
//        let blockMeta = BlockMeta(blockIndex: block.index, previousBlockHash: block.previousBlock?.rawCID, blockHash: blockHeader, parentChainBlocks: parentBlockHeaderAndIndex == nil ? [:] : [parentBlockHeaderAndIndex!.0: parentBlockHeaderAndIndex!.1], parentBlocks: getParents(hash: blockHeader, block: block))
//        if hashToBlock[blockHeader] != nil {
//            return SubmissionResult(addedBlock: false, extendsMainChain: false, needsChildBlock: false, reorganization: nil)
//        }
//        hashToBlock[blockHeader] = blockMeta
//        guard let previousBlock = block.previousBlock else {
//            return SubmissionResult(addedBlock: true, extendsMainChain: false, needsChildBlock: false, reorganization: nil)
//        }
//        if previousBlock.rawCID == chainTip {
//            setNewTip(block: blockMeta)
//            return SubmissionResult(addedBlock: true, extendsMainChain: true, needsChildBlock: false, reorganization: nil)
//        }
//        if block.previousBlock != nil && hashToBlock[block.previousBlock!.rawCID] == nil && block.index > highestBlockIndex - RECENT_BLOCK_DISTANCE {
//            return SubmissionResult(addedBlock: true, extendsMainChain: false, needsChildBlock: true, reorganization: nil)
//        }
//        return SubmissionResult(addedBlock: true, extendsMainChain: false, needsChildBlock: false, reorganization: nil)
//    }
//    
//    func getMainChainBlocks(blockIndex: UInt64) -> [String: UInt64] {
//        var blocks: [String: UInt64] = [:]
//        var currentBlockHash = chainTip
//        var currentBlock = hashToBlock[currentBlockHash]!
//        blocks[currentBlockHash] = currentBlock.blockIndex
//        while (currentBlock.blockIndex > blockIndex) {
//            currentBlockHash = currentBlock.previousBlockHash!
//            currentBlock = hashToBlock[currentBlockHash]!
//            blocks[currentBlockHash] = currentBlock.blockIndex
//        }
//        return blocks
//    }
//    
//    func duplicateBlock(parentBlockHeaderAndIndex: (String, UInt64?)?, blockHeader: String, block: Block) -> SubmissionResult {
//        if let parentBlockHeaderAndIndex = parentBlockHeaderAndIndex {
//            if parentChainBlockHashToBlockHash[parentBlockHeaderAndIndex.0] != nil {
//                return SubmissionResult.discarded()
//            }
//            parentChainBlockHashToBlockHash[parentBlockHeaderAndIndex.0] = blockHeader
//            guard let parentBlockIndex = parentBlockHeaderAndIndex.1 else {
//                return SubmissionResult.discarded()
//            }
//            var blockMeta = hashToBlock[blockHeader]!
//            blockMeta.parentChainBlocks[parentBlockHeaderAndIndex.0] = parentBlockIndex
//            if blockMeta.parentChainBlocks.values.filter({ $0 != nil }).map({ $0! }).max()! > parentBlockIndex {
//                return SubmissionResult.discarded()
//            }
//            if mainChainHashes.contains(blockHeader) {
//                return SubmissionResult.discarded()
//            }
//            if let reorg = checkForReorg(block: blockMeta) {
//                return SubmissionResult(addedBlock: false, extendsMainChain: false, needsChildBlock: false, reorganization: reorg)
//            }
//        }
//        return SubmissionResult.discarded()
//    }
//    
//    func getParents(hash: String, block: Block) -> [String] {
//        guard let blockHashes = indexToBlockHash[block.index + 1] else { return [] }
//        return blockHashes.filter { hashToBlock[$0]?.previousBlockHash == hash }
//    }
//
//    func addToBlockIndex(hash: String, block: Block) {
//        if var blocksForIndex = indexToBlockHash[block.index] {
//            blocksForIndex.insert(hash)
//        }
//        else {
//            indexToBlockHash[block.index] = Set([hash])
//        }
//    }
//    
//    
//    func getHighestBlockHash(index: UInt64, chain: Set<String>) -> String? {
//        return indexToBlockHash[index]?.first(where: chain.contains(_:))
//    }
//    
//    func getEarliestOrphanBlockConnectedToMainChain(blockHeader: String) -> String? {
//        guard var currentBlock = hashToBlock[blockHeader] else { return nil }
//        while (currentBlock.previousBlockHash != nil && !mainChainHashes.contains(currentBlock.previousBlockHash!)) {
//            if hashToBlock[currentBlock.previousBlockHash!] == nil { return nil }
//            currentBlock = hashToBlock[currentBlock.previousBlockHash!]!
//        }
//        if currentBlock.previousBlockHash == nil {
//            if currentBlock.blockIndex == 0 {
//                return currentBlock.blockHash
//            }
//            return nil
//        }
//        return currentBlock.blockHash
//    }
//    
//    func removeParents(mainChainBlocksRemoved: Set<String>) {
//        for mainChainBlock in mainChainBlocksRemoved {
//            if let blockHash = parentChainBlockHashToBlockHash[mainChainBlock] {
//                hashToBlock[blockHash]?.parentChainBlocks.removeValue(forKey: mainChainBlock)
//            }
//        }
//    }
//
//    func addParents(mainChainBlocksAdded: [String: UInt64]) {
//        for (mainChainBlock, idx) in mainChainBlocksAdded {
//            if let blockHash = parentChainBlockHashToBlockHash[mainChainBlock] {
//                hashToBlock[blockHash]?.parentChainBlocks[mainChainBlock] = idx
//            }
//        }
//    }
//    
//    // return true if right is greater work than left, false otherwise
//    static func compareWork(_ left: (highestIndex: UInt64, parent: UInt64?), _ right: (highestIndex: UInt64, parent: UInt64?)) -> Bool {
//        if let rightResultParent = right.parent {
//            if let leftResultParent = left.parent {
//                if rightResultParent < leftResultParent {
//                    return true
//                }
//            }
//            else {
//                return true
//            }
//        }
//        else {
//            if left.parent == nil {
//                if right.highestIndex > left.highestIndex {
//                    return true
//                }
//            }
//        }
//        return false
//    }
//    
//    func getLowestParentIndex(_ left: UInt64?, _ right: UInt64?) -> UInt64? {
//        if let left = left {
//            if let right = right {
//                return min(left, right)
//            }
//            return left
//        }
//        if let right = right {
//            return right
//        }
//        return nil
//    }
//    
//    func setNewTip(block: BlockMeta) {
//        let newMainChain = getChainWithMostWork(startingBlock: block)
//        let blockHashes = indexToBlockHash[newMainChain.highestIndex]
//        chainTip = blockHashes!.first(where: newMainChain.blocks.contains(_:))!
//        mainChainHashes.formUnion(newMainChain.blocks)
//    }
//    
//    func getChainWithMostWork(startingBlock: BlockMeta) -> (highestIndex: UInt64, parent: UInt64?, blocks: Set<String>) {
//        var currentBlock = startingBlock
//        var lowestParentIndex = startingBlock.parentIndex
//        var blocks = Set<String>()
//        blocks.insert(currentBlock.blockHash)
//        var parentBlocks = currentBlock.parentBlocks
//        while (!parentBlocks.isEmpty) {
//            let firstBlock = hashToBlock[parentBlocks.removeFirst()]!
//            if !parentBlocks.isEmpty {
//                let restOfBlocks = parentBlocks.map { hashToBlock[$0]! }
//                let parentWork = getChainWithMostWork(block: firstBlock, otherBlocks: restOfBlocks)
//                return (highestIndex: parentWork.highestIndex, parent: getLowestParentIndex(parentWork.parent, lowestParentIndex), blocks: parentWork.blocks.union(blocks))
//            }
//            currentBlock = firstBlock
//            blocks.insert(currentBlock.blockHash)
//            lowestParentIndex = getLowestParentIndex(lowestParentIndex, currentBlock.parentIndex)
//            parentBlocks = currentBlock.parentBlocks
//        }
//        return (highestIndex: currentBlock.blockIndex, parent: lowestParentIndex, blocks: blocks)
//    }
//    
//    func getChainWithMostWork(block: BlockMeta, otherBlocks: [BlockMeta]) -> (highestIndex: UInt64, parent: UInt64?, blocks: Set<String>) {
//        var currentMostWork = getChainWithMostWork(startingBlock: block)
//        for fork in otherBlocks {
//            var work = getChainWithMostWork(startingBlock: fork)
//            if Chain.compareWork((highestIndex: work.highestIndex, parent: work.parent), (highestIndex: currentMostWork.highestIndex, parent: currentMostWork.parent)) {
//                currentMostWork = work
//            }
//        }
//        return currentMostWork
//    }
//    
//    func getMainChainWork(blockIndex: UInt64) -> (highestIndex: UInt64, parent: UInt64?, blocks: Set<String>) {
//        var currentBlockHeader = chainTip
//        var currentBlock = highestBlock
//        var currentBlockIndex = highestBlockIndex
//        var lowestParentIndex = hashToBlock[chainTip]!.parentIndex
//        var blocks = Set<String>()
//        blocks.insert(currentBlockHeader)
//        while (currentBlockIndex > blockIndex) {
//            if currentBlock.previousBlockHash == nil { return (highestIndex: highestBlockIndex, parent: lowestParentIndex, blocks: blocks) }
//            currentBlockHeader = currentBlock.previousBlockHash!
//            blocks.insert(currentBlockHeader)
//            currentBlock = hashToBlock[currentBlockHeader]!
//            lowestParentIndex = getLowestParentIndex(lowestParentIndex, currentBlock.parentIndex)
//        }
//        return (highestIndex: highestBlockIndex, parent: lowestParentIndex, blocks: blocks)
//    }
//    
//    func checkForReorg(block: BlockMeta) -> Reorganization? {
//        if let earliestOrphanBlock = getEarliestOrphanBlockConnectedToMainChain(blockHeader: block.blockHash) {
//            let mainChainWork = getMainChainWork(blockIndex: hashToBlock[earliestOrphanBlock]!.blockIndex)
//            let forkChainWork = getChainWithMostWork(startingBlock: hashToBlock[earliestOrphanBlock]!)
//            if Chain.compareWork((mainChainWork.highestIndex, mainChainWork.parent), (forkChainWork.highestIndex, forkChainWork.parent)) {
//                return updateForReorg(newForkChainBlocks: forkChainWork.blocks, newForkHighestIndex: forkChainWork.highestIndex, mainChainWorkBlocks: mainChainWork.blocks)
//            }
//        }
//        return nil
//    }
//    
//    func updateForReorg(newForkChainBlocks: Set<String>, newForkHighestIndex: UInt64, mainChainWorkBlocks: Set<String>) -> Reorganization {
//        var newChainTip: String
//        var forkChainHashToIndex = [String: UInt64]()
//        newForkChainBlocks.forEach { blockHash in
//            let blockIndex = hashToBlock[blockHash]!.blockIndex
//            forkChainHashToIndex[blockHash] = blockIndex
//            if blockIndex == newForkHighestIndex {
//                newChainTip = blockHash
//            }
//        }
//        updateNewHighestBlockHash(blockHash: newChainTip, blockIndex: newForkHighestIndex)
//        mainChainHashes.subtract(mainChainWorkBlocks)
//        mainChainHashes.formUnion(newForkChainBlocks)
//        return Reorganization(mainChainBlocksAdded: forkChainHashToIndex, mainChainBlocksRemoved: mainChainWorkBlocks)
//    }
//    
//    func updateNewHighestBlockHash(blockHash: String, blockIndex: UInt64) {
//        let difference = blockIndex - highestBlockIndex
//        chainTip = blockHash
//        for indexToRemove in (highestBlockIndex - RECENT_BLOCK_DISTANCE)..<(blockIndex - RECENT_BLOCK_DISTANCE) {
//            removeBlocksForIndex(index: indexToRemove)
//        }
//    }
//    
//    func removeBlocksForIndex(index: UInt64) {
//        let hashes = indexToBlockHash.removeValue(forKey: index)
//        
//        let blocksForIndex = indexToBlockHash[index]!
//        for blockHash in blocksForIndex {
//            removeBlock(hash: blockHash)
//        }
//    }
//    
//    func removeBlock(hash: String) {
//        mainChainHashes.remove(hash)
//        if let block = hashToBlock.removeValue(forKey: hash) {
//            let parentChainBlocks = block.parentChainBlocks
//            for parentChainBlock in parentChainBlocks.keys {
//                parentChainBlockHashToBlockHash.removeValue(forKey: parentChainBlock)
//            }
//        }
//    }
//    
//    func removeHash(hash: String) {
//        hashToBlock.removeValue(forKey: hash)
//    }
//    
//    private func getMainChainBlockAtIndex(blockIndex: UInt64) -> String {
//        return indexToBlockHash[blockIndex]!.first(where: mainChainHashes.contains)!
//    }
//    
//    func getEarliestOrphanBlocksConnectedToMainChain(blockHeaders: [String]) -> [BlockMeta] {
//        var blocksToVisit = Set(blockHeaders)
//        var visitedBlocks: Set<String> = Set()
//        var earliestOrphanBlocks: [BlockMeta] = []
//        while (!blocksToVisit.isEmpty) {
//            var visitedBlockHash = blocksToVisit.removeFirst()
//            visitedBlocks.insert(visitedBlockHash)
//            var visitedBlock = hashToBlock[visitedBlockHash]!
//            while (visitedBlock.previousBlockHash != nil && !mainChainHashes.contains(visitedBlock.previousBlockHash!) && !visitedBlocks.contains(visitedBlock.previousBlockHash!)) {
//                visitedBlockHash = visitedBlock.previousBlockHash!
//                visitedBlocks.insert(visitedBlockHash)
//                visitedBlock = hashToBlock[visitedBlockHash]!
//            }
//            if !visitedBlocks.contains(visitedBlock.previousBlockHash!) {
//                earliestOrphanBlocks.append(hashToBlock[visitedBlockHash]!)
//            }
//        }
//        return earliestOrphanBlocks
//    }
//    
//    func getWorkAtMainChainIndexes(indexes: [UInt64]) -> [UInt64: UInt64] {
//        var sortedIndexes = indexes.sorted(by: >)
//        var currentBlockHash = chainTip
//        var currentBlock = hashToBlock[currentBlockHash]!
//        var currentWork = currentBlock.parentIndex!
//        var workAtIndex: [UInt64: UInt64] = [:]
//        if currentBlock.blockIndex == sortedIndexes.first! {
//            workAtIndex[currentBlock.blockIndex] = getLowestParentIndex(currentBlock.parentIndex!, currentWork)
//            sortedIndexes.removeFirst()
//        }
//        while (!sortedIndexes.isEmpty && currentBlock.previousBlockHash != nil) {
//            currentBlockHash = currentBlock.previousBlockHash!
//            currentBlock = hashToBlock[currentBlockHash]!
//            if currentBlock.blockIndex == sortedIndexes.first! {
//                workAtIndex[currentBlock.blockIndex] = getLowestParentIndex(currentBlock.parentIndex!, currentWork)
//                sortedIndexes.removeFirst()
//            }
//        }
//        return workAtIndex
//    }
//}
//
//public struct BlockMeta {
//    let blockIndex: UInt64
//    let previousBlockHash: String?
//    let blockHash: String
//    var parentChainBlocks: [String: UInt64?]
//    var parentBlocks: [String]
//    var parentIndex: UInt64? { parentChainBlocks.values.filter { $0 != nil }.map { $0! }.min() }
//    
//    init(blockIndex: UInt64, previousBlockHash: String?, blockHash: String, parentChainBlocks: [String : UInt64?], parentBlocks: [String]) {
//        self.blockIndex = blockIndex
//        self.previousBlockHash = previousBlockHash
//        self.blockHash = blockHash
//        self.parentChainBlocks = parentChainBlocks
//        self.parentBlocks = parentBlocks
//    }
//}
//
//public struct SubmissionResult: Sendable {
//    let addedBlock: Bool
//    let extendsMainChain: Bool
//    let needsChildBlock: Bool
//    let reorganization: Reorganization?
//    
//    static func extendsMainChain() -> Self {
//        return SubmissionResult(addedBlock: true, extendsMainChain: true, needsChildBlock: false, reorganization: nil)
//    }
//    
//    static func discarded() -> Self {
//        return SubmissionResult(addedBlock: false, extendsMainChain: false, needsChildBlock: false, reorganization: nil)
//    }
//}
//
//public struct Reorganization: Sendable {
//    let mainChainBlocksAdded: [String: UInt64]
//    let mainChainBlocksRemoved: Set<String>
//}
//
//extension Dictionary where Key == String, Value == UInt64 {
//    mutating func combine(_ other: Self) {
//        merge(other) { left, right in
//            return left
//        }
//    }
//}
