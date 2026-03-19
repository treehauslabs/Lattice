import Foundation
import Crypto
import cashew
import UInt256
import ArrayTrie
import CollectionConcurrencyKit

public extension Block {
    func getDifficultyHash() -> UInt256 {
        if let previousBlockCID = previousBlock?.rawCID {
            let hashString = previousBlockCID + transactions.rawCID + difficulty.toHexString() + nextDifficulty.toHexString() + spec.rawCID + parentHomestead.rawCID + homestead.rawCID + frontier.rawCID + childBlocks.rawCID + String(index) + String(timestamp) + String(nonce)
            return UInt256.hash(hashString.toData() ?? Data())
        }
        let hashString = transactions.rawCID + difficulty.toHexString() + nextDifficulty.toHexString() + spec.rawCID + parentHomestead.rawCID + homestead.rawCID + frontier.rawCID + childBlocks.rawCID + String(index) + String(timestamp) + String(nonce)
        return UInt256.hash(hashString.toData() ?? Data())
    }
    
    func validateGenesis(fetcher: Fetcher, directory: String?, parentSpec: ChainSpec? = nil) async throws -> Bool {
        if previousBlock != nil { return false }
        if Int64(Date().timeIntervalSince1970 * 1000) < timestamp { return false }
        if index != 0 { return false }
        if homestead.rawCID != LatticeStateHeader(node: LatticeState.emptyState()).rawCID { return false }
        guard let transactionsNode = try await transactions.resolveRecursive(fetcher: fetcher).node else { return false }
        let txHeaders = try transactionsNode.allKeysAndValues().values
        if txHeaders.contains(where: { $0.node == nil }) { throw ValidationErrors.transactionNotResolved }
        let txs = txHeaders.map { $0.node! }
        if try await txs.concurrentMap({ try await $0.validateTransactionForGenesis(fetcher: fetcher) }).contains(false) { return false }
        let transactionBodiesMaybe = txs.map { $0.body.node }
        if transactionBodiesMaybe.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        let transactionBodies = transactionBodiesMaybe.map { $0! }
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return false }
        if specNode.directory != directory { return false }
        if !transactionBodies.allSatisfy({ $0.verifyFilters(spec: specNode) }) { return false }
        if !transactionBodies.allSatisfy({ $0.verifyActionFilters(spec: specNode) }) { return false }
        if let parentSpec = parentSpec {
            if !transactionBodies.allSatisfy({ $0.verifyFilters(spec: parentSpec) }) { return false }
            if !transactionBodies.allSatisfy({ $0.verifyActionFilters(spec: parentSpec) }) { return false }
        }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return false }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return false }
        if !validateBlockSize(spec: specNode) { return false }
        let allAccountActions = getAllAccountActions(transactionBodies: transactionBodies)
        let allDepositActions = getAllDepositActions(transactionBodies: transactionBodies)
        let genesisTotalFees = transactionBodies.map { $0.fee }.reduce(0, +)
        if try !validateBalanceChangesForGenesis(spec: specNode, allDepositActions: allDepositActions, allAccountActions: allAccountActions, totalFees: genesisTotalFees) { return false }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return false }
        if try await !validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: getAllActions(transactionBodies: transactionBodies), allDepositActions: allDepositActions, allGenesisActions: getAllGenesisActions(transactionBodies: transactionBodies), allPeerActions: getAllPeerActions(transactionBodies: transactionBodies), allReceiptActions: getAllReceiptActions(transactionBodies: transactionBodies), allWithdrawalActions: [], fetcher: fetcher) { return false }
        return true
    }
    
    func validateNexus(fetcher: Fetcher) async throws -> Bool {
        guard let previousBlockNode = try await previousBlock?.resolve(fetcher: fetcher).node else { return false }
        guard let blockHeaderData = toData() else { return false }
        if !validateSpec(previousBlock: previousBlockNode) { return false }
        if !validateState(previousBlock: previousBlockNode) { return false }
        if !validateIndex(previousBlock: previousBlockNode) { return false }
        if !validateTimestamp(previousBlock: previousBlockNode) { return false }
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return false }
        if !validateNextDifficulty(spec: specNode, previousBlock: previousBlockNode) { return false }
        guard let transactionsNode = try await transactions.resolveRecursive(fetcher: fetcher).node else { return false }
        let txHeaders = try transactionsNode.allKeysAndValues().values
        if txHeaders.contains(where: { $0.node == nil }) { throw ValidationErrors.transactionNotResolved }
        let txs = txHeaders.map { $0.node! }
        if try await txs.concurrentMap({ try await $0.validateTransactionForNexus(fetcher: fetcher) }).contains(false) { return false }
        let transactionBodiesMaybe = txs.map { $0.body.node }
        if transactionBodiesMaybe.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        let transactionBodies = transactionBodiesMaybe.map { $0! }
        if !transactionBodies.allSatisfy({ $0.verifyFilters(spec: specNode) }) { return false }
        if !transactionBodies.allSatisfy({ $0.verifyActionFilters(spec: specNode) }) { return false }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return false }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return false }
        if !validateBlockSize(spec: specNode) { return false }
        let allAccountActions = getAllAccountActions(transactionBodies: transactionBodies)
        let nexusTotalFees = transactionBodies.map { $0.fee }.reduce(0, +)
        if try !validateBalanceChanges(spec: specNode, allDepositActions: [], allWithdrawalActions: [], allAccountActions: allAccountActions, totalFees: nexusTotalFees) { return false }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return false }
        if try await !validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: getAllActions(transactionBodies: transactionBodies), allDepositActions: [], allGenesisActions: getAllGenesisActions(transactionBodies: transactionBodies), allPeerActions: getAllPeerActions(transactionBodies: transactionBodies), allReceiptActions: getAllReceiptActions(transactionBodies: transactionBodies), allWithdrawalActions: [], fetcher: fetcher) { return false }
        return true
    }
    
    func validateBlockDifficulty(nexusHash: UInt256) -> Bool {
        return difficulty >= nexusHash
    }
    
    func validate(nexusHash: UInt256, parentChainBlock: Block, fetcher: Fetcher) async throws -> Bool {
        guard let previousBlockNode = try await previousBlock?.resolve(fetcher: fetcher).node else { return false }
        guard let blockHeaderData = toData() else { return false }
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
        async let homestedStateFuture = homestead.resolve(fetcher: fetcher)
        async let parentChainHomesteadStateFuture = parentChainBlock.parentHomestead.resolve(fetcher: fetcher)
        let (homesteadState, parentChainHomesteadState) = try await (homestedStateFuture, parentChainHomesteadStateFuture)
        guard let homesteadStateNode = homesteadState.node else { throw ValidationErrors.homesteadNotResolved }
        guard let parentHomesteadStateNode = parentChainHomesteadState.node else { throw ValidationErrors.homesteadNotResolved }
        if try await txs.concurrentMap({ try await $0.validateTransaction(directory: specNode.directory, homestead: homesteadStateNode, parentState: parentHomesteadStateNode, fetcher: fetcher) }).contains(false) { return false }
        let transactionBodiesMaybe = txs.map { $0.body.node }
        if transactionBodiesMaybe.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        let transactionBodies = transactionBodiesMaybe.map { $0! }
        if !transactionBodies.allSatisfy({ $0.verifyFilters(spec: specNode) }) { return false }
        if !transactionBodies.allSatisfy({ $0.verifyActionFilters(spec: specNode) }) { return false }
        if !transactionBodies.allSatisfy({ $0.verifyFilters(spec: parentSpecNode) }) { return false }
        if !transactionBodies.allSatisfy({ $0.verifyActionFilters(spec: parentSpecNode) }) { return false }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return false }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return false }
        if !validateBlockSize(spec: specNode) { return false }
        let allAccountActions = getAllAccountActions(transactionBodies: transactionBodies)
        let allDepositActions = getAllDepositActions(transactionBodies: transactionBodies)
        let allWithdrawalActions = getAllWithdrawalActions(transactionBodies: transactionBodies)
        let childTotalFees = transactionBodies.map { $0.fee }.reduce(0, +)
        if try !validateBalanceChanges(spec: specNode, allDepositActions: allDepositActions, allWithdrawalActions: allWithdrawalActions, allAccountActions: allAccountActions, totalFees: childTotalFees) { return false }
        if try await !validateGenesisTransactions(fetcher: fetcher, transactionBodies: transactionBodies, parentSpec: specNode) { return false }
        if try await !validateFrontierState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: getAllActions(transactionBodies: transactionBodies), allDepositActions: allDepositActions, allGenesisActions: getAllGenesisActions(transactionBodies: transactionBodies), allPeerActions: getAllPeerActions(transactionBodies: transactionBodies), allReceiptActions: getAllReceiptActions(transactionBodies: transactionBodies), allWithdrawalActions: allWithdrawalActions, fetcher: fetcher) { return false }
        return true
    }
    
    func validateFrontierState(transactionBodies: [TransactionBody], fetcher: Fetcher) async throws -> Bool {
        return try await validateFrontierState(transactionBodies: transactionBodies, allAccountActions: getAllAccountActions(transactionBodies: transactionBodies), allActions: getAllActions(transactionBodies: transactionBodies), allDepositActions: getAllDepositActions(transactionBodies: transactionBodies), allGenesisActions: getAllGenesisActions(transactionBodies: transactionBodies), allPeerActions: getAllPeerActions(transactionBodies: transactionBodies), allReceiptActions: getAllReceiptActions(transactionBodies: transactionBodies), allWithdrawalActions: getAllWithdrawalActions(transactionBodies: transactionBodies), fetcher: fetcher)
    }
    
    // transactions should be fully resolved
    func validateFrontierState(transactionBodies: [TransactionBody], allAccountActions: [AccountAction], allActions: [Action], allDepositActions: [DepositAction], allGenesisActions: [GenesisAction], allPeerActions: [PeerAction], allReceiptActions: [ReceiptAction], allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> Bool {
        let resolvedHomestead = try await homestead.resolve(fetcher: fetcher)
        async let resolvedFrontier = frontier.resolve(fetcher: fetcher)
        guard let homesteadNode = resolvedHomestead.node else { throw ValidationErrors.homesteadNotResolved }
        async let updatedHomestead = homesteadNode.proveAndUpdateState(allAccountActions: allAccountActions, allActions: allActions, allDepositActions: allDepositActions, allGenesisActions: allGenesisActions, allPeerActions: allPeerActions, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, transactionBodies: transactionBodies, fetcher: fetcher)
        let (finalFrontier, finalUpdatedHomestead) = await (try resolvedFrontier, try updatedHomestead)
        guard let frontierNode = finalFrontier.node else { throw ValidationErrors.homesteadNotResolved }
        return frontierNode.accountState.rawCID == finalUpdatedHomestead.accountState.rawCID && frontierNode.generalState.rawCID == finalUpdatedHomestead.generalState.rawCID && frontierNode.depositState.rawCID == finalUpdatedHomestead.depositState.rawCID && frontierNode.genesisState.rawCID == finalUpdatedHomestead.genesisState.rawCID && frontierNode.peerState.rawCID == finalUpdatedHomestead.peerState.rawCID && frontierNode.receiptState.rawCID == finalUpdatedHomestead.receiptState.rawCID && frontierNode.withdrawalState.rawCID == finalUpdatedHomestead.withdrawalState.rawCID
    }
    
    func validateBalanceChanges(spec: ChainSpec, allDepositActions: [DepositAction], allWithdrawalActions: [WithdrawalAction], allAccountActions: [AccountAction], totalFees: UInt64) throws -> Bool {
        let reward = spec.rewardAtBlock(index)
        let totalDeposited = getTotalDeposited(allDepositActions: allDepositActions)
        let totalWithdrawn = getTotalWithdrawn(allWithdrawalActions: allWithdrawalActions)
        let totalBalanceBefore = allAccountActions.map { $0.oldBalance }.reduce(0, +)
        let totalBalanceAfter = allAccountActions.map { $0.newBalance }.reduce(0, +)
        return totalBalanceAfter <= totalBalanceBefore - totalDeposited + totalWithdrawn + reward + totalFees
    }

    func validateBalanceChangesForGenesis(spec: ChainSpec, allDepositActions: [DepositAction], allAccountActions: [AccountAction], totalFees: UInt64) throws -> Bool {
        let premineAmount = spec.premineAmount()
        let totalDeposited = getTotalDeposited(allDepositActions: allDepositActions)
        let totalBalanceAfter = allAccountActions.map { $0.newBalance }.reduce(0, +)
        return totalBalanceAfter <= premineAmount - totalDeposited + totalFees
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
        return previousBlock.timestamp < timestamp && Int64(Date().timeIntervalSince1970 * 1000) >= timestamp
    }
    
    func validateStateDeltaSize(spec: ChainSpec, transactionBodies: [TransactionBody]) throws -> Bool {
        return try transactionBodies.map { try $0.getStateDelta() }.reduce(0, +) <= spec.maxStateGrowth
    }
    
    func validateMaxTransactionCount(spec: ChainSpec, transactionBodies: [TransactionBody]) -> Bool {
        return transactionBodies.count <= spec.maxNumberOfTransactionsPerBlock
    }

    func validateBlockSize(spec: ChainSpec) -> Bool {
        guard let blockData = toData() else { return false }
        return blockData.count <= spec.maxBlockSize
    }
    
    func validateGenesisTransactions(fetcher: Fetcher, transactionBodies: [TransactionBody], parentSpec: ChainSpec? = nil) async throws -> Bool {
        return try await !transactionBodies.concurrentMap { transactionBody in
            try await transactionBody.genesisActionsAreValid(fetcher: fetcher, parentSpec: parentSpec)
        }.contains(false)
    }
}
