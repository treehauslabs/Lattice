import cashew
import UInt256

public protocol LatticeDelegate: AnyObject, Sendable {
    func lattice(_ lattice: Lattice, didDiscoverChildChain directory: String) async
}

public actor Lattice {
    public let nexus: ChainLevel
    public weak var delegate: LatticeDelegate?

    public init(nexus: ChainLevel) {
        self.nexus = nexus
    }

    public func setDelegate(_ delegate: LatticeDelegate) {
        self.delegate = delegate
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
                let newChildren = await nexus.extractAndProcessChildBlocks(
                    parentBlock: resolvedBlock,
                    parentBlockHeader: blockHeader,
                    fetcher: fetcher
                )
                for dir in newChildren {
                    await delegate?.lattice(self, didDiscoverChildChain: dir)
                }
                return true
            }
        }
        return await nexus.processNonChainBlockForChildren(
            blockHash: blockHash,
            block: resolvedBlock,
            fetcher: fetcher
        )
    }
}

public actor ChainLevel {
    public let chain: ChainState
    public private(set) var children: [String: ChainLevel]

    public init(chain: ChainState, children: [String: ChainLevel]) {
        self.chain = chain
        self.children = children
    }

    // MARK: - Child Chain Management

    public func subscribe(to directory: String, genesisBlock: Block, retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE) {
        guard children[directory] == nil else { return }
        let childChain = ChainState.fromGenesis(block: genesisBlock, retentionDepth: retentionDepth)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        children[directory] = childLevel
    }

    public func restoreChildChain(directory: String, level: ChainLevel) {
        guard children[directory] == nil else { return }
        children[directory] = level
    }

    public func childDirectories() -> [String] {
        Array(children.keys)
    }

    // MARK: - Child Block Extraction (Merged Mining)

    @discardableResult
    func extractAndProcessChildBlocks(
        parentBlock: Block,
        parentBlockHeader: BlockHeader,
        fetcher: Fetcher,
        ancestorSpecs: [ChainSpec] = []
    ) async -> [String] {
        guard let childBlocksNode = try? await parentBlock.childBlocks.resolve(fetcher: fetcher).node else { return [] }
        guard let allChildKeys = try? childBlocksNode.allKeys() else { return [] }
        if allChildKeys.isEmpty { return [] }

        let parentBlockIndex = await chain.getHighestBlockIndex()

        var allAncestorSpecs = ancestorSpecs
        if let parentSpec = try? await parentBlock.spec.resolve(fetcher: fetcher).node {
            allAncestorSpecs.append(parentSpec)
        }

        var newChildDirectories: [String] = []
        for directory in allChildKeys {
            if children[directory] == nil {
                guard let childBlockHeader = try? childBlocksNode.get(key: directory) else { continue }
                if let childBlock = try? await childBlockHeader.resolve(fetcher: fetcher).node,
                   childBlock.index == 0, childBlock.previousBlock == nil {
                    subscribe(to: directory, genesisBlock: childBlock)
                    newChildDirectories.append(directory)
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for directory in allChildKeys {
                guard let childLevel = children[directory] else { continue }
                guard let childBlockHeader = try? childBlocksNode.get(key: directory) else { continue }

                group.addTask { [parentBlockHeader, parentBlockIndex, allAncestorSpecs] in
                    guard let childBlock = try? await childBlockHeader.resolve(fetcher: fetcher).node else { return }

                    let isValid = await childLevel.validateChildBlock(
                        childBlock: childBlock,
                        parentBlock: parentBlock,
                        ancestorSpecs: allAncestorSpecs,
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

                    await childLevel.extractAndProcessChildBlocks(
                        parentBlock: childBlock,
                        parentBlockHeader: childBlockHeader,
                        fetcher: fetcher,
                        ancestorSpecs: allAncestorSpecs
                    )
                }
            }
        }
        return newChildDirectories
    }

    // MARK: - Child Block Validation

    func validateChildBlock(
        childBlock: Block,
        parentBlock: Block,
        ancestorSpecs: [ChainSpec] = [],
        fetcher: Fetcher
    ) async -> Bool {
        if parentBlock.timestamp != childBlock.timestamp { return false }

        if let previousBlockHeader = childBlock.previousBlock {
            guard let previousBlock = try? await previousBlockHeader.resolve(fetcher: fetcher).node else {
                return true
            }
            if previousBlock.spec.rawCID != childBlock.spec.rawCID { return false }
            if previousBlock.frontier.rawCID != childBlock.homestead.rawCID { return false }
            if previousBlock.index + 1 != childBlock.index { return false }
            if previousBlock.timestamp >= childBlock.timestamp { return false }
        } else {
            if childBlock.index != 0 { return false }
            if childBlock.parentHomestead.rawCID != parentBlock.homestead.rawCID { return false }
            let emptyState = LatticeState.emptyHeader
            if childBlock.homestead.rawCID != emptyState.rawCID { return false }
        }

        guard let transactionsNode = try? await childBlock.transactions.resolveRecursive(fetcher: fetcher).node else { return false }
        guard let txKeysAndValues = try? transactionsNode.allKeysAndValues() else { return false }
        let bodies = txKeysAndValues.values.compactMap { $0.node?.body.node }

        if let specNode = childBlock.spec.node {
            if !TransactionBody.batchVerifyFilters(bodies: bodies, spec: specNode) { return false }
            if !TransactionBody.batchVerifyActionFilters(bodies: bodies, spec: specNode) { return false }
        }

        if let parentSpecNode = try? await parentBlock.spec.resolve(fetcher: fetcher).node {
            if !TransactionBody.batchVerifyFilters(bodies: bodies, spec: parentSpecNode) { return false }
            if !TransactionBody.batchVerifyActionFilters(bodies: bodies, spec: parentSpecNode) { return false }
        }

        for ancestorSpec in ancestorSpecs {
            if !TransactionBody.batchVerifyFilters(bodies: bodies, spec: ancestorSpec) { return false }
            if !TransactionBody.batchVerifyActionFilters(bodies: bodies, spec: ancestorSpec) { return false }
        }

        // Verify frontier state root: re-derive from homestead + transactions
        guard let frontierValid = try? await childBlock.validateFrontierState(
            transactionBodies: bodies, fetcher: fetcher
        ) else { return false }
        if !frontierValid { return false }

        return true
    }

    // MARK: - Non-Chain Block Dispatch (Merged Mining)

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
