import cashew
import UInt256

public actor Lattice {
    let nexus: ChainLevel

    public init(nexus: ChainLevel) {
        self.nexus = nexus
    }

    public func processBlockHeader(_ blockHeader: BlockHeader, fetcher: Fetcher) async -> Bool {
        if await nexus.chain.contains(blockHash: blockHeader.rawCID) { return false }
        guard let resolvedBlock = try? await blockHeader.resolve(fetcher: fetcher).node else { return false }
        guard let validated = try? await resolvedBlock.validateNexus(fetcher: fetcher) else { return false }
        if !validated { return false }
        let blockHash = resolvedBlock.getDifficultyHash()
        if resolvedBlock.validateBlockDifficulty(nexusHash: blockHash) {
            let result = await nexus.chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: blockHeader,
                block: resolvedBlock
            )
            if let reorg = result.reorganization {
                await nexus.propagateReorgToChildren(reorg: reorg)
            }
            if result.extendsMainChain || result.reorganization != nil {
                await nexus.extractAndProcessChildBlocks(
                    parentBlock: resolvedBlock,
                    parentBlockHeader: blockHeader,
                    fetcher: fetcher
                )
                return true
            }
            return await nexus.processNonChainBlockForChildren(
                blockHash: blockHash,
                block: resolvedBlock,
                fetcher: fetcher
            )
        } else {
            return await nexus.processNonChainBlockForChildren(
                blockHash: blockHash,
                block: resolvedBlock,
                fetcher: fetcher
            )
        }
    }
}

public actor ChainLevel {
    public let chain: ChainState
    public let children: [String: ChainLevel]

    public init(chain: ChainState, children: [String: ChainLevel]) {
        self.chain = chain
        self.children = children
    }

    // MARK: - Child Block Extraction
    //
    // After a parent block is accepted, extract embedded child blocks
    // from its childBlocks Merkle dictionary and submit each to the
    // corresponding child chain. This is how merged-mined child blocks
    // enter their respective chains.

    func extractAndProcessChildBlocks(
        parentBlock: Block,
        parentBlockHeader: BlockHeader,
        fetcher: Fetcher
    ) async {
        guard let childBlocksNode = try? await parentBlock.childBlocks.resolve(fetcher: fetcher).node else { return }
        guard let allChildEntries = try? childBlocksNode.allKeysAndValues() else { return }
        if allChildEntries.isEmpty { return }

        let parentBlockIndex = await chain.getHighestBlockIndex()

        await withTaskGroup(of: Void.self) { group in
            for (directory, childBlockHeader) in allChildEntries {
                guard let childLevel = children[directory] else { continue }

                group.addTask { [parentBlockHeader, parentBlockIndex] in
                    guard let childBlock = try? await childBlockHeader.resolve(fetcher: fetcher).node else { return }

                    let result = await childLevel.chain.submitBlock(
                        parentBlockHeaderAndIndex: (parentBlockHeader.rawCID, parentBlockIndex),
                        blockHeader: childBlockHeader,
                        block: childBlock
                    )
                    if let reorg = result.reorganization {
                        await childLevel.propagateReorgToChildren(reorg: reorg)
                    }

                    await childLevel.extractAndProcessChildBlocks(
                        parentBlock: childBlock,
                        parentBlockHeader: childBlockHeader,
                        fetcher: fetcher
                    )
                }
            }
        }
    }

    // MARK: - Non-Chain Block Dispatch (Merged Mining)
    //
    // When a block doesn't meet the current chain's difficulty target,
    // offer it to child chains whose difficulty targets it may meet.

    func processNonChainBlockForChildren(
        blockHash: UInt256,
        block: Block,
        fetcher: Fetcher
    ) async -> Bool {
        let childBlockHeader = BlockHeader(node: block)
        let parentBlockIndex = await chain.getHighestBlockIndex()
        let parentInfo = (childBlockHeader.rawCID, parentBlockIndex)

        return await withTaskGroup(of: Bool.self) { group in
            for (_, child) in children {
                group.addTask { [parentInfo, childBlockHeader, block] in
                    let result = await child.chain.submitBlock(
                        parentBlockHeaderAndIndex: parentInfo,
                        blockHeader: childBlockHeader,
                        block: block
                    )
                    if let reorg = result.reorganization {
                        await child.propagateReorgToChildren(reorg: reorg)
                    }
                    return result.extendsMainChain || result.reorganization != nil
                }
            }
            for await success in group {
                if success { return true }
            }
            return false
        }
    }

    func propagateReorgToChildren(reorg: Reorganization) async {
        await withTaskGroup(of: Void.self) { group in
            for (_, child) in children {
                group.addTask { [reorg] in
                    if let childReorg = await child.chain.propagateParentReorg(reorg: reorg) {
                        await child.propagateReorgToChildren(reorg: childReorg)
                    }
                }
            }
        }
    }
}
