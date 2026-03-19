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
                // Parent block is accepted. Child blocks are processed
                // independently -- invalid child blocks are skipped without
                // affecting the parent block's validity or other children.
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
    public private(set) var children: [String: ChainLevel]

    public init(chain: ChainState, children: [String: ChainLevel]) {
        self.chain = chain
        self.children = children
    }

    // MARK: - Dynamic Chain Discovery
    //
    // When a GenesisAction creates a new child chain, this method registers
    // it in the hierarchy so it can receive merged-mined blocks going forward.

    public func registerChildChain(directory: String, genesisBlock: Block) {
        guard children[directory] == nil else { return }
        let childChain = ChainState.fromGenesis(block: genesisBlock)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        children[directory] = childLevel
    }

    // MARK: - Child Block Extraction (Merged Mining)
    //
    // Child blocks embedded in a parent block via merged mining are
    // OPTIONAL. An invalid child block does not affect:
    //   - The parent block's validity
    //   - Other child chains' blocks in the same parent
    //   - Grandchild blocks under a different valid child
    //
    // Each child block is validated independently against its chain's
    // rules. Invalid blocks are silently skipped. This prevents child
    // chain issues from bottlenecking the nexus and ensures a single
    // malformed child block can't poison the entire merged-mined set.

    func extractAndProcessChildBlocks(
        parentBlock: Block,
        parentBlockHeader: BlockHeader,
        fetcher: Fetcher
    ) async {
        guard let childBlocksNode = try? await parentBlock.childBlocks.resolve(fetcher: fetcher).node else { return }
        guard let allChildEntries = try? childBlocksNode.allKeysAndValues() else { return }
        if allChildEntries.isEmpty { return }

        let parentBlockIndex = await chain.getHighestBlockIndex()

        for (directory, childBlockHeader) in allChildEntries {
            if children[directory] == nil {
                if let childBlock = try? await childBlockHeader.resolve(fetcher: fetcher).node,
                   childBlock.index == 0, childBlock.previousBlock == nil {
                    registerChildChain(directory: directory, genesisBlock: childBlock)
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for (directory, childBlockHeader) in allChildEntries {
                guard let childLevel = children[directory] else { continue }

                group.addTask { [parentBlockHeader, parentBlockIndex] in
                    guard let childBlock = try? await childBlockHeader.resolve(fetcher: fetcher).node else { return }

                    let isValid = await childLevel.validateChildBlock(
                        childBlock: childBlock,
                        parentBlock: parentBlock,
                        fetcher: fetcher
                    )
                    if !isValid { return }

                    let result = await childLevel.chain.submitBlock(
                        parentBlockHeaderAndIndex: (parentBlockHeader.rawCID, parentBlockIndex),
                        blockHeader: childBlockHeader,
                        block: childBlock
                    )
                    if let reorg = result.reorganization {
                        await childLevel.propagateReorgToChildren(reorg: reorg)
                    }

                    // Recursively extract grandchild blocks. If this child
                    // block is valid but contains invalid grandchild blocks,
                    // those grandchildren are skipped independently.
                    await childLevel.extractAndProcessChildBlocks(
                        parentBlock: childBlock,
                        parentBlockHeader: childBlockHeader,
                        fetcher: fetcher
                    )
                }
            }
        }
    }

    // MARK: - Child Block Validation
    //
    // Validates a child block independently before accepting it into
    // the child chain. Returns false if the block is invalid -- the
    // caller skips it without affecting the parent block.

    func validateChildBlock(
        childBlock: Block,
        parentBlock: Block,
        fetcher: Fetcher
    ) async -> Bool {
        // Timestamp must match parent (merged mining requirement)
        if parentBlock.timestamp != childBlock.timestamp { return false }

        // If the child block has a previous block, validate chain continuity
        if let previousBlockHeader = childBlock.previousBlock {
            guard let previousBlock = try? await previousBlockHeader.resolve(fetcher: fetcher).node else {
                // Previous block can't be resolved -- may arrive later.
                // Still accept into consensus (submitBlock handles orphans).
                return true
            }

            // Spec must be consistent with the chain
            if previousBlock.spec.rawCID != childBlock.spec.rawCID { return false }

            // State continuity: homestead must equal previous frontier
            if previousBlock.frontier.rawCID != childBlock.homestead.rawCID { return false }

            // Index must be sequential
            if previousBlock.index + 1 != childBlock.index { return false }

            // Timestamp must be after previous
            if previousBlock.timestamp >= childBlock.timestamp { return false }
        } else {
            // No previous block means this is a genesis block on the child chain.
            // Genesis validation is handled by GenesisAction in the parent
            // chain's transaction -- not here. Accept it.
            if childBlock.index != 0 { return false }
        }

        // Validate child chain's own filters
        if let specNode = childBlock.spec.node {
            guard let transactionsNode = try? await childBlock.transactions.resolveRecursive(fetcher: fetcher).node else { return false }
            guard let txKeysAndValues = try? transactionsNode.allKeysAndValues() else { return false }
            let txHeaders = txKeysAndValues.values
            let txs = txHeaders.compactMap { $0.node }
            let bodies = txs.compactMap { $0.body.node }
            if !bodies.allSatisfy({ $0.verifyFilters(spec: specNode) }) { return false }
            if !bodies.allSatisfy({ $0.verifyActionFilters(spec: specNode) }) { return false }
        }

        // Validate against parent chain's filters (filter inheritance)
        if let parentSpecNode = try? await parentBlock.spec.resolve(fetcher: fetcher).node {
            guard let transactionsNode = try? await childBlock.transactions.resolveRecursive(fetcher: fetcher).node else { return false }
            guard let txKeysAndValues = try? transactionsNode.allKeysAndValues() else { return false }
            let bodies = txKeysAndValues.values.compactMap { $0.node?.body.node }
            if !bodies.allSatisfy({ $0.verifyFilters(spec: parentSpecNode) }) { return false }
            if !bodies.allSatisfy({ $0.verifyActionFilters(spec: parentSpecNode) }) { return false }
        }

        return true
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
