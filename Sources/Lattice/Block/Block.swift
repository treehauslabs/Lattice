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

    public init(version: UInt16 = 1, previousBlock: HeaderImpl<Block>?, transactions: HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Transaction>>>, difficulty: UInt256, nextDifficulty: UInt256, spec: HeaderImpl<ChainSpec>, parentHomestead: LatticeStateHeader, homestead: LatticeStateHeader, frontier: LatticeStateHeader, childBlocks: HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Block>>>, index: UInt64, timestamp: Int64, nonce: UInt64) {
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


    public static func getAllAccountActions(_ transactionBodies: [TransactionBody]) -> [AccountAction] {
        transactionBodies.flatMap { $0.accountActions }
    }

    public static func getAllSwapActions(_ transactionBodies: [TransactionBody]) -> [SwapAction] {
        transactionBodies.flatMap { $0.swapActions }
    }

    public static func getAllSwapClaimActions(_ transactionBodies: [TransactionBody]) -> [SwapClaimAction] {
        transactionBodies.flatMap { $0.swapClaimActions }
    }

    public static func getAllActions(_ transactionBodies: [TransactionBody]) -> [Action] {
        transactionBodies.flatMap { $0.actions }
    }

    public static func getAllGenesisActions(_ transactionBodies: [TransactionBody]) -> [GenesisAction] {
        transactionBodies.flatMap { $0.genesisActions }
    }

    public static func getAllPeerActions(_ transactionBodies: [TransactionBody]) -> [PeerAction] {
        transactionBodies.flatMap { $0.peerActions }
    }

    public static func getAllSettleActions(_ transactionBodies: [TransactionBody]) -> [SettleAction] {
        transactionBodies.flatMap { $0.settleActions }
    }

    public static func getTotalSwapLocked(_ allSwapActions: [SwapAction]) -> (total: UInt64, overflow: Bool) {
        var total: UInt64 = 0
        for action in allSwapActions {
            let (result, overflow) = total.addingReportingOverflow(action.amount)
            if overflow { return (0, true) }
            total = result
        }
        return (total, false)
    }

    public static func getTotalSwapClaimed(_ allSwapClaimActions: [SwapClaimAction]) -> (total: UInt64, overflow: Bool) {
        var total: UInt64 = 0
        for action in allSwapClaimActions {
            let (result, overflow) = total.addingReportingOverflow(action.amount)
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
        return Block(version: version, previousBlock: properties[PREVIOUS_BLOCK_PROPERTY] as? HeaderImpl<Block>, transactions: properties[TRANSACTIONS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Transaction>>>, difficulty: difficulty, nextDifficulty: nextDifficulty, spec: properties[SPEC_PROPERTY] as! HeaderImpl<ChainSpec>, parentHomestead: properties[PARENT_HOMESTEAD_PROPERTY] as! LatticeStateHeader, homestead: properties[HOMESTEAD_PROPERTY] as! LatticeStateHeader, frontier: properties[FRONTIER_PROPERTY] as! LatticeStateHeader, childBlocks: properties[CHILD_BLOCKS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Block>>>, index: index, timestamp: timestamp, nonce: nonce)
    }
}

public enum ValidationErrors: Error {
    case transactionNotResolved, homesteadNotResolved, frontierNotResolved, serializationError
}
