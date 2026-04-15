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
        guard let childBlocksNode = try? await parentBlock.childBlocks.resolve(
            paths: [[""]: .list], fetcher: fetcher
        ).node else { print("[LATTICE] childBlocks resolve failed"); return [] }
        guard let allChildKeys = try? childBlocksNode.allKeys() else { print("[LATTICE] allKeys failed"); return [] }
        if allChildKeys.isEmpty { return [] }
        print("[LATTICE] extractAndProcessChildBlocks: keys=\(allChildKeys)")

        let parentBlockIndex = await chain.getHighestBlockIndex()

        var allAncestorSpecs = ancestorSpecs
        if let parentSpec = try? await parentBlock.spec.resolve(fetcher: fetcher).node {
            allAncestorSpecs.append(parentSpec)
        }

        var newChildDirectories: [String] = []
        for directory in allChildKeys {
            if children[directory] == nil {
                print("[LATTICE] child '\(directory)' not yet subscribed, attempting auto-subscribe")
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
                guard let childLevel = children[directory] else { print("[LATTICE] no childLevel for '\(directory)'"); continue }
                guard let childBlockHeader = try? childBlocksNode.get(key: directory) else { print("[LATTICE] get(key:) failed for '\(directory)'"); continue }

                group.addTask { [parentBlockHeader, parentBlockIndex, allAncestorSpecs] in
                    guard let childBlock = try? await childBlockHeader.resolve(fetcher: fetcher).node else { print("[LATTICE] child block resolve failed for '\(directory)'"); return }

                    let childChainPath = allAncestorSpecs.map { $0.directory } + [directory]
                    let isValid = await childLevel.validateChildBlock(
                        childBlock: childBlock,
                        parentBlock: parentBlock,
                        ancestorSpecs: allAncestorSpecs,
                        chainPath: childChainPath,
                        fetcher: fetcher
                    )
                    if !isValid { print("[LATTICE] child block validation FAILED for '\(directory)' at index \(childBlock.index)"); return }
                    print("[LATTICE] child block validated for '\(directory)' at index \(childBlock.index)")

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
        chainPath: [String] = [],
        fetcher: Fetcher
    ) async -> Bool {
        if parentBlock.timestamp != childBlock.timestamp { print("[VALIDATE] timestamp mismatch: parent=\(parentBlock.timestamp) child=\(childBlock.timestamp)"); return false }

        if let previousBlockHeader = childBlock.previousBlock {
            guard let previousBlock = try? await previousBlockHeader.resolve(fetcher: fetcher).node else {
                print("[VALIDATE] could not resolve previousBlock CID=\(previousBlockHeader.rawCID)")
                return false
            }
            if previousBlock.spec.rawCID != childBlock.spec.rawCID { print("[VALIDATE] spec mismatch"); return false }
            if previousBlock.frontier.rawCID != childBlock.homestead.rawCID { print("[VALIDATE] frontier/homestead mismatch"); return false }
            if childBlock.parentHomestead.rawCID != parentBlock.homestead.rawCID { print("[VALIDATE] parentHomestead mismatch for non-genesis child"); return false }
            if previousBlock.index + 1 != childBlock.index { print("[VALIDATE] index mismatch: prev=\(previousBlock.index) child=\(childBlock.index)"); return false }
            if previousBlock.timestamp >= childBlock.timestamp { print("[VALIDATE] timestamp ordering: prev=\(previousBlock.timestamp) child=\(childBlock.timestamp)"); return false }
        } else {
            if childBlock.index != 0 { print("[VALIDATE] non-zero index with no previousBlock"); return false }
            if childBlock.parentHomestead.rawCID != parentBlock.homestead.rawCID { print("[VALIDATE] parentHomestead mismatch"); return false }
            let emptyState = LatticeState.emptyHeader
            if childBlock.homestead.rawCID != emptyState.rawCID { print("[VALIDATE] homestead not empty for genesis child"); return false }
        }

        guard let specNode = try? await childBlock.spec.resolve(fetcher: fetcher).node else { print("[VALIDATE] spec resolve failed"); return false }

        guard let transactionsNode = try? await childBlock.transactions.resolveRecursive(fetcher: fetcher).node else { print("[VALIDATE] transactions resolve failed"); return false }
        guard let txKeysAndValues = try? transactionsNode.allKeysAndValues() else { print("[VALIDATE] tx allKeysAndValues failed"); return false }
        let txHeaders = txKeysAndValues.values
        if txHeaders.contains(where: { $0.node == nil }) { print("[VALIDATE] unresolved tx header"); return false }
        let txs = txHeaders.map { $0.node! }

        // Validate each transaction's signatures and authorization
        async let homesteadStateFuture = childBlock.homestead.resolve(fetcher: fetcher)
        async let parentStateFuture = childBlock.parentHomestead.resolve(fetcher: fetcher)
        guard let homesteadStateNode = try? await homesteadStateFuture.node else { print("[VALIDATE] homestead state resolve failed"); return false }
        guard let parentHomesteadStateNode = try? await parentStateFuture.node else { print("[VALIDATE] parentHomestead state resolve failed"); return false }
        for tx in txs {
            guard let valid = try? await tx.validateTransaction(
                directory: specNode.directory,
                homestead: homesteadStateNode,
                parentState: parentHomesteadStateNode,
                fetcher: fetcher
            ) else { print("[VALIDATE] tx.validateTransaction threw"); return false }
            if !valid { print("[VALIDATE] tx.validateTransaction returned false"); return false }
        }

        let bodiesMaybe = txs.map { $0.body.node }
        if bodiesMaybe.contains(where: { $0 == nil }) { print("[VALIDATE] unresolved tx body"); return false }
        let bodies = bodiesMaybe.map { $0! }

        if !childBlock.validateChainPaths(transactionBodies: bodies, expectedPath: chainPath) { print("[VALIDATE] chainPaths failed, expected=\(chainPath)"); return false }

        if !TransactionBody.batchVerifyFilters(bodies: bodies, spec: specNode) { print("[VALIDATE] child spec filter failed"); return false }
        if !TransactionBody.batchVerifyActionFilters(bodies: bodies, spec: specNode) { print("[VALIDATE] child spec action filter failed"); return false }

        if let parentSpecNode = try? await parentBlock.spec.resolve(fetcher: fetcher).node {
            if !TransactionBody.batchVerifyFilters(bodies: bodies, spec: parentSpecNode) { print("[VALIDATE] parent spec filter failed"); return false }
            if !TransactionBody.batchVerifyActionFilters(bodies: bodies, spec: parentSpecNode) { print("[VALIDATE] parent spec action filter failed"); return false }
        }

        for ancestorSpec in ancestorSpecs {
            if !TransactionBody.batchVerifyFilters(bodies: bodies, spec: ancestorSpec) { print("[VALIDATE] ancestor spec filter failed for \(ancestorSpec.directory)"); return false }
            if !TransactionBody.batchVerifyActionFilters(bodies: bodies, spec: ancestorSpec) { print("[VALIDATE] ancestor spec action filter failed for \(ancestorSpec.directory)"); return false }
        }

        if !childBlock.validateMaxTransactionCount(spec: specNode, transactionBodies: bodies) { print("[VALIDATE] maxTxCount failed"); return false }
        if (try? childBlock.validateStateDeltaSize(spec: specNode, transactionBodies: bodies)) != true { print("[VALIDATE] stateDeltaSize failed"); return false }
        if !childBlock.validateBlockSize(spec: specNode) { print("[VALIDATE] blockSize failed"); return false }

        // Balance conservation
        let allAccountActions = bodies.flatMap { $0.accountActions }
        let allDepositActions = bodies.flatMap { $0.depositActions }
        let allWithdrawalActions = bodies.flatMap { $0.withdrawalActions }
        let (totalFees, feesOverflow) = Block.getTotalFees(bodies)
        if feesOverflow { print("[VALIDATE] fees overflow"); return false }
        if (try? childBlock.validateBalanceChanges(
            spec: specNode,
            allDepositActions: allDepositActions,
            allWithdrawalActions: allWithdrawalActions,
            allAccountActions: allAccountActions,
            totalFees: totalFees
        )) != true { print("[VALIDATE] balance conservation failed"); return false }

        // Verify frontier state root: re-derive from homestead + transactions
        let frontierValid: Bool
        do {
            frontierValid = try await childBlock.validateFrontierState(
                transactionBodies: bodies, fetcher: fetcher
            )
        } catch {
            print("[VALIDATE] frontier state threw: \(error)")
            return false
        }
        if !frontierValid { print("[VALIDATE] frontier state invalid"); return false }

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
