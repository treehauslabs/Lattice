import Foundation
import Crypto
import cashew
import UInt256
import CollectionConcurrencyKit

public extension Block {
    func getDifficultyHash() -> UInt256 {
        var data = Data()
        data.reserveCapacity(512)
        if let previousBlockCID = previousBlock?.rawCID {
            data.append(contentsOf: previousBlockCID.utf8)
        }
        data.append(contentsOf: transactions.rawCID.utf8)
        data.append(contentsOf: difficulty.toHexString().utf8)
        data.append(contentsOf: nextDifficulty.toHexString().utf8)
        data.append(contentsOf: spec.rawCID.utf8)
        data.append(contentsOf: parentHomestead.rawCID.utf8)
        data.append(contentsOf: homestead.rawCID.utf8)
        data.append(contentsOf: frontier.rawCID.utf8)
        data.append(contentsOf: childBlocks.rawCID.utf8)
        data.append(contentsOf: String(index).utf8)
        data.append(contentsOf: String(timestamp).utf8)
        data.append(contentsOf: String(nonce).utf8)
        return UInt256.hash(data)
    }

    func validateGenesis(fetcher: Fetcher, directory: String?, parentSpec: ChainSpec? = nil) async throws -> Bool {
        if previousBlock != nil { return false }
        if Int64(Date().timeIntervalSince1970 * 1000) < timestamp { return false }
        if index != 0 { return false }
        if homestead.rawCID != LatticeState.emptyHeader.rawCID { return false }
        guard let transactionBodies = try await resolveTransactionBodies(fetcher: fetcher, validator: { tx in
            try await tx.validateTransactionForGenesis(fetcher: fetcher)
        }) else { return false }
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return false }
        if specNode.directory != directory { return false }
        if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: specNode) { return false }
        if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: specNode) { return false }
        if let parentSpec = parentSpec {
            if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: parentSpec) { return false }
            if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: parentSpec) { return false }
        }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return false }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return false }
        if !validateBlockSize(spec: specNode) { return false }
        let allAccountActions = Block.getAllAccountActions(transactionBodies)
        let allSwapActions = Block.getAllSwapActions(transactionBodies)
        let genesisTotalFees = transactionBodies.reduce(0 as UInt64) { $0 + $1.fee }
        if try !validateBalanceChangesForGenesis(spec: specNode, allSwapActions: allSwapActions, allAccountActions: allAccountActions, totalFees: genesisTotalFees) { return false }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return false }
        if try await !validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: Block.getAllActions(transactionBodies), allSwapActions: [], allSwapClaimActions: [], allGenesisActions: Block.getAllGenesisActions(transactionBodies), allPeerActions: Block.getAllPeerActions(transactionBodies), allSettleActions: [], fetcher: fetcher) { return false }
        return true
    }

    func collectAncestorTimestamps(previousBlock: Block, count: UInt64, fetcher: Fetcher) async -> [Int64] {
        var timestamps: [Int64] = [previousBlock.timestamp]
        var current = previousBlock
        for _ in 1..<count {
            guard let prev = try? await current.previousBlock?.resolve(fetcher: fetcher).node else { break }
            timestamps.append(prev.timestamp)
            current = prev
        }
        return timestamps
    }

    func validateNexus(fetcher: Fetcher) async throws -> Bool {
        guard let previousBlockNode = try await previousBlock?.resolve(fetcher: fetcher).node else { return false }
        if !validateSpec(previousBlock: previousBlockNode) { return false }
        if !validateState(previousBlock: previousBlockNode) { return false }
        if !validateIndex(previousBlock: previousBlockNode) { return false }
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return false }
        let walkDepth = min(max(specNode.difficultyAdjustmentWindow, 11), 32)
        let ancestorTimestamps = await collectAncestorTimestamps(previousBlock: previousBlockNode, count: walkDepth, fetcher: fetcher)
        if !validateTimestamp(previousBlock: previousBlockNode, ancestorTimestamps: ancestorTimestamps) { return false }
        if !validateNextDifficulty(spec: specNode, previousBlock: previousBlockNode, ancestorTimestamps: ancestorTimestamps) { return false }
        let resolvedHomestead = try await homestead.resolve(fetcher: fetcher)
        guard let homesteadNode = resolvedHomestead.node else { throw ValidationErrors.homesteadNotResolved }
        guard let transactionBodies = try await resolveTransactionBodies(fetcher: fetcher, validator: { tx in
            try await tx.validateTransactionForNexus(directory: specNode.directory, homestead: homesteadNode, blockIndex: self.index, fetcher: fetcher)
        }) else { return false }
        if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: specNode) { return false }
        if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: specNode) { return false }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return false }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return false }
        if !validateBlockSize(spec: specNode) { return false }
        let allAccountActions = Block.getAllAccountActions(transactionBodies)
        let allSwapActions = Block.getAllSwapActions(transactionBodies)
        let allSwapClaimActions = Block.getAllSwapClaimActions(transactionBodies)
        let nexusTotalFees = transactionBodies.reduce(0 as UInt64) { $0 + $1.fee }
        if try !validateBalanceChanges(spec: specNode, allSwapActions: allSwapActions, allSwapClaimActions: allSwapClaimActions, allAccountActions: allAccountActions, totalFees: nexusTotalFees) { return false }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return false }
        if try await !validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: Block.getAllActions(transactionBodies), allSwapActions: allSwapActions, allSwapClaimActions: allSwapClaimActions, allGenesisActions: Block.getAllGenesisActions(transactionBodies), allPeerActions: Block.getAllPeerActions(transactionBodies), allSettleActions: Block.getAllSettleActions(transactionBodies), fetcher: fetcher) { return false }
        return true
    }

    func validateBlockDifficulty(nexusHash: UInt256) -> Bool {
        return difficulty >= nexusHash
    }

    func validate(nexusHash: UInt256, parentChainBlock: Block, fetcher: Fetcher) async throws -> Bool {
        guard let previousBlockNode = try await previousBlock?.resolve(fetcher: fetcher).node else { return false }
        if !validateSpec(previousBlock: previousBlockNode) { return false }
        if !validateState(previousBlock: previousBlockNode) { return false }
        if !validateParentState(parent: parentChainBlock) { return false }
        if !validateIndex(previousBlock: previousBlockNode) { return false }
        if parentChainBlock.timestamp != timestamp { return false }
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return false }
        guard let parentSpecNode = try await parentChainBlock.spec.resolve(fetcher: fetcher).node else { return false }
        let walkDepth = min(max(specNode.difficultyAdjustmentWindow, 11), 32)
        let ancestorTimestamps = await collectAncestorTimestamps(previousBlock: previousBlockNode, count: walkDepth, fetcher: fetcher)
        if !validateTimestamp(previousBlock: previousBlockNode, ancestorTimestamps: ancestorTimestamps) { return false }
        if !validateNextDifficulty(spec: specNode, previousBlock: previousBlockNode, ancestorTimestamps: ancestorTimestamps) { return false }
        guard let transactionsNode = try await transactions.resolveRecursive(fetcher: fetcher).node else { return false }
        let txHeaders = try transactionsNode.allKeysAndValues().values
        if txHeaders.contains(where: { $0.node == nil }) { throw ValidationErrors.transactionNotResolved }
        let txs = txHeaders.map { $0.node! }
        async let homesteadStateFuture = homestead.resolve(fetcher: fetcher)
        async let parentStateFuture = parentHomestead.resolve(fetcher: fetcher)
        let (homesteadState, parentStateResolved) = try await (homesteadStateFuture, parentStateFuture)
        guard let homesteadStateNode = homesteadState.node else { throw ValidationErrors.homesteadNotResolved }
        guard let parentHomesteadStateNode = parentStateResolved.node else { throw ValidationErrors.homesteadNotResolved }
        if try await txs.concurrentMap({ try await $0.validateTransaction(directory: specNode.directory, homestead: homesteadStateNode, parentState: parentHomesteadStateNode, blockIndex: self.index, fetcher: fetcher) }).contains(false) { return false }
        let transactionBodiesMaybe = txs.map { $0.body.node }
        if transactionBodiesMaybe.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        let transactionBodies = transactionBodiesMaybe.map { $0! }
        if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: specNode) { return false }
        if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: specNode) { return false }
        if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: parentSpecNode) { return false }
        if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: parentSpecNode) { return false }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return false }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return false }
        if !validateBlockSize(spec: specNode) { return false }
        let allAccountActions = Block.getAllAccountActions(transactionBodies)
        let allSwapActions = Block.getAllSwapActions(transactionBodies)
        let allSwapClaimActions = Block.getAllSwapClaimActions(transactionBodies)
        let childTotalFees = transactionBodies.reduce(0 as UInt64) { $0 + $1.fee }
        if try !validateBalanceChanges(spec: specNode, allSwapActions: allSwapActions, allSwapClaimActions: allSwapClaimActions, allAccountActions: allAccountActions, totalFees: childTotalFees) { return false }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return false }
        if try await !validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: Block.getAllActions(transactionBodies), allSwapActions: allSwapActions, allSwapClaimActions: allSwapClaimActions, allGenesisActions: Block.getAllGenesisActions(transactionBodies), allPeerActions: Block.getAllPeerActions(transactionBodies), allSettleActions: Block.getAllSettleActions(transactionBodies), fetcher: fetcher) { return false }
        return true
    }

    func validateFrontierState(transactionBodies: [TransactionBody], fetcher: Fetcher) async throws -> Bool {
        return try await validateFrontierState(transactionBodies: transactionBodies, allAccountActions: Block.getAllAccountActions(transactionBodies), allActions: Block.getAllActions(transactionBodies), allSwapActions: Block.getAllSwapActions(transactionBodies), allSwapClaimActions: Block.getAllSwapClaimActions(transactionBodies), allGenesisActions: Block.getAllGenesisActions(transactionBodies), allPeerActions: Block.getAllPeerActions(transactionBodies), allSettleActions: Block.getAllSettleActions(transactionBodies), fetcher: fetcher)
    }

    func validateFrontierState(transactionBodies: [TransactionBody], allAccountActions: [AccountAction], allActions: [Action], allSwapActions: [SwapAction], allSwapClaimActions: [SwapClaimAction], allGenesisActions: [GenesisAction], allPeerActions: [PeerAction], allSettleActions: [SettleAction], fetcher: Fetcher) async throws -> Bool {
        let resolvedHomestead = try await homestead.resolve(fetcher: fetcher)
        async let resolvedFrontier = frontier.resolve(fetcher: fetcher)
        guard let homesteadNode = resolvedHomestead.node else { throw ValidationErrors.homesteadNotResolved }
        async let updatedHomestead = homesteadNode.proveAndUpdateState(allAccountActions: allAccountActions, allActions: allActions, allSwapActions: allSwapActions, allSwapClaimActions: allSwapClaimActions, allGenesisActions: allGenesisActions, allPeerActions: allPeerActions, allSettleActions: allSettleActions, transactionBodies: transactionBodies, fetcher: fetcher)
        let (finalFrontier, finalUpdatedHomestead) = await (try resolvedFrontier, try updatedHomestead)
        guard let frontierNode = finalFrontier.node else { throw ValidationErrors.homesteadNotResolved }
        return frontierNode.accountState.rawCID == finalUpdatedHomestead.accountState.rawCID && frontierNode.generalState.rawCID == finalUpdatedHomestead.generalState.rawCID && frontierNode.swapState.rawCID == finalUpdatedHomestead.swapState.rawCID && frontierNode.genesisState.rawCID == finalUpdatedHomestead.genesisState.rawCID && frontierNode.peerState.rawCID == finalUpdatedHomestead.peerState.rawCID && frontierNode.settleState.rawCID == finalUpdatedHomestead.settleState.rawCID && frontierNode.transactionState.rawCID == finalUpdatedHomestead.transactionState.rawCID
    }

    func validateBalanceChanges(spec: ChainSpec, allSwapActions: [SwapAction], allSwapClaimActions: [SwapClaimAction], allAccountActions: [AccountAction], totalFees: UInt64) throws -> Bool {
        let reward = spec.rewardAtBlock(index)
        let (totalSwapLocked, lockedOverflow) = Block.getTotalSwapLocked(allSwapActions)
        let (totalSwapClaimed, claimedOverflow) = Block.getTotalSwapClaimed(allSwapClaimActions)
        if lockedOverflow || claimedOverflow { return false }
        // With deltas: sum(credits) must not exceed sum(debits) + reward + fees + swapClaimed - swapLocked
        // Equivalently: net delta (sum of all deltas) must equal reward + fees + swapClaimed - swapLocked
        var totalCredits: UInt64 = 0
        var totalDebits: UInt64 = 0
        for action in allAccountActions {
            if action.delta == Int64.min { return false }
            if action.delta > 0 {
                let (newCredits, overflow) = totalCredits.addingReportingOverflow(UInt64(action.delta))
                if overflow { return false }
                totalCredits = newCredits
            } else if action.delta < 0 {
                let (newDebits, overflow) = totalDebits.addingReportingOverflow(UInt64(-action.delta))
                if overflow { return false }
                totalDebits = newDebits
            }
        }
        // Available new funds: debits + reward + fees + swapClaimed - swapLocked
        let (withReward, r1) = totalDebits.addingReportingOverflow(reward)
        let (withFees, r2) = withReward.addingReportingOverflow(totalFees)
        let (withClaimed, r3) = withFees.addingReportingOverflow(totalSwapClaimed)
        if r1 || r2 || r3 { return false }
        guard withClaimed >= totalSwapLocked else { return false }
        let available = withClaimed - totalSwapLocked
        return totalCredits <= available
    }

    func validateBalanceChangesForGenesis(spec: ChainSpec, allSwapActions: [SwapAction], allAccountActions: [AccountAction], totalFees: UInt64) throws -> Bool {
        let premineAmount = spec.premineAmount()
        let (totalSwapLocked, lockedOverflow) = Block.getTotalSwapLocked(allSwapActions)
        if lockedOverflow { return false }
        var totalCredits: UInt64 = 0
        for action in allAccountActions {
            if action.delta > 0 {
                let (newCredits, overflow) = totalCredits.addingReportingOverflow(UInt64(action.delta))
                if overflow { return false }
                totalCredits = newCredits
            }
        }
        let (incomeWithFees, overflow) = premineAmount.addingReportingOverflow(totalFees)
        if overflow { return false }
        guard incomeWithFees >= totalSwapLocked else { return false }
        let available = incomeWithFees - totalSwapLocked
        return totalCredits <= available
    }

    func validateSpec(previousBlock: Block) -> Bool {
        return previousBlock.spec.rawCID == spec.rawCID
    }

    func validateParentState(parent: Block) -> Bool {
        return parent.homestead.rawCID == parentHomestead.rawCID
    }

    func validateNextDifficulty(spec: ChainSpec, previousBlock: Block, ancestorTimestamps: [Int64] = []) -> Bool {
        let expected: UInt256
        if ancestorTimestamps.count >= 2 {
            let windowTimestamps = [timestamp] + Array(ancestorTimestamps.prefix(Int(spec.difficultyAdjustmentWindow)))
            expected = spec.calculateWindowedDifficulty(previousDifficulty: difficulty, ancestorTimestamps: windowTimestamps)
        } else {
            expected = spec.calculateMinimumDifficulty(previousDifficulty: difficulty, blockTimestamp: timestamp, previousTimestamp: previousBlock.timestamp)
        }
        let maxDifficultyChange = UInt256(ChainSpec.maxDifficultyChange)
        let lowerBound = expected / maxDifficultyChange
        let upperBound = expected <= UInt256.max / maxDifficultyChange ? expected * maxDifficultyChange : UInt256.max
        return nextDifficulty >= lowerBound && nextDifficulty <= upperBound
    }

    func validateState(previousBlock: Block) -> Bool {
        return previousBlock.frontier.rawCID == homestead.rawCID
    }

    func validateIndex(previousBlock: Block) -> Bool {
        return previousBlock.index + 1 == index
    }

    func validateTimestamp(previousBlock: Block, ancestorTimestamps: [Int64] = []) -> Bool {
        if previousBlock.timestamp >= timestamp { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if timestamp > now { return false }
        let maxDrift: Int64 = 2 * 60 * 60 * 1000
        if now - timestamp > maxDrift { return false }
        // Median-time-past: new blocks must have timestamp > median of recent ancestors
        if ancestorTimestamps.count >= 3 {
            let sorted = ancestorTimestamps.sorted()
            let median = sorted[sorted.count / 2]
            if timestamp <= median { return false }
        }
        return true
    }

    func validateStateDeltaSize(spec: ChainSpec, transactionBodies: [TransactionBody]) throws -> Bool {
        return try transactionBodies.reduce(0) { try $0 + $1.getStateDelta() } <= spec.maxStateGrowth
    }

    func validateMaxTransactionCount(spec: ChainSpec, transactionBodies: [TransactionBody]) -> Bool {
        return transactionBodies.count <= spec.maxNumberOfTransactionsPerBlock
    }

    func validateBlockSize(spec: ChainSpec) -> Bool {
        guard let blockData = toData() else { return false }
        return blockData.count <= spec.maxBlockSize
    }

    func resolveTransactionBodies(fetcher: Fetcher, validator: @escaping @Sendable (Transaction) async throws -> Bool) async throws -> [TransactionBody]? {
        guard let transactionsNode = try await transactions.resolveRecursive(fetcher: fetcher).node else { return nil }
        let txHeaders = try transactionsNode.allKeysAndValues().values
        if txHeaders.contains(where: { $0.node == nil }) { throw ValidationErrors.transactionNotResolved }
        let txs = txHeaders.map { $0.node! }
        if try await txs.concurrentMap({ try await validator($0) }).contains(false) { return nil }
        let transactionBodiesMaybe = txs.map { $0.body.node }
        if transactionBodiesMaybe.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        return transactionBodiesMaybe.map { $0! }
    }

    func validateGenesisTransactions(fetcher: Fetcher, transactionBodies: [TransactionBody], parentSpec: ChainSpec? = nil) async throws -> Bool {
        return try await !transactionBodies.concurrentMap { transactionBody in
            try await transactionBody.genesisActionsAreValid(fetcher: fetcher, parentSpec: parentSpec)
        }.contains(false)
    }
}
