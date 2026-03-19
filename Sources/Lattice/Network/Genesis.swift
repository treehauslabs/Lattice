import Foundation
import cashew
import UInt256

public struct GenesisConfig: Sendable {
    public let spec: ChainSpec
    public let timestamp: Int64
    public let difficulty: UInt256

    public init(spec: ChainSpec, timestamp: Int64, difficulty: UInt256) {
        self.spec = spec
        self.timestamp = timestamp
        self.difficulty = difficulty
    }

    public static func standard(spec: ChainSpec) -> GenesisConfig {
        GenesisConfig(spec: spec, timestamp: 0, difficulty: UInt256.max)
    }
}

public struct GenesisResult: Sendable {
    public let block: Block
    public let blockHash: String
    public let chainState: ChainState

    public init(block: Block, blockHash: String, chainState: ChainState) {
        self.block = block
        self.blockHash = blockHash
        self.chainState = chainState
    }
}

public enum GenesisCeremony {

    public static func create(config: GenesisConfig, fetcher: Fetcher) async throws -> GenesisResult {
        let block = try await BlockBuilder.buildGenesis(
            spec: config.spec,
            timestamp: config.timestamp,
            difficulty: config.difficulty,
            fetcher: fetcher
        )
        let blockHash = HeaderImpl<Block>(node: block).rawCID
        let chainState = ChainState.fromGenesis(block: block)
        return GenesisResult(block: block, blockHash: blockHash, chainState: chainState)
    }

    public static func verify(block: Block, config: GenesisConfig) -> Bool {
        guard block.index == 0 else { return false }
        guard block.previousBlock == nil else { return false }
        guard block.timestamp == config.timestamp else { return false }
        guard block.spec.node != nil else { return false }
        let emptyState = LatticeStateHeader(node: LatticeState.emptyState())
        guard block.homestead.rawCID == emptyState.rawCID else { return false }
        return true
    }
}
