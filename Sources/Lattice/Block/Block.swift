import Foundation
import Crypto
import cashew
import UInt256
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
    public let version: UInt16
    public let previousBlock: VolumeImpl<Block>?
    public let transactions: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>
    public let difficulty: UInt256
    public let nextDifficulty: UInt256
    public let spec: HeaderImpl<ChainSpec>
    public let parentHomestead: LatticeStateHeader
    public let homestead: LatticeStateHeader
    public let frontier: LatticeStateHeader
    public let childBlocks: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>
    public let index: UInt64
    public let timestamp: Int64
    public let nonce: UInt64

    public init(version: UInt16 = 1, previousBlock: VolumeImpl<Block>?, transactions: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>, difficulty: UInt256, nextDifficulty: UInt256, spec: HeaderImpl<ChainSpec>, parentHomestead: LatticeStateHeader, homestead: LatticeStateHeader, frontier: LatticeStateHeader, childBlocks: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>, index: UInt64, timestamp: Int64, nonce: UInt64) {
        self.version = version
        self.previousBlock = previousBlock
        self.transactions = transactions
        self.difficulty = difficulty
        self.nextDifficulty = nextDifficulty
        self.spec = spec
        self.parentHomestead = parentHomestead
        self.homestead = homestead
        self.frontier = frontier
        self.childBlocks = childBlocks
        self.index = index
        self.timestamp = timestamp
        self.nonce = nonce
    }

    public static func == (lhs: Block, rhs: Block) -> Bool {
        guard let lhsData = lhs.toData() else { return false }
        guard let rhsData = rhs.toData() else { return false }
        return UInt256.hash(lhsData) == UInt256.hash(rhsData)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(version)
        hasher.combine(difficulty)
        hasher.combine(index)
        hasher.combine(timestamp)
        hasher.combine(nonce)
    }

    public func getGenesisSize() throws -> Int {
        guard let blockCount = toData()?.count else { throw ValidationErrors.serializationError }
        guard let specCount = spec.node?.toData()?.count else { throw ValidationErrors.serializationError }
        guard let txKeys = try? transactions.node?.allKeys() else { throw ValidationErrors.transactionNotResolved }
        let transactionKeysCount = txKeys.reduce(0) { $0 + $1.count }
        guard let transactionsKeysAndValues = try? transactions.node?.allKeysAndValues() else { throw ValidationErrors.transactionNotResolved }
        var totalTransactionDataCount = 0
        for transaction in transactionsKeysAndValues {
            guard let txDataCount = transaction.value.node?.toData()?.count else { throw ValidationErrors.transactionNotResolved }
            totalTransactionDataCount += txDataCount
        }
        guard let cbKeys = try? childBlocks.node?.allKeys() else { throw ValidationErrors.transactionNotResolved }
        let childBlocksKeysCount = cbKeys.reduce(0) { $0 + $1.count }
        guard let childBlocksKeysAndValues = try childBlocks.node?.allKeysAndValues() else { throw ValidationErrors.transactionNotResolved }
        var childBlocksCount = 0
        for block in childBlocksKeysAndValues {
            guard let blockDataCount = try block.value.node?.getGenesisSize() else { throw ValidationErrors.transactionNotResolved }
            childBlocksCount += blockDataCount
        }
        return blockCount + specCount + transactionKeysCount + totalTransactionDataCount + childBlocksKeysCount + childBlocksCount
    }

    public static func getTotalDeposited(_ allDepositActions: [DepositAction]) -> (total: UInt64, overflow: Bool) {
        var total: UInt64 = 0
        for action in allDepositActions {
            let (result, overflow) = total.addingReportingOverflow(action.amountDeposited)
            if overflow { return (0, true) }
            total = result
        }
        return (total, false)
    }

    public static func getTotalWithdrawn(_ allWithdrawalActions: [WithdrawalAction]) -> (total: UInt64, overflow: Bool) {
        var total: UInt64 = 0
        for action in allWithdrawalActions {
            let (result, overflow) = total.addingReportingOverflow(action.amountWithdrawn)
            if overflow { return (0, true) }
            total = result
        }
        return (total, false)
    }

    public static func getTotalFees(_ transactionBodies: [TransactionBody]) -> (total: UInt64, overflow: Bool) {
        var total: UInt64 = 0
        for body in transactionBodies {
            let (result, overflow) = total.addingReportingOverflow(body.fee)
            if overflow { return (0, true) }
            total = result
        }
        return (total, false)
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
        return Block(
            version: version,
            previousBlock: properties[PREVIOUS_BLOCK_PROPERTY] as? VolumeImpl<Block> ?? previousBlock,
            transactions: properties[TRANSACTIONS_PROPERTY] as? HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>> ?? transactions,
            difficulty: difficulty,
            nextDifficulty: nextDifficulty,
            spec: properties[SPEC_PROPERTY] as? HeaderImpl<ChainSpec> ?? spec,
            parentHomestead: properties[PARENT_HOMESTEAD_PROPERTY] as? LatticeStateHeader ?? parentHomestead,
            homestead: properties[HOMESTEAD_PROPERTY] as? LatticeStateHeader ?? homestead,
            frontier: properties[FRONTIER_PROPERTY] as? LatticeStateHeader ?? frontier,
            childBlocks: properties[CHILD_BLOCKS_PROPERTY] as? HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>> ?? childBlocks,
            index: index,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}

public enum ValidationErrors: Error {
    case transactionNotResolved, homesteadNotResolved, frontierNotResolved, serializationError
}
