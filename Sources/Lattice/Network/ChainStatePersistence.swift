import Foundation
import cashew

public struct PersistedChainState: Codable, Sendable {
    public let chainTip: String
    public let mainChainHashes: [String]
    public let blocks: [PersistedBlockMeta]
    public let parentChainMap: [String: String]
    public let missingBlockHashes: [String]
}

public struct PersistedBlockMeta: Codable, Sendable {
    public let blockHash: String
    public let previousBlockHash: String?
    public let blockIndex: UInt64
    public let parentChainBlocks: [String: UInt64?]
    public let childBlockHashes: [String]
}

public extension ChainState {

    func persist() async -> PersistedChainState {
        var blocks: [PersistedBlockMeta] = []
        for (_, meta) in hashToBlock {
            blocks.append(PersistedBlockMeta(
                blockHash: meta.blockHash,
                previousBlockHash: meta.previousBlockHash,
                blockIndex: meta.blockIndex,
                parentChainBlocks: meta.parentChainBlocks,
                childBlockHashes: meta.childBlockHashes
            ))
        }
        return PersistedChainState(
            chainTip: chainTip,
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
        for block in persisted.blocks {
            let meta = BlockMeta(
                blockInfo: BlockInfoImpl(
                    blockHash: block.blockHash,
                    previousBlockHash: block.previousBlockHash,
                    blockIndex: block.blockIndex
                ),
                parentChainBlocks: block.parentChainBlocks,
                childBlockHashes: block.childBlockHashes
            )
            hashToBlock[block.blockHash] = meta
            indexToBlockHash[block.blockIndex, default: Set()].insert(block.blockHash)
        }
        let chain = ChainState(
            chainTip: persisted.chainTip,
            mainChainHashes: Set(persisted.mainChainHashes),
            indexToBlockHash: indexToBlockHash,
            hashToBlock: hashToBlock,
            parentChainBlockHashToBlockHash: persisted.parentChainMap,
            retentionDepth: retentionDepth
        )
        return chain
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
