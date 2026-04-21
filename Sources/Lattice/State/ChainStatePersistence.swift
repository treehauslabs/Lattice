import Foundation
import cashew
import UInt256

public struct PersistedChainState: Codable, Sendable {
    public let chainTip: String
    public let tipFrontierCID: String?
    public let tipHomesteadCID: String?
    public let tipSpecCID: String?
    public let tipDifficulty: String?
    public let tipNextDifficulty: String?
    public let tipIndex: UInt64?
    public let tipTimestamp: Int64?
    public let mainChainHashes: [String]
    public let blocks: [PersistedBlockMeta]
    public let parentChainMap: [String: String]
    public let missingBlockHashes: [String]

    public init(chainTip: String, tipFrontierCID: String?, tipHomesteadCID: String?, tipSpecCID: String?, tipDifficulty: String?, tipNextDifficulty: String?, tipIndex: UInt64?, tipTimestamp: Int64?, mainChainHashes: [String], blocks: [PersistedBlockMeta], parentChainMap: [String: String], missingBlockHashes: [String]) {
        self.chainTip = chainTip
        self.tipFrontierCID = tipFrontierCID
        self.tipHomesteadCID = tipHomesteadCID
        self.tipSpecCID = tipSpecCID
        self.tipDifficulty = tipDifficulty
        self.tipNextDifficulty = tipNextDifficulty
        self.tipIndex = tipIndex
        self.tipTimestamp = tipTimestamp
        self.mainChainHashes = mainChainHashes
        self.blocks = blocks
        self.parentChainMap = parentChainMap
        self.missingBlockHashes = missingBlockHashes
    }
}

public struct PersistedBlockMeta: Codable, Sendable {
    public let blockHash: String
    public let previousBlockHash: String?
    public let blockIndex: UInt64
    public let parentChainBlocks: [String: UInt64?]
    public let childBlockHashes: [String]
    public let difficulty: String?
    public let timestamp: Int64?

    public init(blockHash: String, previousBlockHash: String?, blockIndex: UInt64, parentChainBlocks: [String: UInt64?], childBlockHashes: [String], difficulty: String? = nil, timestamp: Int64? = nil) {
        self.blockHash = blockHash
        self.previousBlockHash = previousBlockHash
        self.blockIndex = blockIndex
        self.parentChainBlocks = parentChainBlocks
        self.childBlockHashes = childBlockHashes
        self.difficulty = difficulty
        self.timestamp = timestamp
    }
}

public extension ChainState {

    func persist() async -> PersistedChainState {
        var blocks: [PersistedBlockMeta] = []
        for (_, meta) in hashToBlock {
            // Recover difficulty from work: if work > 0, difficulty = MAX / work
            let diffHex: String? = meta.work > UInt256.zero
                ? (UInt256.max / meta.work).toHexString()
                : nil
            blocks.append(PersistedBlockMeta(
                blockHash: meta.blockHash,
                previousBlockHash: meta.previousBlockHash,
                blockIndex: meta.blockIndex,
                parentChainBlocks: meta.parentChainBlocks,
                childBlockHashes: meta.childBlockHashes,
                difficulty: diffHex,
                timestamp: blockTimestamps[meta.blockHash]
            ))
        }
        return PersistedChainState(
            chainTip: chainTip,
            tipFrontierCID: tipSnapshot?.frontierCID,
            tipHomesteadCID: tipSnapshot?.homesteadCID,
            tipSpecCID: tipSnapshot?.specCID,
            tipDifficulty: tipSnapshot?.difficulty.toHexString(),
            tipNextDifficulty: tipSnapshot?.nextDifficulty.toHexString(),
            tipIndex: tipSnapshot?.index,
            tipTimestamp: tipSnapshot?.timestamp,
            mainChainHashes: Array(mainChainHashes),
            blocks: blocks,
            parentChainMap: parentChainBlockHashToBlockHash,
            missingBlockHashes: Array(missingBlockHashes)
        )
    }

    static func restore(
        from persisted: PersistedChainState,
        retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE
    ) -> ChainState {
        var hashToBlock: [String: BlockMeta] = [:]
        var indexToBlockHash: [UInt64: Set<String>] = [:]
        var blockTimestamps: [String: Int64] = [:]
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
            hashToBlock[block.blockHash] = meta
            indexToBlockHash[block.blockIndex, default: Set()].insert(block.blockHash)
            if let ts = block.timestamp {
                blockTimestamps[block.blockHash] = ts
            }
        }
        var snapshot: TipBlockSnapshot? = nil
        if let frontierCID = persisted.tipFrontierCID,
           let homesteadCID = persisted.tipHomesteadCID,
           let specCID = persisted.tipSpecCID,
           let diffHex = persisted.tipDifficulty,
           let nextDiffHex = persisted.tipNextDifficulty,
           let index = persisted.tipIndex,
           let timestamp = persisted.tipTimestamp,
           let diff = UInt256(diffHex, radix: 16),
           let nextDiff = UInt256(nextDiffHex, radix: 16) {
            snapshot = TipBlockSnapshot(
                frontierCID: frontierCID,
                homesteadCID: homesteadCID,
                specCID: specCID,
                difficulty: diff,
                nextDifficulty: nextDiff,
                index: index,
                timestamp: timestamp
            )
        }
        return ChainState(
            chainTip: persisted.chainTip,
            mainChainHashes: Set(persisted.mainChainHashes),
            indexToBlockHash: indexToBlockHash,
            hashToBlock: hashToBlock,
            parentChainBlockHashToBlockHash: persisted.parentChainMap,
            retentionDepth: retentionDepth,
            blockTimestamps: blockTimestamps,
            tipSnapshot: snapshot
        )
    }
}

public actor ChainStatePersister {
    private let path: URL

    public init(storagePath: URL, directory: String) {
        self.path = storagePath
            .appendingPathComponent(directory)
            .appendingPathComponent("chain_state.json")
    }

    public func save(_ state: PersistedChainState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: path)
    }

    public func load() throws -> PersistedChainState? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(PersistedChainState.self, from: data)
    }

    public func delete() throws {
        try? FileManager.default.removeItem(at: path)
    }
}
