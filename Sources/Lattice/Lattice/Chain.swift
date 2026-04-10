import cashew
import UInt256

/// Compute proof-of-work for a given difficulty target.
/// Higher difficulty value = easier target; work is inversely proportional.
public func workForDifficulty(_ difficulty: UInt256) -> UInt256 {
    guard difficulty > UInt256.zero else { return UInt256.zero }
    return UInt256.max / difficulty
}

public let RECENT_BLOCK_DISTANCE: UInt64 = UInt64.max
public typealias BlockHeader = VolumeImpl<Block>

// MARK: - Protocols

public protocol ConsensusBlock: Sendable {
    var blockInfo: BlockInfoImpl { get }
    var weights: [UInt64] { get }
}

public protocol BlockInfo: Sendable {
    var blockHash: String { get }
    var previousBlockHash: String? { get }
    var blockIndex: UInt64 { get }
}

// MARK: - Concrete Types

public struct BlockInfoImpl: BlockInfo, Sendable {
    public let blockHash: String
    public let previousBlockHash: String?
    public let blockIndex: UInt64
    public let work: UInt256
}

public struct BlockMeta: ConsensusBlock, Sendable {
    public let blockInfo: BlockInfoImpl
    public var parentChainBlocks: [String: UInt64?]
    public var childBlockHashes: [String]
    public private(set) var cachedParentIndex: UInt64?

    public var blockIndex: UInt64 { blockInfo.blockIndex }
    public var previousBlockHash: String? { blockInfo.previousBlockHash }
    public var blockHash: String { blockInfo.blockHash }
    public var work: UInt256 { blockInfo.work }

    public var parentIndex: UInt64? { cachedParentIndex }

    public var weights: [UInt64] {
        if let pi = cachedParentIndex {
            return [UInt64.max - pi, blockIndex]
        }
        return [0, blockIndex]
    }

    public init(
        blockInfo: BlockInfoImpl,
        parentChainBlocks: [String: UInt64?],
        childBlockHashes: [String]
    ) {
        self.blockInfo = blockInfo
        self.parentChainBlocks = parentChainBlocks
        self.childBlockHashes = childBlockHashes
        self.cachedParentIndex = parentChainBlocks.values.compactMap { $0 }.min()
    }

    public mutating func setParentChainBlock(_ hash: String, index: UInt64?) {
        parentChainBlocks[hash] = index
        recomputeParentIndex()
    }

    public mutating func removeParentChainBlock(_ hash: String) {
        parentChainBlocks.removeValue(forKey: hash)
        recomputeParentIndex()
    }

    private mutating func recomputeParentIndex() {
        cachedParentIndex = parentChainBlocks.values.compactMap { $0 }.min()
    }
}

public struct SubmissionResult: Sendable {
    public let addedBlock: Bool
    public let extendsMainChain: Bool
    public let needsChildBlock: Bool
    public let reorganization: Reorganization?

    public static func extendsMainChain() -> Self {
        SubmissionResult(addedBlock: true, extendsMainChain: true, needsChildBlock: false, reorganization: nil)
    }

    public static func discarded() -> Self {
        SubmissionResult(addedBlock: false, extendsMainChain: false, needsChildBlock: false, reorganization: nil)
    }
}

public struct Reorganization: Sendable {
    public let mainChainBlocksAdded: [String: UInt64]
    public let mainChainBlocksRemoved: Set<String>
}

// MARK: - Fork Choice Cache

public struct CachedChainWork: Sendable {
    public let tipHash: String
    public let cumulativeWork: UInt256
    public let lowestParentIndex: UInt64?
}

// MARK: - Fork Choice

/// Returns true if `right` has more work than `left`.
/// Primary: parent chain anchoring (lower parentIndex = earlier anchor = wins).
/// Secondary: cumulative proof-of-work (higher = wins).
public func compareWork(
    _ left: (cumulativeWork: UInt256, parentIndex: UInt64?),
    _ right: (cumulativeWork: UInt256, parentIndex: UInt64?)
) -> Bool {
    if let rightParent = right.parentIndex {
        if let leftParent = left.parentIndex {
            if rightParent != leftParent {
                return rightParent < leftParent
            }
            return right.cumulativeWork > left.cumulativeWork
        }
        return true
    }
    if left.parentIndex == nil {
        return right.cumulativeWork > left.cumulativeWork
    }
    return false
}

func minOptional(_ a: UInt64?, _ b: UInt64?) -> UInt64? {
    switch (a, b) {
    case let (a?, b?): return min(a, b)
    case let (a?, nil): return a
    case let (nil, b?): return b
    case (nil, nil): return nil
    }
}

// MARK: - ChainState

public struct TipBlockSnapshot: Sendable {
    public let frontierCID: String
    public let homesteadCID: String
    public let specCID: String
    public let difficulty: UInt256
    public let nextDifficulty: UInt256
    public let index: UInt64
    public let timestamp: Int64

    public init(frontierCID: String, homesteadCID: String, specCID: String, difficulty: UInt256, nextDifficulty: UInt256, index: UInt64, timestamp: Int64) {
        self.frontierCID = frontierCID
        self.homesteadCID = homesteadCID
        self.specCID = specCID
        self.difficulty = difficulty
        self.nextDifficulty = nextDifficulty
        self.index = index
        self.timestamp = timestamp
    }
}

public actor ChainState {
    var chainTip: String
    var mainChainHashes: Set<String>
    var indexToBlockHash: [UInt64: Set<String>]
    var hashToBlock: [String: BlockMeta]
    var parentChainBlockHashToBlockHash: [String: String]
    var mainChainBlockAtIndex: [UInt64: String]
    var bestChainCache: [String: CachedChainWork]
    var missingBlockHashes: Set<String>
    var retentionDepth: UInt64
    public private(set) var tipSnapshot: TipBlockSnapshot?

    var highestBlock: BlockMeta { hashToBlock[chainTip]! }
    var highestBlockIndex: UInt64 { highestBlock.blockIndex }

    public func getRetentionDepth() -> UInt64 { retentionDepth }

    public init(
        chainTip: String,
        mainChainHashes: Set<String>,
        indexToBlockHash: [UInt64: Set<String>],
        hashToBlock: [String: BlockMeta],
        parentChainBlockHashToBlockHash: [String: String],
        retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE,
        tipSnapshot: TipBlockSnapshot? = nil
    ) {
        self.chainTip = chainTip
        self.mainChainHashes = mainChainHashes
        self.indexToBlockHash = indexToBlockHash
        self.hashToBlock = hashToBlock
        self.parentChainBlockHashToBlockHash = parentChainBlockHashToBlockHash
        self.retentionDepth = retentionDepth
        self.tipSnapshot = tipSnapshot
        self.bestChainCache = [:]
        self.missingBlockHashes = Set()
        var blockAtIndex: [UInt64: String] = [:]
        for hash in mainChainHashes {
            if let block = hashToBlock[hash] {
                blockAtIndex[block.blockIndex] = hash
            }
        }
        self.mainChainBlockAtIndex = blockAtIndex
    }

    public func resetFrom(_ persisted: PersistedChainState, retentionDepth: UInt64? = nil) {
        var newHashToBlock: [String: BlockMeta] = [:]
        var newIndexToBlockHash: [UInt64: Set<String>] = [:]
        for block in persisted.blocks {
            let difficulty = block.difficulty.flatMap { UInt256($0, radix: 16) } ?? UInt256.zero
            let meta = BlockMeta(
                blockInfo: BlockInfoImpl(
                    blockHash: block.blockHash,
                    previousBlockHash: block.previousBlockHash,
                    blockIndex: block.blockIndex,
                    work: workForDifficulty(difficulty)
                ),
                parentChainBlocks: block.parentChainBlocks,
                childBlockHashes: block.childBlockHashes
            )
            newHashToBlock[block.blockHash] = meta
            newIndexToBlockHash[block.blockIndex, default: Set()].insert(block.blockHash)
        }
        self.chainTip = persisted.chainTip
        self.mainChainHashes = Set(persisted.mainChainHashes)
        self.indexToBlockHash = newIndexToBlockHash
        self.hashToBlock = newHashToBlock
        self.parentChainBlockHashToBlockHash = persisted.parentChainMap
        self.retentionDepth = retentionDepth ?? self.retentionDepth
        self.bestChainCache = [:]
        self.missingBlockHashes = Set(persisted.missingBlockHashes)
        var blockAtIndex: [UInt64: String] = [:]
        for hash in self.mainChainHashes {
            if let block = self.hashToBlock[hash] {
                blockAtIndex[block.blockIndex] = hash
            }
        }
        self.mainChainBlockAtIndex = blockAtIndex
    }

    public static func fromGenesis(block: Block, retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE) -> ChainState {
        let blockHeader = BlockHeader(node: block)
        let blockHash = blockHeader.rawCID
        let meta = BlockMeta(
            blockInfo: BlockInfoImpl(
                blockHash: blockHash,
                previousBlockHash: nil,
                blockIndex: 0,
                work: workForDifficulty(block.difficulty)
            ),
            parentChainBlocks: [:],
            childBlockHashes: []
        )
        return ChainState(
            chainTip: blockHash,
            mainChainHashes: Set([blockHash]),
            indexToBlockHash: [0: Set([blockHash])],
            hashToBlock: [blockHash: meta],
            parentChainBlockHashToBlockHash: [:],
            retentionDepth: retentionDepth,
            tipSnapshot: TipBlockSnapshot(
                frontierCID: block.frontier.rawCID,
                homesteadCID: block.homestead.rawCID,
                specCID: block.spec.rawCID,
                difficulty: block.difficulty,
                nextDifficulty: block.nextDifficulty,
                index: block.index,
                timestamp: block.timestamp
            )
        )
    }

    // MARK: - Queries

    public func contains(blockHash: String) -> Bool {
        hashToBlock.keys.contains(blockHash)
    }

    public func getMainChainTip() -> String {
        chainTip
    }

    public func isOnMainChain(hash: String) -> Bool {
        guard let block = hashToBlock[hash] else { return false }
        return mainChainBlockAtIndex[block.blockIndex] == hash
    }

    public func getConsensusBlock(hash: String) -> BlockMeta? {
        hashToBlock[hash]
    }

    public func getHighestBlock() -> BlockMeta {
        highestBlock
    }

    public func getHighestBlockIndex() -> UInt64 {
        highestBlockIndex
    }

    public func getMissingBlockHashes() -> Set<String> {
        missingBlockHashes
    }

    public func getMainChainBlockHash(atIndex index: UInt64) -> String? {
        mainChainBlockAtIndex[index]
    }

    // MARK: - Block Submission

    private func updateTipSnapshot(block: Block) {
        tipSnapshot = TipBlockSnapshot(
            frontierCID: block.frontier.rawCID,
            homesteadCID: block.homestead.rawCID,
            specCID: block.spec.rawCID,
            difficulty: block.difficulty,
            nextDifficulty: block.nextDifficulty,
            index: block.index,
            timestamp: block.timestamp
        )
    }

    public func submitBlock(
        parentBlockHeaderAndIndex: (String, UInt64?)?,
        blockHeader: BlockHeader,
        block: Block
    ) -> SubmissionResult {
        let blockHash = blockHeader.rawCID
        let difficulty = block.difficulty

        let (indexPlusRetention, overflow1) = block.index.addingReportingOverflow(retentionDepth)
        if !overflow1 && indexPlusRetention < highestBlockIndex {
            return .discarded()
        }
        if parentBlockHeaderAndIndex == nil && block.previousBlock == nil {
            return .discarded()
        }

        if hashToBlock[blockHash] != nil {
            return handleDuplicateBlock(
                parentBlockHeaderAndIndex: parentBlockHeaderAndIndex,
                blockHash: blockHash
            )
        }

        let result = insertBlock(
            parentBlockHeaderAndIndex: parentBlockHeaderAndIndex,
            blockHash: blockHash,
            block: block,
            difficulty: difficulty
        )
        if !result.addedBlock { return result }

        if let parentInfo = parentBlockHeaderAndIndex {
            addParentBlockReference(
                parentBlockHeader: parentInfo.0,
                parentIndex: parentInfo.1,
                blockHash: blockHash
            )
        }

        if result.extendsMainChain {
            updateTipSnapshot(block: block)
            return .extendsMainChain()
        }
        if result.needsChildBlock { return result }

        let meta = hashToBlock[blockHash]!
        if let reorg = checkForReorg(block: meta) {
            updateTipSnapshot(block: block)
            return SubmissionResult(
                addedBlock: true,
                extendsMainChain: false,
                needsChildBlock: false,
                reorganization: reorg
            )
        }

        return result
    }

    // MARK: - Insert

    func insertBlock(
        parentBlockHeaderAndIndex: (String, UInt64?)?,
        blockHash: String,
        block: Block,
        difficulty: UInt256
    ) -> SubmissionResult {
        addToBlockIndex(hash: blockHash, blockIndex: block.index)

        let meta = BlockMeta(
            blockInfo: BlockInfoImpl(
                blockHash: blockHash,
                previousBlockHash: block.previousBlock?.rawCID,
                blockIndex: block.index,
                work: workForDifficulty(difficulty)
            ),
            parentChainBlocks: parentBlockHeaderAndIndex.map { [$0.0: $0.1] } ?? [:],
            childBlockHashes: findChildren(hash: blockHash, blockIndex: block.index)
        )

        hashToBlock[blockHash] = meta
        missingBlockHashes.remove(blockHash)

        if let prevHash = block.previousBlock?.rawCID {
            hashToBlock[prevHash]?.childBlockHashes.append(blockHash)
            invalidateBestChainCache(fromBlock: prevHash)
        }

        guard let previousBlockCID = block.previousBlock?.rawCID else {
            return SubmissionResult(
                addedBlock: true,
                extendsMainChain: false,
                needsChildBlock: false,
                reorganization: nil
            )
        }

        if previousBlockCID == chainTip {
            setNewTip(block: meta)
            return .extendsMainChain()
        }

        let (idxPlusRet, ovf) = block.index.addingReportingOverflow(retentionDepth)
        if hashToBlock[previousBlockCID] == nil
            && (ovf || idxPlusRet > highestBlockIndex)
        {
            missingBlockHashes.insert(previousBlockCID)
            return SubmissionResult(
                addedBlock: true,
                extendsMainChain: false,
                needsChildBlock: true,
                reorganization: nil
            )
        }

        return SubmissionResult(
            addedBlock: true,
            extendsMainChain: false,
            needsChildBlock: false,
            reorganization: nil
        )
    }

    // MARK: - Duplicate Block (new parent chain anchoring for already-known block)

    func handleDuplicateBlock(
        parentBlockHeaderAndIndex: (String, UInt64?)?,
        blockHash: String
    ) -> SubmissionResult {
        guard let parentInfo = parentBlockHeaderAndIndex else { return .discarded() }
        if parentChainBlockHashToBlockHash[parentInfo.0] != nil { return .discarded() }

        parentChainBlockHashToBlockHash[parentInfo.0] = blockHash
        guard let parentBlockIndex = parentInfo.1 else { return .discarded() }

        hashToBlock[blockHash]?.setParentChainBlock(parentInfo.0, index: parentBlockIndex)
        invalidateBestChainCache(fromBlock: blockHash)

        if mainChainBlockAtIndex[hashToBlock[blockHash]!.blockIndex] == blockHash {
            return .discarded()
        }

        if let reorg = checkForReorg(block: hashToBlock[blockHash]!) {
            return SubmissionResult(
                addedBlock: false,
                extendsMainChain: false,
                needsChildBlock: false,
                reorganization: reorg
            )
        }
        return .discarded()
    }

    // MARK: - Parent Chain Reorg

    public func applyParentReorg(
        reorg: Reorganization,
        parentBlockHeaderAndIndex: (String, UInt64?)?,
        blockHash: String,
        block: Block
    ) -> SubmissionResult {
        var tempResult: SubmissionResult = .discarded()

        let shouldInsert = block.index + retentionDepth >= highestBlockIndex
            && (reorg.mainChainBlocksAdded[blockHash] != nil
                || (block.previousBlock != nil && hashToBlock[blockHash] == nil))

        if shouldInsert {
            tempResult = insertBlock(
                parentBlockHeaderAndIndex: parentBlockHeaderAndIndex,
                blockHash: blockHash,
                block: block,
                difficulty: block.difficulty
            )
        }

        updateParentsForReorg(reorg: reorg)

        var affectedHashes = reorg.mainChainBlocksAdded.keys.compactMap {
            parentChainBlockHashToBlockHash[$0]
        }
        affectedHashes.append(blockHash)

        let orphanCandidates = affectedHashes.filter {
            guard let block = hashToBlock[$0] else { return false }
            return mainChainBlockAtIndex[block.blockIndex] != $0
        }
        let earliestOrphans = findEarliestOrphansConnectedToMainChain(blockHeaders: orphanCandidates)

        if let reorgResult = findBestReorg(among: earliestOrphans) {
            return SubmissionResult(
                addedBlock: tempResult.addedBlock,
                extendsMainChain: tempResult.extendsMainChain,
                needsChildBlock: tempResult.needsChildBlock,
                reorganization: reorgResult
            )
        }

        return tempResult
    }

    // MARK: - Parent Chain Reorg Propagation

    public func propagateParentReorg(reorg: Reorganization) -> Reorganization? {
        updateParentsForReorg(reorg: reorg)

        var affectedBlockHashes: Set<String> = Set()
        for addedHash in reorg.mainChainBlocksAdded.keys {
            if let blockHash = parentChainBlockHashToBlockHash[addedHash] {
                affectedBlockHashes.insert(blockHash)
            }
        }
        for removedHash in reorg.mainChainBlocksRemoved {
            if let blockHash = parentChainBlockHashToBlockHash[removedHash] {
                affectedBlockHashes.insert(blockHash)
            }
        }

        let orphanCandidates = affectedBlockHashes.filter {
            guard let block = hashToBlock[$0] else { return false }
            return mainChainBlockAtIndex[block.blockIndex] != $0
        }
        guard !orphanCandidates.isEmpty else { return nil }

        let earliestOrphans = findEarliestOrphansConnectedToMainChain(
            blockHeaders: Array(orphanCandidates)
        )

        return findBestReorg(among: earliestOrphans)
    }

    // MARK: - Shared Reorg Evaluation

    private func findBestReorg(among orphans: [BlockMeta]) -> Reorganization? {
        var bestWork: (cumulativeWork: UInt256, parentIndex: UInt64?)? = nil
        var bestBlocks: Set<String> = Set()
        var bestForkIndex: UInt64 = 0

        for orphan in orphans {
            let forkWork = chainWithMostWork(startingBlock: orphan)
            let mainWork = mainChainWork(fromIndex: orphan.blockIndex)

            if compareWork(
                (mainWork.cumulativeWork, mainWork.parentIndex),
                (forkWork.cumulativeWork, forkWork.parentIndex)
            ) {
                if let current = bestWork {
                    if compareWork(current, (forkWork.cumulativeWork, forkWork.parentIndex)) {
                        bestWork = (forkWork.cumulativeWork, forkWork.parentIndex)
                        bestBlocks = forkWork.blocks
                        bestForkIndex = orphan.blockIndex
                    }
                } else {
                    bestWork = (forkWork.cumulativeWork, forkWork.parentIndex)
                    bestBlocks = forkWork.blocks
                    bestForkIndex = orphan.blockIndex
                }
            }
        }

        if bestWork != nil {
            let tipHash = bestBlocks.first(where: { hash in
                guard let b = hashToBlock[hash] else { return false }
                return b.childBlockHashes.allSatisfy { !bestBlocks.contains($0) }
            })
            return applyReorg(
                newForkBlocks: bestBlocks,
                newForkTipHash: tipHash,
                mainChainBlocks: mainChainHashesFrom(index: bestForkIndex)
            )
        }
        return nil
    }

    // MARK: - Index Management

    func addToBlockIndex(hash: String, blockIndex: UInt64) {
        indexToBlockHash[blockIndex, default: []].insert(hash)
    }

    func findChildren(hash: String, blockIndex: UInt64) -> [String] {
        guard let hashes = indexToBlockHash[blockIndex + 1] else { return [] }
        return hashes.filter { hashToBlock[$0]?.previousBlockHash == hash }
    }

    // MARK: - Parent Chain Tracking

    func addParentBlockReference(parentBlockHeader: String, parentIndex: UInt64?, blockHash: String) {
        parentChainBlockHashToBlockHash[parentBlockHeader] = blockHash
        hashToBlock[blockHash]?.setParentChainBlock(parentBlockHeader, index: parentIndex)
        invalidateBestChainCache(fromBlock: blockHash)
    }

    func updateParentsForReorg(reorg: Reorganization) {
        for removedHash in reorg.mainChainBlocksRemoved {
            if let blockHash = parentChainBlockHashToBlockHash[removedHash] {
                hashToBlock[blockHash]?.removeParentChainBlock(removedHash)
                invalidateBestChainCache(fromBlock: blockHash)
            }
        }
        for (addedHash, idx) in reorg.mainChainBlocksAdded {
            if let blockHash = parentChainBlockHashToBlockHash[addedHash] {
                hashToBlock[blockHash]?.setParentChainBlock(addedHash, index: idx)
                invalidateBestChainCache(fromBlock: blockHash)
            }
        }
    }

    // MARK: - Best Chain Cache

    func invalidateBestChainCache(fromBlock blockHash: String) {
        var current: String? = blockHash
        while let hash = current {
            bestChainCache.removeValue(forKey: hash)
            current = hashToBlock[hash]?.previousBlockHash
        }
    }

    func collectChainBlocks(from startHash: String, toTip tipHash: String) -> Set<String> {
        var blocks: Set<String> = []
        var current = tipHash
        while true {
            blocks.insert(current)
            if current == startHash { break }
            guard let block = hashToBlock[current], let prev = block.previousBlockHash else { break }
            current = prev
        }
        return blocks
    }

    // MARK: - Fork Choice
    //
    // Walk forward from a block through its children, following the fork
    // with the most work. Results are cached per starting block and
    // invalidated when children or parent chain anchoring changes.
    //
    // The fork choice rule:
    //   1. Parent chain is respected: a fork anchored earlier on the
    //      parent chain (lower parentIndex) beats one anchored later.
    //   2. Longest chain: if neither fork has parent chain anchoring,
    //      the fork with the higher block index wins.

    func chainWithMostWork(
        startingBlock: BlockMeta
    ) -> (cumulativeWork: UInt256, parentIndex: UInt64?, blocks: Set<String>) {
        if let cached = bestChainCache[startingBlock.blockHash],
           hashToBlock[cached.tipHash] != nil
        {
            let blocks = collectChainBlocks(
                from: startingBlock.blockHash,
                toTip: cached.tipHash
            )
            return (cached.cumulativeWork, cached.lowestParentIndex, blocks)
        }

        var current = startingBlock
        var lowestParent = startingBlock.cachedParentIndex
        var cumWork = startingBlock.work
        var blocks: Set<String> = [current.blockHash]
        var children = current.childBlockHashes

        while !children.isEmpty {
            let firstHash = children.removeFirst()
            guard let first = hashToBlock[firstHash] else { break }

            if !children.isEmpty {
                let others = children.compactMap { hashToBlock[$0] }
                let best = bestForkAmong(first: first, others: others)
                let finalParent = minOptional(best.parentIndex, lowestParent)
                let totalWork = cumWork &+ best.cumulativeWork
                let allBlocks = best.blocks.union(blocks)
                let tipHash = allBlocks.first(where: { hash in
                    guard let b = hashToBlock[hash] else { return false }
                    return b.childBlockHashes.allSatisfy { !allBlocks.contains($0) }
                }) ?? current.blockHash
                bestChainCache[startingBlock.blockHash] = CachedChainWork(
                    tipHash: tipHash,
                    cumulativeWork: totalWork,
                    lowestParentIndex: finalParent
                )
                return (totalWork, finalParent, allBlocks)
            }

            current = first
            cumWork = cumWork &+ current.work
            blocks.insert(current.blockHash)
            lowestParent = minOptional(lowestParent, current.cachedParentIndex)
            children = current.childBlockHashes
        }

        bestChainCache[startingBlock.blockHash] = CachedChainWork(
            tipHash: current.blockHash,
            cumulativeWork: cumWork,
            lowestParentIndex: lowestParent
        )
        return (cumWork, lowestParent, blocks)
    }

    func bestForkAmong(
        first: BlockMeta,
        others: [BlockMeta]
    ) -> (cumulativeWork: UInt256, parentIndex: UInt64?, blocks: Set<String>) {
        var best = chainWithMostWork(startingBlock: first)
        for fork in others {
            let work = chainWithMostWork(startingBlock: fork)
            if compareWork(
                (best.cumulativeWork, best.parentIndex),
                (work.cumulativeWork, work.parentIndex)
            ) {
                best = work
            }
        }
        return best
    }

    func mainChainWork(
        fromIndex blockIndex: UInt64
    ) -> (cumulativeWork: UInt256, parentIndex: UInt64?, blocks: Set<String>) {
        var currentHash = chainTip
        var current = highestBlock
        var lowestParent = current.cachedParentIndex
        var cumWork = current.work
        var blocks: Set<String> = [currentHash]

        while current.blockIndex > blockIndex {
            guard let prevHash = current.previousBlockHash else { break }
            guard let prev = hashToBlock[prevHash] else { break }
            currentHash = prevHash
            current = prev
            cumWork = cumWork &+ current.work
            blocks.insert(currentHash)
            lowestParent = minOptional(lowestParent, current.cachedParentIndex)
        }

        return (cumWork, lowestParent, blocks)
    }

    // MARK: - Reorganization

    func checkForReorg(block: BlockMeta) -> Reorganization? {
        guard let earliestHash = findEarliestOrphanConnectedToMainChain(
            blockHeader: block.blockHash
        ) else {
            return nil
        }
        guard let earliest = hashToBlock[earliestHash] else { return nil }

        let mainWork = mainChainWork(fromIndex: earliest.blockIndex)
        let forkWork = chainWithMostWork(startingBlock: earliest)

        if compareWork(
            (mainWork.cumulativeWork, mainWork.parentIndex),
            (forkWork.cumulativeWork, forkWork.parentIndex)
        ) {
            return applyReorg(
                newForkBlocks: forkWork.blocks,
                newForkTipHash: forkWork.blocks.first(where: { hash in
                    guard let b = hashToBlock[hash] else { return false }
                    return b.childBlockHashes.allSatisfy { !forkWork.blocks.contains($0) }
                }),
                mainChainBlocks: mainWork.blocks
            )
        }
        return nil
    }

    func applyReorg(
        newForkBlocks: Set<String>,
        newForkTipHash: String?,
        mainChainBlocks: Set<String>
    ) -> Reorganization {
        var forkHashToIndex: [String: UInt64] = [:]
        var highestIndex: UInt64 = 0

        for hash in newForkBlocks {
            let idx = hashToBlock[hash]!.blockIndex
            forkHashToIndex[hash] = idx
            if idx > highestIndex { highestIndex = idx }
        }

        let newTip = newForkTipHash ?? chainTip
        advanceTip(to: newTip, newHighestIndex: highestIndex)

        for hash in mainChainBlocks {
            mainChainHashes.remove(hash)
            if let block = hashToBlock[hash] {
                mainChainBlockAtIndex.removeValue(forKey: block.blockIndex)
            }
        }
        for (hash, idx) in forkHashToIndex {
            mainChainHashes.insert(hash)
            mainChainBlockAtIndex[idx] = hash
        }

        return Reorganization(
            mainChainBlocksAdded: forkHashToIndex,
            mainChainBlocksRemoved: mainChainBlocks
        )
    }

    func setNewTip(block: BlockMeta) {
        let chain = chainWithMostWork(startingBlock: block)
        // Find the leaf node (tip) of this chain — the block whose children
        // are all outside the chain set.
        let tipHash = chain.blocks.first(where: { hash in
            guard let b = hashToBlock[hash] else { return false }
            return b.childBlockHashes.allSatisfy { !chain.blocks.contains($0) }
        })
        if let tipHash = tipHash {
            chainTip = tipHash
            for hash in chain.blocks {
                mainChainHashes.insert(hash)
                if let b = hashToBlock[hash] {
                    mainChainBlockAtIndex[b.blockIndex] = hash
                }
            }
        }
    }

    func advanceTip(to blockHash: String, newHighestIndex: UInt64) {
        let oldHighest = highestBlockIndex
        chainTip = blockHash

        if oldHighest > retentionDepth && newHighestIndex > retentionDepth {
            let oldCutoff = oldHighest - retentionDepth
            let newCutoff = newHighestIndex - retentionDepth
            if newCutoff > oldCutoff {
                for idx in oldCutoff..<newCutoff {
                    pruneBlocksAtIndex(idx)
                }
            }
        }
    }

    // MARK: - Orphan Detection

    func findEarliestOrphanConnectedToMainChain(blockHeader: String) -> String? {
        guard var current = hashToBlock[blockHeader] else { return nil }
        var currentHash = blockHeader

        while let prevHash = current.previousBlockHash,
              !mainChainHashes.contains(prevHash)
        {
            guard let prev = hashToBlock[prevHash] else { return nil }
            current = prev
            currentHash = prevHash
        }

        if current.previousBlockHash == nil {
            return current.blockIndex == 0 ? currentHash : nil
        }
        return currentHash
    }

    func findEarliestOrphansConnectedToMainChain(blockHeaders: [String]) -> [BlockMeta] {
        var toVisit = Set(blockHeaders)
        var visited: Set<String> = Set()
        var result: [BlockMeta] = []

        while let startHash = toVisit.popFirst() {
            visited.insert(startHash)
            guard var current = hashToBlock[startHash] else { continue }
            var currentHash = startHash

            while let prevHash = current.previousBlockHash,
                  !mainChainHashes.contains(prevHash),
                  !visited.contains(prevHash)
            {
                guard let prev = hashToBlock[prevHash] else { break }
                currentHash = prevHash
                visited.insert(currentHash)
                current = prev
            }

            if let prevHash = current.previousBlockHash {
                if mainChainHashes.contains(prevHash) {
                    result.append(hashToBlock[currentHash]!)
                }
            } else if current.blockIndex == 0 {
                result.append(hashToBlock[currentHash]!)
            }
        }
        return result
    }

    // MARK: - Main Chain Queries

    func mainChainHashesFrom(index blockIndex: UInt64) -> Set<String> {
        var hashes: Set<String> = Set()
        var currentHash = chainTip
        var current = highestBlock
        hashes.insert(currentHash)

        while current.blockIndex > blockIndex {
            guard let prevHash = current.previousBlockHash else { break }
            guard let prev = hashToBlock[prevHash] else { break }
            currentHash = prevHash
            current = prev
            hashes.insert(currentHash)
        }
        return hashes
    }

    // MARK: - Pruning

    func pruneBlocksAtIndex(_ index: UInt64) {
        guard let hashes = indexToBlockHash.removeValue(forKey: index) else { return }
        for hash in hashes {
            mainChainHashes.remove(hash)
            bestChainCache.removeValue(forKey: hash)
            if let block = hashToBlock.removeValue(forKey: hash) {
                for parentChainBlock in block.parentChainBlocks.keys {
                    parentChainBlockHashToBlockHash.removeValue(forKey: parentChainBlock)
                }
            }
        }
        mainChainBlockAtIndex.removeValue(forKey: index)
    }
}
