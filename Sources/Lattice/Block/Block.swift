import Foundation
import Crypto
import cashew
import UInt256

let PREVIOUS_BLOCK_PROPERTY = "previous"
let TRANSACTIONS_PROPERTY = "transactions"
let SPEC_PROPERTY = "spec"
let PARENT_HOMESTEAD_PROPERTY = "parentHomestead"
let HOMESTEAD_PROPERTY = "homestead"
let FRONTIER_PROPERTY = "frontier"
let CHILD_BLOCKS_PROPERTY = "childBlocks"

let BLOCK_PROPERTIES = Set([PREVIOUS_BLOCK_PROPERTY, TRANSACTIONS_PROPERTY, SPEC_PROPERTY, PARENT_HOMESTEAD_PROPERTY, HOMESTEAD_PROPERTY, FRONTIER_PROPERTY, CHILD_BLOCKS_PROPERTY])

public struct Block {
    let previousBlock: HeaderImpl<Block>?
    let transactions: HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Transaction>>>
    let nextDifficulty: UInt256
    let spec: HeaderImpl<ChainSpec>
    let parentHomestead: LatticeStateHeader
    let homestead: LatticeStateHeader
    let frontier: LatticeStateHeader
    let childBlocks: HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Block>>>
    let index: UInt64
    let timestamp: Int64
    let nonce: UInt64
    
    // transactions should be fully resolved
    public func validateFrontierState(transactionBodies: [TransactionBody], allAccountActions: [AccountAction], allActions: [Action], allDepositActions: [DepositAction], allGenesisActions: [GenesisAction], allPeerActions: [PeerAction], allReceiptActions: [ReceiptAction], allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> Bool {
        let resolvedHomestead = try await homestead.resolve(fetcher: fetcher)
        async let resolvedFrontier = frontier.resolve(fetcher: fetcher)
        guard let homesteadNode = resolvedHomestead.node else { throw ValidationErrors.homesteadNotResolved }
        async let updatedHomestead = homesteadNode.proveAndUpdateState(allAccountActions: allAccountActions, allActions: allActions, allDepositActions: allDepositActions, allGenesisActions: allGenesisActions, allPeerActions: allPeerActions, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, transactionBodies: transactionBodies, fetcher: fetcher)
        let (finalFrontier, finalUpdatedHomestead) = await (try resolvedFrontier, try updatedHomestead)
        guard let frontierNode = finalFrontier.node else { throw ValidationErrors.homesteadNotResolved }
        return frontierNode.accountState.rawCID == finalUpdatedHomestead.accountState.rawCID && frontierNode.generalState.rawCID == finalUpdatedHomestead.generalState.rawCID && frontierNode.depositState.rawCID == finalUpdatedHomestead.depositState.rawCID && frontierNode.genesisState.rawCID == finalUpdatedHomestead.genesisState.rawCID && frontierNode.peerState.rawCID == finalUpdatedHomestead.peerState.rawCID && frontierNode.receiptState.rawCID == finalUpdatedHomestead.receiptState.rawCID && frontierNode.withdrawalState.rawCID == finalUpdatedHomestead.withdrawalState.rawCID
    }
    
    public func validateBalanceChanges(spec: ChainSpec, allDepositActions: [DepositAction], allWithdrawalActions: [WithdrawalAction], allAccountActions: [AccountAction]) throws -> Bool {
        let reward = spec.rewardAtBlock(index)
        let totalDeposited = try getTotalDeposited(allDepositActions: allDepositActions)
        let totalWithdrawn = try getTotalWithdrawn(allWithdrawalActions: allWithdrawalActions)
        let totalBalanceBefore = allAccountActions.map { $0.oldBalance }.reduce(0, +)
        let totalBalanceAfter = allAccountActions.map { $0.newBalance }.reduce(0, +)
        return totalBalanceAfter <= totalBalanceBefore - totalDeposited + totalWithdrawn + reward
    }
    
    public func getAllAccountActions(transactionBodies: [TransactionBody]) throws -> [AccountAction] {
        let totalAccountNodes = transactionBodies.map { $0.accountActions.node }
        if totalAccountNodes.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        return try totalAccountNodes.map { try $0!.allKeysAndValues() }.map { $0.values }.reduce([], +)
    }
    
    public func getAllDepositActions(transactionBodies: [TransactionBody]) throws -> [DepositAction] {
        let totalDepositsNodes = transactionBodies.map { $0.depositActions.node }
        if totalDepositsNodes.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        return try totalDepositsNodes.map { try $0!.allKeysAndValues() }.map { $0.values }.reduce([], +)
    }
    
    public func getAllWithdrawalActions(transactionBodies: [TransactionBody]) throws -> [WithdrawalAction] {
        let totalWithdrawalNodes = transactionBodies.map { $0.withdrawalActions.node }
        if totalWithdrawalNodes.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        return try totalWithdrawalNodes.map { try $0!.allKeysAndValues() }.map { $0.values }.reduce([], +)
    }
    
    public func getTotalDeposited(allDepositActions: [DepositAction]) throws -> UInt64 {
        return allDepositActions.map { $0.amountDeposited }.reduce(0, +)
    }
    
    public func getTotalWithdrawn(allWithdrawalActions: [WithdrawalAction]) throws -> UInt64 {
        return allWithdrawalActions.map { $0.amountWithdrawn }.reduce(0, +)
    }
    
    public func validateSpec(previousBlock: Block) -> Bool {
        return previousBlock.spec.rawCID == spec.rawCID
    }
    
    public func validateParentState(parent: Block) -> Bool {
        return parent.homestead.rawCID == parentHomestead.rawCID
    }
    
    public func validateNextDifficulty(spec: ChainSpec, previousBlock: Block) -> Bool {
        return nextDifficulty < spec.calculateMinimumDifficulty(previousDifficulty: previousBlock.nextDifficulty, blockTimestamp: timestamp, previousTimestamp: previousBlock.timestamp)
    }
    
    public func validateState(previousBlock: Block) -> Bool {
        return previousBlock.frontier.rawCID == homestead.rawCID
    }
    
    public func validateIndex(previousBlock: Block) -> Bool {
        return previousBlock.index + 1 == index
    }
    
    public func validateBlockDifficulty(hash: UInt256, previousBlock: Block) -> Bool {
        guard let blockHeaderData = toData() else { return false }
        return previousBlock.nextDifficulty > UInt256.hash(blockHeaderData)
    }
    
    public func validateTimestamp(previousBlock: Block) -> Bool {
        return previousBlock.timestamp < timestamp && Int64(Date().timeIntervalSince1970 * 1000) >= timestamp
    }
}

extension Block: Node {
    public func get(property: PathSegment) -> (any cashew.Address)? {
        switch property {
            case PREVIOUS_BLOCK_PROPERTY: return previousBlock
            case TRANSACTIONS_PROPERTY: return transactions
            case SPEC_PROPERTY: return spec
            case PARENT_HOMESTEAD_PROPERTY: return parentHomestead
            case HOMESTEAD_PROPERTY: return homestead
            case FRONTIER_PROPERTY: return frontier
            case CHILD_BLOCKS_PROPERTY: return childBlocks
            default: return nil
        }
    }
    
    public func properties() -> Set<PathSegment> {
        return BLOCK_PROPERTIES
    }
    
    public func set(properties: [PathSegment : any cashew.Address]) -> Block {
        return Block(previousBlock: properties[PREVIOUS_BLOCK_PROPERTY] as? HeaderImpl<Block>, transactions: properties[TRANSACTIONS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Transaction>>>, nextDifficulty: nextDifficulty, spec: properties[SPEC_PROPERTY] as! HeaderImpl<ChainSpec>, parentHomestead: properties[PARENT_HOMESTEAD_PROPERTY] as! LatticeStateHeader, homestead: properties[HOMESTEAD_PROPERTY] as! LatticeStateHeader, frontier: properties[FRONTIER_PROPERTY] as! LatticeStateHeader, childBlocks: properties[CHILD_BLOCKS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Block>>>, index: index, timestamp: timestamp, nonce: nonce)
    }
}

public enum ValidationErrors: Error {
    case transactionNotResolved, homesteadNotResolved, frontierNotResolved
}
