import cashew
import UInt256

public protocol LatticeDelegate: AnyObject, Sendable {
    func lattice(_ lattice: Lattice, didDiscoverChildChain directory: String) async
}

public struct ChildTreeResult: Sendable {
    public let newlyDiscovered: [String]
    public let anyAccepted: Bool

    public static let empty = ChildTreeResult(newlyDiscovered: [], anyAccepted: false)
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

    public func processBlockHeader(_ blockHeader: BlockHeader, fetcher: Fetcher, skipValidation: Bool = false) async -> (Bool, StateDiff) {
        let tag = String(blockHeader.rawCID.prefix(16))
        let tTotal = ContinuousClock.now

        if await nexus.chain.contains(blockHash: blockHeader.rawCID) {
            return (false, .empty)
        }

        guard let resolvedBlock = try? await blockHeader.resolve(fetcher: fetcher).node else {
            print("[LATTICE] processBlockHeader \(tag) FAIL resolve")
            return (false, .empty)
        }

        let nexusHash = resolvedBlock.getDifficultyHash()
        let meetsNexusDifficulty = skipValidation || resolvedBlock.validateBlockDifficulty(nexusHash: nexusHash)

        var nexusAccepted = false
        var nexusDiff = StateDiff.empty
        if meetsNexusDifficulty {
            if !skipValidation {
                let (validated, diff) = (try? await resolvedBlock.validateNexus(fetcher: fetcher, chain: nexus.chain)) ?? (false, .empty)
                if !validated {
                    print("[LATTICE] processBlockHeader \(tag) FAIL validateNexus")
                    return (false, .empty)
                }
                nexusDiff = diff
            }
            let result = await nexus.chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: blockHeader,
                block: resolvedBlock
            )
            if let reorg = result.reorganization {
                await nexus.propagateReorgToChildren(reorg: reorg)
            }
            nexusAccepted = result.extendsMainChain || result.reorganization != nil
        } else if !skipValidation {
            // Block won't enter the nexus chain, but its child blocks anchor
            // against this block's homestead. If the homestead is forged,
            // grandchild withdrawals could reference fabricated state. Verify
            // only homestead continuity (cheap) and skip the rest of
            // validateNexus (expensive, unnecessary).
            let valid = await ChainLevel.validateHomesteadContinuity(
                block: resolvedBlock, chain: nexus.chain, fetcher: fetcher
            )
            if !valid {
                print("[LATTICE] processBlockHeader \(tag) FAIL homestead continuity")
                return (false, .empty)
            }
        }

        // Always walk the entire childBlocks tree: per the PoW-per-level rule,
        // grandchildren may pass a level's difficulty even when the intermediate
        // block (or the nexus itself) does not.
        let treeResult = await processChildBlockTree(
            parentBlock: resolvedBlock,
            parentBlockHeader: blockHeader,
            fetcher: fetcher
        )

        let accepted = nexusAccepted || treeResult.anyAccepted
        let dTotal = ContinuousClock.now - tTotal
        print("[LATTICE] processBlockHeader \(tag) accepted=\(accepted) nexus=\(nexusAccepted) anyChild=\(treeResult.anyAccepted) newChildren=\(treeResult.newlyDiscovered.count) total=\(dTotal)")
        return (accepted, nexusDiff)
    }

    /// Drive child-side effects of a parent block: discover and subscribe new
    /// children, submit embedded child blocks recursively through the merged-
    /// mining tree, and notify the delegate of newly-discovered directories.
    ///
    /// The caller is responsible for ensuring `parentBlock` is already accepted
    /// into the nexus chain — this method does not run nexus-level validation
    /// or `submitBlock`. Use it when bulk chain state has been installed
    /// out-of-band (e.g., snapshot-sync `chain.resetFrom`) and only the per-
    /// parent child-tree side effects remain.
    @discardableResult
    public func processChildBlockTree(
        parentBlock: Block,
        parentBlockHeader: BlockHeader,
        fetcher: Fetcher
    ) async -> ChildTreeResult {
        let result = await nexus.acceptChildBlockTree(
            parentBlock: parentBlock,
            parentBlockHeader: parentBlockHeader,
            nexusHash: parentBlock.getDifficultyHash(),
            fetcher: fetcher
        )
        for dir in result.newlyDiscovered {
            await delegate?.lattice(self, didDiscoverChildChain: dir)
        }
        return result
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

    /// DFS-walk this level and all descendants, returning the level whose
    /// directory matches the target plus the chain path from the receiver
    /// down to (and including) that level. `chainPath` is passed in by the
    /// caller to anchor the path at the correct root (e.g. `[nexusDir]` when
    /// starting from nexus).
    public func findLevel(directory target: String, chainPath: [String]) async -> (level: ChainLevel, chainPath: [String])? {
        if chainPath.last == target { return (self, chainPath) }
        for (childDir, childLevel) in children {
            if childDir == target {
                return (childLevel, chainPath + [childDir])
            }
            if let hit = await childLevel.findLevel(directory: target, chainPath: chainPath + [childDir]) {
                return hit
            }
        }
        return nil
    }

    /// DFS walk collecting every descendant's directory and full chain path.
    /// `chainPath` is the path to this receiver; callers pass e.g. `[nexusDir]`
    /// to anchor paths at the nexus.
    public func collectAllLevels(chainPath: [String]) async -> [(level: ChainLevel, chainPath: [String])] {
        var result: [(level: ChainLevel, chainPath: [String])] = [(self, chainPath)]
        for (childDir, childLevel) in children {
            let sub = await childLevel.collectAllLevels(chainPath: chainPath + [childDir])
            result.append(contentsOf: sub)
        }
        return result
    }

    // MARK: - Child Block Tree Walk (Merged Mining)
    //
    // For each block in the childBlocks tree hanging off `parentBlock`:
    //   1. Structurally validate the child.
    //   2. If `childBlock.validateBlockDifficulty(nexusHash:)` passes, submit
    //      to that child's chain.
    //   3. ALWAYS recurse into the child's own childBlocks — a grandchild may
    //      pass its level's target even when the intermediate child does not.
    //
    // Each accepted child is anchored to its direct parent level's chain via
    // `(parentBlockHeader.rawCID, chain.highestBlockIndex)` for fork choice.
    @discardableResult
    func acceptChildBlockTree(
        parentBlock: Block,
        parentBlockHeader: BlockHeader,
        nexusHash: UInt256,
        ancestorSpecs: [ChainSpec] = [],
        fetcher: Fetcher
    ) async -> ChildTreeResult {
        guard let childBlocksNode = try? await parentBlock.childBlocks.resolve(
            paths: [[""]: .list], fetcher: fetcher
        ).node else { return .empty }
        guard let allChildKeys = try? childBlocksNode.allKeys() else { return .empty }
        if allChildKeys.isEmpty { return .empty }

        let parentChainIndex = await chain.getHighestBlockIndex()

        var allAncestorSpecs = ancestorSpecs
        if let parentSpec = try? await parentBlock.spec.resolve(fetcher: fetcher).node {
            allAncestorSpecs.append(parentSpec)
        }

        var newlyDiscovered: [String] = []
        for directory in allChildKeys {
            if children[directory] == nil {
                guard let childBlockHeader = try? childBlocksNode.get(key: directory) else { continue }
                if let childBlock = try? await childBlockHeader.resolve(fetcher: fetcher).node,
                   childBlock.index == 0, childBlock.previousBlock == nil {
                    subscribe(to: directory, genesisBlock: childBlock)
                    newlyDiscovered.append(directory)
                }
            }
        }

        let subtreeResults = await withTaskGroup(of: ChildTreeResult.self, returning: ChildTreeResult.self) { group in
            for directory in allChildKeys {
                guard let childLevel = children[directory] else { continue }
                guard let childBlockHeader = try? childBlocksNode.get(key: directory) else { continue }

                group.addTask { [parentBlockHeader, parentChainIndex, allAncestorSpecs] in
                    guard let childBlock = try? await childBlockHeader.resolve(fetcher: fetcher).node else {
                        return .empty
                    }

                    let childChainPath = allAncestorSpecs.map { $0.directory } + [directory]
                    var localAccepted = false
                    if childBlock.validateBlockDifficulty(nexusHash: nexusHash) {
                        // Block can join this child's chain — full validation required.
                        let isValid = await childLevel.validateChildBlock(
                            childBlock: childBlock,
                            parentBlock: parentBlock,
                            ancestorSpecs: allAncestorSpecs,
                            chainPath: childChainPath,
                            fetcher: fetcher
                        )
                        if !isValid {
                            print("[LATTICE] child '\(directory)' FAIL structural validation")
                            return .empty
                        }
                        let result = await childLevel.chain.submitBlock(
                            parentBlockHeaderAndIndex: (parentBlockHeader.rawCID, parentChainIndex),
                            blockHeader: childBlockHeader,
                            block: childBlock
                        )
                        if let reorg = result.reorganization {
                            await childLevel.propagateReorgToChildren(reorg: reorg)
                        }
                        localAccepted = result.extendsMainChain || result.reorganization != nil
                        if localAccepted {
                            print("[LATTICE] child '\(directory)' #\(childBlock.index) ACCEPTED")
                        }
                    } else {
                        // Block won't join this chain. Reject structurally malformed
                        // cross-chain anchors, then verify homestead continuity so
                        // grandchildren can trust this block's homestead.
                        if childBlock.parentHomestead.rawCID != parentBlock.homestead.rawCID {
                            print("[LATTICE] child '\(directory)' FAIL parentHomestead mismatch")
                            return .empty
                        }
                        let valid = await ChainLevel.validateHomesteadContinuity(
                            block: childBlock,
                            chain: childLevel.chain,
                            fetcher: fetcher
                        )
                        if !valid {
                            print("[LATTICE] child '\(directory)' FAIL homestead continuity")
                            return .empty
                        }
                    }

                    let subResult = await childLevel.acceptChildBlockTree(
                        parentBlock: childBlock,
                        parentBlockHeader: childBlockHeader,
                        nexusHash: nexusHash,
                        ancestorSpecs: allAncestorSpecs,
                        fetcher: fetcher
                    )

                    return ChildTreeResult(
                        newlyDiscovered: subResult.newlyDiscovered,
                        anyAccepted: localAccepted || subResult.anyAccepted
                    )
                }
            }

            var combined: ChildTreeResult = .empty
            for await r in group {
                combined = ChildTreeResult(
                    newlyDiscovered: combined.newlyDiscovered + r.newlyDiscovered,
                    anyAccepted: combined.anyAccepted || r.anyAccepted
                )
            }
            return combined
        }

        return ChildTreeResult(
            newlyDiscovered: newlyDiscovered + subtreeResults.newlyDiscovered,
            anyAccepted: subtreeResults.anyAccepted
        )
    }

    // MARK: - Child Block Validation

    /// Cheap continuity check used when a block's PoW does not meet its
    /// chain's difficulty target. Verifies the block's own homestead is real
    /// (came from its previous block's frontier) so grandchildren anchoring
    /// `parentHomestead` against this homestead can trust it. Skips
    /// transactions, signatures, cross-chain references, frontier replay.
    static func validateHomesteadContinuity(block: Block, chain: ChainState, fetcher: Fetcher) async -> Bool {
        if let previousBlockHeader = block.previousBlock {
            // Require previousBlock to already be a validated block on this
            // chain (main chain or side chain). Any hash in the chain has
            // passed validateNexus/validateChildBlock, including frontier
            // replay — so its frontier is a trusted state. Without this
            // check, an attacker can fabricate a sequence of non-validated
            // blocks linked only by frontier==homestead, producing a forged
            // state that a grandchild withdrawal then redeems against.
            guard await chain.contains(blockHash: previousBlockHeader.rawCID) else { return false }
            guard let previousBlock = try? await previousBlockHeader.resolve(fetcher: fetcher).node else {
                return false
            }
            return previousBlock.frontier.rawCID == block.homestead.rawCID
        }
        if block.index != 0 { return false }
        return block.homestead.rawCID == LatticeState.emptyHeader.rawCID
    }

    public func validateChildBlock(
        childBlock: Block,
        parentBlock: Block,
        ancestorSpecs: [ChainSpec] = [],
        chainPath: [String] = [],
        fetcher: Fetcher
    ) async -> Bool {
        if parentBlock.timestamp != childBlock.timestamp { return false }

        if let previousBlockHeader = childBlock.previousBlock {
            guard let previousBlock = try? await previousBlockHeader.resolve(fetcher: fetcher).node else {
                return false
            }
            if previousBlock.spec.rawCID != childBlock.spec.rawCID { return false }
            if previousBlock.frontier.rawCID != childBlock.homestead.rawCID { return false }
            if childBlock.parentHomestead.rawCID != parentBlock.homestead.rawCID { return false }
            if previousBlock.index + 1 != childBlock.index { return false }
            if previousBlock.timestamp >= childBlock.timestamp { return false }
        } else {
            if childBlock.index != 0 { return false }
            if childBlock.parentHomestead.rawCID != parentBlock.homestead.rawCID { return false }
            let emptyState = LatticeState.emptyHeader
            if childBlock.homestead.rawCID != emptyState.rawCID { return false }
        }

        guard let specNode = try? await childBlock.spec.resolve(fetcher: fetcher).node else { return false }

        guard let transactionsNode = try? await childBlock.transactions.resolveRecursive(fetcher: fetcher).node else { return false }
        guard let txKeysAndValues = try? transactionsNode.allKeysAndValues() else { return false }
        let txHeaders = txKeysAndValues.values
        if txHeaders.contains(where: { $0.node == nil }) { return false }
        let txs = txHeaders.map { $0.node! }

        async let homesteadStateFuture = childBlock.homestead.resolve(fetcher: fetcher)
        async let parentStateFuture = childBlock.parentHomestead.resolve(fetcher: fetcher)
        guard let homesteadStateNode = try? await homesteadStateFuture.node else { return false }
        guard let parentHomesteadStateNode = try? await parentStateFuture.node else { return false }

        for tx in txs {
            guard let valid = try? await tx.validateTransaction(
                directory: specNode.directory,
                homestead: homesteadStateNode,
                parentState: parentHomesteadStateNode,
                fetcher: fetcher
            ) else { return false }
            if !valid { return false }
        }

        let bodiesMaybe = txs.map { $0.body.node }
        if bodiesMaybe.contains(where: { $0 == nil }) { return false }
        let bodies = bodiesMaybe.map { $0! }

        if !childBlock.validateChainPaths(transactionBodies: bodies, expectedPath: chainPath) { return false }

        if !TransactionBody.batchVerifyFilters(bodies: bodies, spec: specNode) { return false }
        if !TransactionBody.batchVerifyActionFilters(bodies: bodies, spec: specNode) { return false }

        if let parentSpecNode = try? await parentBlock.spec.resolve(fetcher: fetcher).node {
            if !TransactionBody.batchVerifyFilters(bodies: bodies, spec: parentSpecNode) { return false }
            if !TransactionBody.batchVerifyActionFilters(bodies: bodies, spec: parentSpecNode) { return false }
        }

        for ancestorSpec in ancestorSpecs {
            if !TransactionBody.batchVerifyFilters(bodies: bodies, spec: ancestorSpec) { return false }
            if !TransactionBody.batchVerifyActionFilters(bodies: bodies, spec: ancestorSpec) { return false }
        }

        if !childBlock.validateMaxTransactionCount(spec: specNode, transactionBodies: bodies) { return false }
        if (try? childBlock.validateStateDeltaSize(spec: specNode, transactionBodies: bodies)) != true { return false }
        if !childBlock.validateBlockSize(spec: specNode) { return false }

        let allAccountActions = bodies.flatMap { $0.accountActions }
        let allDepositActions = bodies.flatMap { $0.depositActions }
        let allWithdrawalActions = bodies.flatMap { $0.withdrawalActions }
        let (totalFees, feesOverflow) = Block.getTotalFees(bodies)
        if feesOverflow { return false }
        if (try? childBlock.validateBalanceChanges(
            spec: specNode,
            allDepositActions: allDepositActions,
            allWithdrawalActions: allWithdrawalActions,
            allAccountActions: allAccountActions,
            totalFees: totalFees
        )) != true { return false }

        let frontierValid: Bool
        do {
            (frontierValid, _) = try await childBlock.validateFrontierState(
                transactionBodies: bodies, fetcher: fetcher
            )
        } catch {
            return false
        }
        if !frontierValid { return false }

        return true
    }

    /// Legacy wrapper kept for tests that assert structural propagation
    /// without any PoW consideration. Uses `nexusHash = 0`, which always
    /// satisfies `difficulty >= nexusHash`, so every validated child is
    /// submitted to its chain.
    @discardableResult
    func extractAndProcessChildBlocks(
        parentBlock: Block,
        parentBlockHeader: BlockHeader,
        fetcher: Fetcher,
        ancestorSpecs: [ChainSpec] = []
    ) async -> [String] {
        let result = await acceptChildBlockTree(
            parentBlock: parentBlock,
            parentBlockHeader: parentBlockHeader,
            nexusHash: UInt256.zero,
            ancestorSpecs: ancestorSpecs,
            fetcher: fetcher
        )
        return result.newlyDiscovered
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
