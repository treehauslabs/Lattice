import Foundation
import Crypto
import cashew
import UInt256
import CollectionConcurrencyKit

public extension Block {
    private static let fieldSeparator: [UInt8] = [0x00]

    func getDifficultyHash() -> UInt256 {
        var data = Data()
        data.reserveCapacity(512)
        if let previousBlockCID = previousBlock?.rawCID {
            data.append(contentsOf: previousBlockCID.utf8)
        }
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: transactions.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: difficulty.toHexString().utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: nextDifficulty.toHexString().utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: spec.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: parentHomestead.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: homestead.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: frontier.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: childBlocks.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: String(index).utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: String(timestamp).utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: String(nonce).utf8)
        return UInt256.hash(data)
    }

    func validateGenesis(fetcher: Fetcher, directory: String?, parentSpec: ChainSpec? = nil) async throws -> (Bool, StateDiff) {
        if previousBlock != nil { return (false, .empty) }
        if Int64(Date().timeIntervalSince1970 * 1000) < timestamp { return (false, .empty) }
        if index != 0 { return (false, .empty) }
        if homestead.rawCID != LatticeState.emptyHeader.rawCID { return (false, .empty) }
        guard let transactionBodies = try await resolveTransactionBodies(fetcher: fetcher, validator: { tx in
            try await tx.validateTransactionForGenesis(fetcher: fetcher)
        }) else { return (false, .empty) }
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return (false, .empty) }
        if specNode.directory != directory { return (false, .empty) }
        if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: specNode) { return (false, .empty) }
        if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: specNode) { return (false, .empty) }
        if let parentSpec = parentSpec {
            if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: parentSpec) { return (false, .empty) }
            if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: parentSpec) { return (false, .empty) }
        }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty) }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty) }
        if !validateBlockSize(spec: specNode) { return (false, .empty) }
        let allAccountActions = transactionBodies.flatMap { $0.accountActions }
        let allDepositActions = transactionBodies.flatMap { $0.depositActions }
        let (totalFees, feesOverflow) = Block.getTotalFees(transactionBodies)
        if feesOverflow { return (false, .empty) }
        if try !validateBalanceChangesForGenesis(spec: specNode, allDepositActions: allDepositActions, allAccountActions: allAccountActions, totalFees: totalFees) { return (false, .empty) }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return (false, .empty) }
        let (frontierValid, diff) = try await validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: transactionBodies.flatMap { $0.actions }, allDepositActions: allDepositActions, allGenesisActions: transactionBodies.flatMap { $0.genesisActions }, allReceiptActions: transactionBodies.flatMap { $0.receiptActions }, allWithdrawalActions: [], fetcher: fetcher)
        if !frontierValid { return (false, .empty) }
        return (true, diff)
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

    func validateNexus(fetcher: Fetcher, chain: ChainState? = nil) async throws -> (Bool, StateDiff) {
        let tTotal = ContinuousClock.now
        let tPrev = ContinuousClock.now
        guard let previousBlockNode = try await previousBlock?.resolve(fetcher: fetcher).node else { return (false, .empty) }
        if !validateSpec(previousBlock: previousBlockNode) { return (false, .empty) }
        if !validateState(previousBlock: previousBlockNode) { return (false, .empty) }
        if !validateIndex(previousBlock: previousBlockNode) { return (false, .empty) }
        let dPrev = ContinuousClock.now - tPrev

        let tSpec = ContinuousClock.now
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return (false, .empty) }
        let dSpec = ContinuousClock.now - tSpec

        let tAncestors = ContinuousClock.now
        let mtpDepth: UInt64 = 11
        let walkDepth: UInt64 = specNode.isEpochBoundary(blockIndex: index)
            ? max(specNode.difficultyAdjustmentWindow, mtpDepth)
            : mtpDepth
        let ancestorTimestamps: [Int64]
        var fastPath = false
        if let chain,
           let parentHash = previousBlock?.rawCID,
           let fast = await chain.getMainChainTimestamps(forParentHash: parentHash, count: walkDepth) {
            ancestorTimestamps = fast
            fastPath = true
        } else {
            ancestorTimestamps = await collectAncestorTimestamps(previousBlock: previousBlockNode, count: walkDepth, fetcher: fetcher)
        }
        if !validateTimestamp(previousBlock: previousBlockNode, ancestorTimestamps: ancestorTimestamps) { return (false, .empty) }
        if !validateNextDifficulty(spec: specNode, previousBlock: previousBlockNode, ancestorTimestamps: ancestorTimestamps) { return (false, .empty) }
        let dAncestors = ContinuousClock.now - tAncestors

        let tTx = ContinuousClock.now
        guard let transactionBodies = try await resolveTransactionBodies(fetcher: fetcher, validator: { tx in
            try await tx.validateTransactionForNexus(fetcher: fetcher)
        }) else { return (false, .empty) }
        let dTx = ContinuousClock.now - tTx

        let tFilters = ContinuousClock.now
        if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: specNode) { return (false, .empty) }
        if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: specNode) { return (false, .empty) }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty) }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty) }
        if !validateBlockSize(spec: specNode) { return (false, .empty) }
        if !validateChainPaths(transactionBodies: transactionBodies, expectedPath: [specNode.directory]) { return (false, .empty) }
        let dFilters = ContinuousClock.now - tFilters

        let tBalance = ContinuousClock.now
        let allAccountActions = transactionBodies.flatMap { $0.accountActions }
        let (totalFees, feesOverflow) = Block.getTotalFees(transactionBodies)
        if feesOverflow { return (false, .empty) }
        if try !validateBalanceChanges(spec: specNode, allDepositActions: [], allWithdrawalActions: [], allAccountActions: allAccountActions, totalFees: totalFees) { return (false, .empty) }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return (false, .empty) }
        let dBalance = ContinuousClock.now - tBalance

        let tFrontier = ContinuousClock.now
        let (frontierValid, diff) = try await validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: transactionBodies.flatMap { $0.actions }, allDepositActions: [], allGenesisActions: transactionBodies.flatMap { $0.genesisActions }, allReceiptActions: transactionBodies.flatMap { $0.receiptActions }, allWithdrawalActions: [], fetcher: fetcher)
        if !frontierValid { return (false, .empty) }
        let dFrontier = ContinuousClock.now - tFrontier

        let dTotal = ContinuousClock.now - tTotal
        print("[TIMING] validateNexus #\(index) txs=\(transactionBodies.count) total=\(dTotal) prev=\(dPrev) spec=\(dSpec) ancestors=\(dAncestors) ancestorsFast=\(fastPath) ancestorsDepth=\(walkDepth) txResolve=\(dTx) filters=\(dFilters) balance=\(dBalance) frontier=\(dFrontier)")
        return (true, diff)
    }

    func validateBlockDifficulty(nexusHash: UInt256) -> Bool {
        return difficulty >= nexusHash
    }

    func validate(nexusHash: UInt256, parentChainBlock: Block, chainPath: [String] = [], fetcher: Fetcher) async throws -> (Bool, StateDiff) {
        guard let previousBlockNode = try await previousBlock?.resolve(fetcher: fetcher).node else { return (false, .empty) }
        if !validateSpec(previousBlock: previousBlockNode) { return (false, .empty) }
        if !validateState(previousBlock: previousBlockNode) { return (false, .empty) }
        if !validateParentState(parent: parentChainBlock) { return (false, .empty) }
        if !validateIndex(previousBlock: previousBlockNode) { return (false, .empty) }
        if parentChainBlock.timestamp != timestamp { return (false, .empty) }
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return (false, .empty) }
        guard let parentSpecNode = try await parentChainBlock.spec.resolve(fetcher: fetcher).node else { return (false, .empty) }
        let walkDepth = max(specNode.difficultyAdjustmentWindow, 11)
        let ancestorTimestamps = await collectAncestorTimestamps(previousBlock: previousBlockNode, count: walkDepth, fetcher: fetcher)
        if !validateTimestamp(previousBlock: previousBlockNode, ancestorTimestamps: ancestorTimestamps) { return (false, .empty) }
        if !validateNextDifficulty(spec: specNode, previousBlock: previousBlockNode, ancestorTimestamps: ancestorTimestamps) { return (false, .empty) }
        guard let transactionsNode = try await transactions.resolveRecursive(fetcher: fetcher).node else { return (false, .empty) }
        let txHeaders = try transactionsNode.allKeysAndValues().values
        if txHeaders.contains(where: { $0.node == nil }) { throw ValidationErrors.transactionNotResolved }
        let txs = txHeaders.map { $0.node! }
        async let homesteadStateFuture = homestead.resolve(fetcher: fetcher)
        async let parentStateFuture = parentHomestead.resolve(fetcher: fetcher)
        let (homesteadState, parentStateResolved) = try await (homesteadStateFuture, parentStateFuture)
        guard let homesteadStateNode = homesteadState.node else { throw ValidationErrors.homesteadNotResolved }
        guard let parentHomesteadStateNode = parentStateResolved.node else { throw ValidationErrors.homesteadNotResolved }
        if try await txs.concurrentMap({ try await $0.validateTransaction(directory: specNode.directory, homestead: homesteadStateNode, parentState: parentHomesteadStateNode, fetcher: fetcher) }).contains(false) { return (false, .empty) }
        let transactionBodiesMaybe = txs.map { $0.body.node }
        if transactionBodiesMaybe.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        let transactionBodies = transactionBodiesMaybe.map { $0! }
        if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: specNode) { return (false, .empty) }
        if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: specNode) { return (false, .empty) }
        if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: parentSpecNode) { return (false, .empty) }
        if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: parentSpecNode) { return (false, .empty) }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty) }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty) }
        if !validateBlockSize(spec: specNode) { return (false, .empty) }
        if !validateChainPaths(transactionBodies: transactionBodies, expectedPath: chainPath) { return (false, .empty) }
        let allAccountActions = transactionBodies.flatMap { $0.accountActions }
        let allDepositActions = transactionBodies.flatMap { $0.depositActions }
        let allWithdrawalActions = transactionBodies.flatMap { $0.withdrawalActions }
        let allReceiptActions = transactionBodies.flatMap { $0.receiptActions }
        let (totalFees, feesOverflow) = Block.getTotalFees(transactionBodies)
        if feesOverflow { return (false, .empty) }
        if try !validateBalanceChanges(spec: specNode, allDepositActions: allDepositActions, allWithdrawalActions: allWithdrawalActions, allAccountActions: allAccountActions, totalFees: totalFees) { return (false, .empty) }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return (false, .empty) }
        let (frontierValid, diff) = try await validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: transactionBodies.flatMap { $0.actions }, allDepositActions: allDepositActions, allGenesisActions: transactionBodies.flatMap { $0.genesisActions }, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, fetcher: fetcher)
        if !frontierValid { return (false, .empty) }
        return (true, diff)
    }

    func validateFrontierState(transactionBodies: [TransactionBody], fetcher: Fetcher) async throws -> (Bool, StateDiff) {
        return try await validateFrontierState(transactionBodies: transactionBodies, allAccountActions: transactionBodies.flatMap { $0.accountActions }, allActions: transactionBodies.flatMap { $0.actions }, allDepositActions: transactionBodies.flatMap { $0.depositActions }, allGenesisActions: transactionBodies.flatMap { $0.genesisActions }, allReceiptActions: transactionBodies.flatMap { $0.receiptActions }, allWithdrawalActions: transactionBodies.flatMap { $0.withdrawalActions }, fetcher: fetcher)
    }

    func validateFrontierState(transactionBodies: [TransactionBody], allAccountActions: [AccountAction], allActions: [Action], allDepositActions: [DepositAction], allGenesisActions: [GenesisAction], allReceiptActions: [ReceiptAction], allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> (Bool, StateDiff) {
        let resolvedHomestead = try await homestead.resolve(fetcher: fetcher)
        async let resolvedFrontier = frontier.resolve(fetcher: fetcher)
        guard let homesteadNode = resolvedHomestead.node else { throw ValidationErrors.homesteadNotResolved }
        async let updatedResult = homesteadNode.proveAndUpdateState(allAccountActions: allAccountActions, allActions: allActions, allDepositActions: allDepositActions, allGenesisActions: allGenesisActions, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, transactionBodies: transactionBodies, fetcher: fetcher)
        let (finalFrontier, (finalUpdatedHomestead, diff)) = await (try resolvedFrontier, try updatedResult)
        guard let frontierNode = finalFrontier.node else { throw ValidationErrors.homesteadNotResolved }
        let valid = frontierNode.accountState.rawCID == finalUpdatedHomestead.accountState.rawCID && frontierNode.generalState.rawCID == finalUpdatedHomestead.generalState.rawCID && frontierNode.depositState.rawCID == finalUpdatedHomestead.depositState.rawCID && frontierNode.genesisState.rawCID == finalUpdatedHomestead.genesisState.rawCID && frontierNode.receiptState.rawCID == finalUpdatedHomestead.receiptState.rawCID
        return (valid, diff)
    }

    func validateBalanceChanges(spec: ChainSpec, allDepositActions: [DepositAction], allWithdrawalActions: [WithdrawalAction], allAccountActions: [AccountAction], totalFees: UInt64) throws -> Bool {
        let reward = spec.rewardAtBlock(index)
        let (totalDeposited, depOverflow) = Block.getTotalDeposited(allDepositActions)
        if depOverflow { return false }
        let (totalWithdrawn, wdOverflow) = Block.getTotalWithdrawn(allWithdrawalActions)
        if wdOverflow { return false }
        // totalCredits <= totalDebits + totalWithdrawn + reward + fees - totalDeposited
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
        let (withReward, r1) = totalDebits.addingReportingOverflow(reward)
        let (withFees, r2) = withReward.addingReportingOverflow(totalFees)
        let (withWithdrawn, r3) = withFees.addingReportingOverflow(totalWithdrawn)
        if r1 || r2 || r3 { return false }
        guard withWithdrawn >= totalDeposited else { return false }
        let available = withWithdrawn - totalDeposited
        return totalCredits <= available
    }

    func validateBalanceChangesForGenesis(spec: ChainSpec, allDepositActions: [DepositAction], allAccountActions: [AccountAction], totalFees: UInt64) throws -> Bool {
        let premineAmount = spec.premineAmount()
        let (totalDeposited, depOverflow) = Block.getTotalDeposited(allDepositActions)
        if depOverflow { return false }
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
        guard incomeWithFees >= totalDeposited else { return false }
        let available = incomeWithFees - totalDeposited
        return totalCredits <= available
    }

    func validateSpec(previousBlock: Block) -> Bool {
        return previousBlock.spec.rawCID == spec.rawCID
    }

    func validateParentState(parent: Block) -> Bool {
        return parent.homestead.rawCID == parentHomestead.rawCID
    }

    func validateNextDifficulty(spec: ChainSpec, previousBlock: Block, ancestorTimestamps: [Int64] = []) -> Bool {
        // Epoch-based: only adjust at window boundaries
        if !spec.isEpochBoundary(blockIndex: index) {
            return nextDifficulty == difficulty
        }
        // Accept the minimum difficulty floor for chains recovering from a
        // zero-difficulty bug (UInt256 division by 1 returned 0).
        if difficulty == ChainSpec.minimumDifficulty && previousBlock.nextDifficulty < ChainSpec.minimumDifficulty {
            return nextDifficulty == difficulty
        }
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

    /// Bitcoin-style consensus rules:
    ///   (1) timestamp strictly greater than previous block
    ///   (2) timestamp ≤ now + 2h (bounded future drift — prevents warp
    ///       attacks that forward-shift timestamps to halve difficulty)
    ///   (3) timestamp > MedianTimePast(11) (prevents grinding by predating)
    /// No lower-bound against wall-clock: old blocks must still validate for
    /// cold sync, so we only gate the future side against clock drift.
    func validateTimestamp(previousBlock: Block, ancestorTimestamps: [Int64] = []) -> Bool {
        if previousBlock.timestamp >= timestamp { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let maxFutureDrift: Int64 = 2 * 60 * 60 * 1000
        if timestamp > now + maxFutureDrift { return false }
        if !ancestorTimestamps.isEmpty {
            let sorted = ancestorTimestamps.sorted()
            let medianIndex = (sorted.count - 1) / 2
            let median = sorted[medianIndex]
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

    func validateChainPaths(transactionBodies: [TransactionBody], expectedPath: [String]) -> Bool {
        for body in transactionBodies {
            if !body.chainPath.isEmpty && body.chainPath != expectedPath {
                return false
            }
        }
        return true
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
