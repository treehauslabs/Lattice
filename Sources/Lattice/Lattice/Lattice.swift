import cashew
import UInt256

public struct Lattice {
    let nexus: ChainLevel
    
    func processBlockHeader(_ blockHeader: BlockHeader, fetcher: Fetcher) async -> Bool {
        if await nexus.chain.contains(blockHash: blockHeader.rawCID) { return false }
        guard let resolvedBlock = try? await blockHeader.resolve(fetcher: fetcher).node else { return false }
        guard let validated = try? await resolvedBlock.validateNexus(fetcher: fetcher) else { return false }
        let blockHash = resolvedBlock.getDifficultyHash()
        if !validated { return false }
        if resolvedBlock.validateBlockDifficulty(nexusHash: blockHash) {
            let result = await nexus.chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader, block: resolvedBlock)
            if !result.extendsMainChain && result.reorganization == nil {
                return await nexus.processNonChainBlockForChildren(blockHash: blockHash, block: resolvedBlock, fetcher: fetcher)
            }
        } else {
            return await nexus.processNonChainBlockForChildren(blockHash: blockHash, block: resolvedBlock, fetcher: fetcher)
        }
    }
}

public struct ChainLevel {
    let chain: Chain
    let children: [String: ChainLevel]
    
    func processNonChainBlockForChildren(blockHash: UInt256, block: Block, fetcher: Fetcher) async -> Bool {
        return false
    }
}
