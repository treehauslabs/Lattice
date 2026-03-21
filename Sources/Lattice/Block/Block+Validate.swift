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
        let allDepositActions = Block.getAllDepositActions(transactionBodies)
        let genesisTotalFees = transactionBodies.reduce(0 as UInt64) { $0 + $1.fee }
        if try !validateBalanceChangesForGenesis(spec: specNode, allDepositActions: allDepositActions, allAccountActions: allAccountActions, totalFees: genesisTotalFees) { return false }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return false }
        if try await !validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: Block.getAllActions(transactionBodies), allDepositActions: allDepositActions, allGenesisActions: Block.getAllGenesisActions(transactionBodies), allPeerActions: Block.getAllPeerActions(transactionBodies), allReceiptActions: Block.getAllReceiptActions(transactionBodies), allWithdrawalActions: [], fetcher: fetcher) { return false }
        return true
    }
    
    func validateNexus(fetcher: Fetcher) async throws -> Bool {
        guard let previousBlockNode = try await previousBlock?.resolve(fetcher: fetcher).node else { return false }
        if !validateSpec(previousBlock: previousBlockNode) { return false }
        if !validateState(previousBlock: previousBlockNode) { return false }
        if !validateIndex(previousBlock: previousBlockNode) { return false }
        if !validateTimestamp(previousBlock: previousBlockNode) { return false }
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return false }
        if !validateNextDifficulty(spec: specNode, previousBlock: previousBlockNode) { return false }
        guard let transactionBodies = try await resolveTransactionBodies(fetcher: fetcher, validator: { tx in
            try await tx.validateTransactionForNexus(fetcher: fetcher)
        }) else { return false }
        if !TransactionBody.batchVerifyFilters(bodies: transactionBodies, spec: specNode) { return false }
        if !TransactionBody.batchVerifyActionFilters(bodies: transactionBodies, spec: specNode) { return false }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return false }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return false }
        if !validateBlockSize(spec: specNode) { return false }
        let allAccountActions = Block.getAllAccountActions(transactionBodies)
        let nexusTotalFees = transactionBodies.reduce(0 as UInt64) { $0 + $1.fee }
        if try !validateBalanceChanges(spec: specNode, allDepositActions: [], allWithdrawalActions: [], allAccountActions: allAccountActions, totalFees: nexusTotalFees) { return false }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return false }
        if try await !validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: Block.getAllActions(transactionBodies), allDepositActions: [], allGenesisActions: Block.getAllGenesisActions(transactionBodies), allPeerActions: Block.getAllPeerActions(transactionBodies), allReceiptActions: Block.getAllReceiptActions(transactionBodies), allWithdrawalActions: [], fetcher: fetcher) { return false }
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
        if !validateTimestamp(previousBlock: previousBlockNode) { return false }
        if parentChainBlock.timestamp != timestamp { return false }
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return false }
        guard let parentSpecNode = try await parentChainBlock.spec.resolve(fetcher: fetcher).node else { return false }
        if !validateNextDifficulty(spec: specNode, previousBlock: previousBlockNode) { return false }
        guard let transactionsNode = try await transactions.resolveRecursive(fetcher: fetcher).node else { return false }
        let txHeaders = try transactionsNode.allKeysAndValues().values
        if txHeaders.contains(where: { $0.node == nil }) { throw ValidationErrors.transactionNotResolved }
        let txs = txHeaders.map { $0.node! }
        async let homesteadStateFuture = homestead.resolve(fetcher: fetcher)
        async let parentChainHomesteadStateFuture = parentChainBlock.parentHomestead.resolve(fetcher: fetcher)
        let (homesteadState, parentChainHomesteadState) = try await (homesteadStateFuture, parentChainHomesteadStateFuture)
        guard let homesteadStateNode = homesteadState.node else { throw ValidationErrors.homesteadNotResolved }
        guard let parentHomesteadStateNode = parentChainHomesteadState.node else { throw ValidationErrors.homesteadNotResolved }
        if try await txs.concurrentMap({ try await $0.validateTransaction(directory: specNode.directory, homestead: homesteadStateNode, parentState: parentHomesteadStateNode, fetcher: fetcher) }).contains(false) { return false }
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
        let allDepositActions = Block.getAllDepositActions(transactionBodies)
        let allWithdrawalActions = Block.getAllWithdrawalActions(transactionBodies)
        let childTotalFees = transactionBodies.reduce(0 as UInt64) { $0 + $1.fee }
        if try !validateBalanceChanges(spec: specNode, allDepositActions: allDepositActions, allWithdrawalActions: allWithdrawalActions, allAccountActions: allAccountActions, totalFees: childTotalFees) { return false }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return false }
        if try await !validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: Block.getAllActions(transactionBodies), allDepositActions: allDepositActions, allGenesisActions: Block.getAllGenesisActions(transactionBodies), allPeerActions: Block.getAllPeerActions(transactionBodies), allReceiptActions: Block.getAllReceiptActions(transactionBodies), allWithdrawalActions: allWithdrawalActions, fetcher: fetcher) { return false }
        return true
    }
    
    func validateFrontierState(transactionBodies: [TransactionBody], fetcher: Fetcher) async throws -> Bool {
        return try await validateFrontierState(transactionBodies: transactionBodies, allAccountActions: Block.getAllAccountActions(transactionBodies), allActions: Block.getAllActions(transactionBodies), allDepositActions: Block.getAllDepositActions(transactionBodies), allGenesisActions: Block.getAllGenesisActions(transactionBodies), allPeerActions: Block.getAllPeerActions(transactionBodies), allReceiptActions: Block.getAllReceiptActions(transactionBodies), allWithdrawalActions: Block.getAllWithdrawalActions(transactionBodies), fetcher: fetcher)
    }
    
    // transactions should be fully resolved
    func validateFrontierState(transactionBodies: [TransactionBody], allAccountActions: [AccountAction], allActions: [Action], allDepositActions: [DepositAction], allGenesisActions: [GenesisAction], allPeerActions: [PeerAction], allReceiptActions: [ReceiptAction], allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> Bool {
        let resolvedHomestead = try await homestead.resolve(fetcher: fetcher)
        async let resolvedFrontier = frontier.resolve(fetcher: fetcher)
        guard let homesteadNode = resolvedHomestead.node else { throw ValidationErrors.homesteadNotResolved }
        async let updatedHomestead = homesteadNode.proveAndUpdateState(allAccountActions: allAccountActions, allActions: allActions, allDepositActions: allDepositActions, allGenesisActions: allGenesisActions, allPeerActions: allPeerActions, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, transactionBodies: transactionBodies, fetcher: fetcher)
        let (finalFrontier, finalUpdatedHomestead) = await (try resolvedFrontier, try updatedHomestead)
        guard let frontierNode = finalFrontier.node else { throw ValidationErrors.homesteadNotResolved }
        return frontierNode.accountState.rawCID == finalUpdatedHomestead.accountState.rawCID && frontierNode.generalState.rawCID == finalUpdatedHomestead.generalState.rawCID && frontierNode.depositState.rawCID == finalUpdatedHomestead.depositState.rawCID && frontierNode.genesisState.rawCID == finalUpdatedHomestead.genesisState.rawCID && frontierNode.peerState.rawCID == finalUpdatedHomestead.peerState.rawCID && frontierNode.receiptState.rawCID == finalUpdatedHomestead.receiptState.rawCID && frontierNode.withdrawalState.rawCID == finalUpdatedHomestead.withdrawalState.rawCID && frontierNode.transactionState.rawCID == finalUpdatedHomestead.transactionState.rawCID
    }
    
    func validateBalanceChanges(spec: ChainSpec, allDepositActions: [DepositAction], allWithdrawalActions: [WithdrawalAction], allAccountActions: [AccountAction], totalFees: UInt64) throws -> Bool {
        let reward = spec.rewardAtBlock(index)
        let totalDeposited = Block.getTotalDeposited(allDepositActions)
        let totalWithdrawn = Block.getTotalWithdrawn(allWithdrawalActions)
        var totalBalanceBefore: UInt64 = 0
        var totalBalanceAfter: UInt64 = 0
        for action in allAccountActions {
            let (newBefore, beforeOverflow) = totalBalanceBefore.addingReportingOverflow(action.oldBalance)
            let (newAfter, afterOverflow) = totalBalanceAfter.addingReportingOverflow(action.newBalance)
            if beforeOverflow || afterOverflow { return false }
            totalBalanceBefore = newBefore
            totalBalanceAfter = newAfter
        }
        let (income, incomeOverflow) = totalBalanceBefore.addingReportingOverflow(totalWithdrawn)
        let (incomeWithReward, rewardOverflow) = income.addingReportingOverflow(reward)
        let (incomeWithFees, feeOverflow) = incomeWithReward.addingReportingOverflow(totalFees)
        if incomeOverflow || rewardOverflow || feeOverflow { return false }
        guard incomeWithFees >= totalDeposited else { return false }
        let available = incomeWithFees - totalDeposited
        return totalBalanceAfter <= available
    }

    func validateBalanceChangesForGenesis(spec: ChainSpec, allDepositActions: [DepositAction], allAccountActions: [AccountAction], totalFees: UInt64) throws -> Bool {
        let premineAmount = spec.premineAmount()
        let totalDeposited = Block.getTotalDeposited(allDepositActions)
        var totalBalanceAfter: UInt64 = 0
        for action in allAccountActions {
            let (newAfter, overflow) = totalBalanceAfter.addingReportingOverflow(action.newBalance)
            if overflow { return false }
            totalBalanceAfter = newAfter
        }
        let (incomeWithFees, overflow) = premineAmount.addingReportingOverflow(totalFees)
        if overflow { return false }
        guard incomeWithFees >= totalDeposited else { return false }
        let available = incomeWithFees - totalDeposited
        return totalBalanceAfter <= available
    }
    
    func validateSpec(previousBlock: Block) -> Bool {
        return previousBlock.spec.rawCID == spec.rawCID
    }
    
    func validateParentState(parent: Block) -> Bool {
        return parent.homestead.rawCID == parentHomestead.rawCID
    }
    
    func validateNextDifficulty(spec: ChainSpec, previousBlock: Block) -> Bool {
        let expected = spec.calculateMinimumDifficulty(previousDifficulty: difficulty, blockTimestamp: timestamp, previousTimestamp: previousBlock.timestamp)
        let maxDifficultyChange = UInt256(ChainSpec.maxDifficultyChange)
        let lowerBound = expected / maxDifficultyChange
        let upperBound = expected * maxDifficultyChange
        return nextDifficulty >= lowerBound && nextDifficulty <= upperBound
    }
    
    func validateState(previousBlock: Block) -> Bool {
        return previousBlock.frontier.rawCID == homestead.rawCID
    }
    
    func validateIndex(previousBlock: Block) -> Bool {
        return previousBlock.index + 1 == index
    }
    
    func validateTimestamp(previousBlock: Block) -> Bool {
        if previousBlock.timestamp >= timestamp { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if timestamp > now { return false }
        let maxDrift: Int64 = 2 * 60 * 60 * 1000
        if now - timestamp > maxDrift { return false }
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
