import Foundation
import Crypto
import cashew
import UInt256
import ArrayTrie
import CollectionConcurrencyKit

let PREVIOUS_BLOCK_PROPERTY = "previous"
let TRANSACTIONS_PROPERTY = "transactions"
let SPEC_PROPERTY = "spec"
let PARENT_HOMESTEAD_PROPERTY = "parentHomestead"
let HOMESTEAD_PROPERTY = "homestead"
let FRONTIER_PROPERTY = "frontier"
let CHILD_BLOCKS_PROPERTY = "childBlocks"

let BLOCK_PROPERTIES = Set([PREVIOUS_BLOCK_PROPERTY, TRANSACTIONS_PROPERTY, SPEC_PROPERTY, PARENT_HOMESTEAD_PROPERTY, HOMESTEAD_PROPERTY, FRONTIER_PROPERTY, CHILD_BLOCKS_PROPERTY])

public struct Block: Hashable {
    public let previousBlock: HeaderImpl<Block>?
    public let transactions: HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Transaction>>>
    public let difficulty: UInt256
    public let nextDifficulty: UInt256
    public let spec: HeaderImpl<ChainSpec>
    public let parentHomestead: LatticeStateHeader
    public let homestead: LatticeStateHeader
    public let frontier: LatticeStateHeader
    public let childBlocks: HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Block>>>
    public let index: UInt64
    public let timestamp: Int64
    public let nonce: UInt64
    
    public static func == (lhs: Block, rhs: Block) -> Bool {
        guard let lhsData = lhs.toData() else { return false }
        guard let rhsData = rhs.toData() else { return false }
        return UInt256.hash(lhsData) == UInt256.hash(rhsData)
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(difficulty)
        hasher.combine(index)
        hasher.combine(timestamp)
        hasher.combine(nonce)
    }
    
    public func getGenesisSize() throws -> Int {
        guard let blockCount = toData()?.count else { throw ValidationErrors.serializationError }
        guard let specCount = spec.node?.toData()?.count else { throw ValidationErrors.serializationError }
        guard let transactionKeysCount = try? transactions.node?.allKeys().map({ $0.count }).reduce(0, +) else { throw ValidationErrors.transactionNotResolved }
        guard let transactionsKeysAndValues = try? transactions.node?.allKeysAndValues() else { throw ValidationErrors.transactionNotResolved }
        var totalTransactionDataCount = 0
        for transaction in transactionsKeysAndValues {
            guard let transctionDataCount = transaction.value.node?.toData()?.count else { throw ValidationErrors.transactionNotResolved }
            totalTransactionDataCount += transctionDataCount
        }
        guard let childBlocksKeysCount = try childBlocks.node?.allKeys().map({ $0.count }).reduce(0, +) else { throw ValidationErrors.transactionNotResolved }
        guard let childBlocksKeysAndValues = try childBlocks.node?.allKeysAndValues() else { throw ValidationErrors.transactionNotResolved }
        var childBlocksCount = 0
        for block in childBlocksKeysAndValues {
            guard let blockDataCount = try block.value.node?.getGenesisSize() else { throw ValidationErrors.transactionNotResolved }
            childBlocksCount += blockDataCount
        }
        return blockCount + specCount + transactionKeysCount + totalTransactionDataCount + childBlocksKeysCount + childBlocksCount
    }
    
    
    public func getAllAccountActions(transactionBodies: [TransactionBody]) -> [AccountAction] {
        return transactionBodies.map { $0.accountActions }.reduce([], +)
    }
    
    public func getAllDepositActions(transactionBodies: [TransactionBody]) -> [DepositAction] {
        return transactionBodies.map { $0.depositActions }.reduce([], +)
    }
    
    public func getAllWithdrawalActions(transactionBodies: [TransactionBody]) -> [WithdrawalAction] {
        return transactionBodies.map { $0.withdrawalActions }.reduce([], +)
    }
    
    public func getAllActions(transactionBodies: [TransactionBody]) -> [Action] {
        return transactionBodies.map { $0.actions }.reduce([], +)
    }
    
    public func getAllGenesisActions(transactionBodies: [TransactionBody]) -> [GenesisAction] {
        return transactionBodies.map { $0.genesisActions }.reduce([], +)
    }
    
    public func getAllPeerActions(transactionBodies: [TransactionBody]) -> [PeerAction] {
        return transactionBodies.map { $0.peerActions }.reduce([], +)
    }
    
    public func getAllReceiptActions(transactionBodies: [TransactionBody]) -> [ReceiptAction] {
        return transactionBodies.map { $0.receiptActions }.reduce([], +)
    }
    
    public func getTotalDeposited(allDepositActions: [DepositAction]) -> UInt64 {
        return allDepositActions.map { $0.amountDeposited }.reduce(0, +)
    }
    
    public func getTotalWithdrawn(allWithdrawalActions: [WithdrawalAction]) -> UInt64 {
        return allWithdrawalActions.map { $0.amountWithdrawn }.reduce(0, +)
    }
}

extension Block: Node {
    public func get(property: PathSegment) -> (any cashew.Header)? {
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
    
    public func set(properties: [PathSegment : any cashew.Header]) -> Block {
        return Block(previousBlock: properties[PREVIOUS_BLOCK_PROPERTY] as? HeaderImpl<Block>, transactions: properties[TRANSACTIONS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Transaction>>>, difficulty: difficulty, nextDifficulty: nextDifficulty, spec: properties[SPEC_PROPERTY] as! HeaderImpl<ChainSpec>, parentHomestead: properties[PARENT_HOMESTEAD_PROPERTY] as! LatticeStateHeader, homestead: properties[HOMESTEAD_PROPERTY] as! LatticeStateHeader, frontier: properties[FRONTIER_PROPERTY] as! LatticeStateHeader, childBlocks: properties[CHILD_BLOCKS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Block>>>, index: index, timestamp: timestamp, nonce: nonce)
    }
}

public enum ValidationErrors: Error {
    case transactionNotResolved, homesteadNotResolved, frontierNotResolved, serializationError
}
