import cashew
import UInt256

public protocol LatticeDelegate: AnyObject, Sendable {
    func lattice(_ lattice: Lattice, didDiscoverChildChain directory: String) async
}

public actor Lattice {
    public let nexus: ChainLevel
    public weak var delegate: LatticeDelegate?
    private var subscribedChains: Set<String>

    public init(nexus: ChainLevel, subscribedChains: Set<String> = []) {
        self.nexus = nexus
        self.subscribedChains = subscribedChains
    }

    public func setDelegate(_ delegate: LatticeDelegate) {
        self.delegate = delegate
    }

    public func subscribe(to directory: String) {
        subscribedChains.insert(directory)
    }

    public func unsubscribe(from directory: String) {
        subscribedChains.remove(directory)
    }

    public func getSubscribedChains() -> Set<String> {
        subscribedChains
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
                    fetcher: fetcher,
                    subscribedChains: subscribedChains
                )
                for dir in newChildren {
                    await delegate?.lattice(self, didDiscoverChildChain: dir)
                }
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

    public func restoreChildChain(directory: String, level: ChainLevel) {
        guard children[directory] == nil else { return }
        children[directory] = level
    }

    public func childDirectories() -> [String] {
        Array(children.keys)
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

    @discardableResult
    func extractAndProcessChildBlocks(
        parentBlock: Block,
        parentBlockHeader: BlockHeader,
        fetcher: Fetcher,
        subscribedChains: Set<String> = [],
        ancestorSpecs: [ChainSpec] = []
    ) async -> [String] {
        guard let childBlocksNode = try? await parentBlock.childBlocks.resolve(fetcher: fetcher).node else { return [] }
        guard let allChildKeys = try? childBlocksNode.allKeys() else { return [] }
        if allChildKeys.isEmpty { return [] }

        let relevantKeys = subscribedChains.isEmpty
            ? Set(allChildKeys)
            : Set(allChildKeys).intersection(subscribedChains)
        if relevantKeys.isEmpty { return [] }

        let parentBlockIndex = await chain.getHighestBlockIndex()

        var allAncestorSpecs = ancestorSpecs
        if let parentSpec = try? await parentBlock.spec.resolve(fetcher: fetcher).node {
            allAncestorSpecs.append(parentSpec)
        }

        var newChildDirectories: [String] = []
        for directory in relevantKeys {
            if children[directory] == nil {
                guard let childBlockHeader = try? childBlocksNode.get(key: directory) else { continue }
                if let childBlock = try? await childBlockHeader.resolve(fetcher: fetcher).node,
                   childBlock.index == 0, childBlock.previousBlock == nil {
                    registerChildChain(directory: directory, genesisBlock: childBlock)
                    newChildDirectories.append(directory)
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for directory in relevantKeys {
                guard let childLevel = children[directory] else { continue }
                guard let childBlockHeader = try? childBlocksNode.get(key: directory) else { continue }

                group.addTask { [parentBlockHeader, parentBlockIndex, allAncestorSpecs, subscribedChains] in
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
                        subscribedChains: subscribedChains,
                        ancestorSpecs: allAncestorSpecs
                    )
                }
            }
        }
        return newChildDirectories
    }

    // MARK: - Child Block Validation
    //
    // Validates a child block independently before accepting it into
    // the child chain. Returns false if the block is invalid -- the
    // caller skips it without affecting the parent block.

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
            let emptyState = LatticeStateHeader(node: LatticeState.emptyState())
            if childBlock.homestead.rawCID != emptyState.rawCID { return false }
        }

        guard let transactionsNode = try? await childBlock.transactions.resolveRecursive(fetcher: fetcher).node else { return false }
        guard let txKeysAndValues = try? transactionsNode.allKeysAndValues() else { return false }
        let bodies = txKeysAndValues.values.compactMap { $0.node?.body.node }

        if let specNode = childBlock.spec.node {
            if !bodies.allSatisfy({ $0.verifyFilters(spec: specNode) }) { return false }
            if !bodies.allSatisfy({ $0.verifyActionFilters(spec: specNode) }) { return false }
        }

        if let parentSpecNode = try? await parentBlock.spec.resolve(fetcher: fetcher).node {
            if !bodies.allSatisfy({ $0.verifyFilters(spec: parentSpecNode) }) { return false }
            if !bodies.allSatisfy({ $0.verifyActionFilters(spec: parentSpecNode) }) { return false }
        }

        for ancestorSpec in ancestorSpecs {
            if !bodies.allSatisfy({ $0.verifyFilters(spec: ancestorSpec) }) { return false }
            if !bodies.allSatisfy({ $0.verifyActionFilters(spec: ancestorSpec) }) { return false }
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
