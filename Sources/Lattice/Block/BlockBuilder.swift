import Foundation
import cashew
import UInt256

public enum BlockBuilderError: Error {
    case missingHomesteadState
    case stateComputationFailed
    case invalidTransactionBody
}

public struct BlockBuilder {

    // MARK: - Build Genesis Block

    public static func buildGenesis(
        spec: ChainSpec,
        transactions: [Transaction] = [],
        childBlocks: [String: Block] = [:],
        timestamp: Int64,
        difficulty: UInt256,
        nonce: UInt64 = 0,
        version: UInt16 = 1,
        fetcher: Fetcher
    ) async throws -> Block {
        let emptyState = LatticeState.emptyState()
        let homestead = LatticeStateHeader(node: emptyState)

        let transactionBodies = transactions.compactMap { $0.body.node }
        let frontier = try await computeFrontier(
            homestead: homestead,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )

        let block = Block(
            version: version,
            previousBlock: nil,
            transactions: buildTransactionsDictionary(transactions),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: VolumeImpl<ChainSpec>(node: spec),
            parentHomestead: homestead,
            homestead: homestead,
            frontier: frontier,
            childBlocks: buildChildBlocksDictionary(childBlocks),
            index: 0,
            timestamp: timestamp,
            nonce: nonce
        )
        if let storer = fetcher as? Storer {
            try BlockHeader(node: block).storeRecursively(storer: storer)
        }
        return block
    }

    // MARK: - Build Next Block (extends a chain)

    public static func buildBlock(
        previous: Block,
        transactions: [Transaction] = [],
        childBlocks: [String: Block] = [:],
        parentChainBlock: Block? = nil,
        timestamp: Int64,
        difficulty: UInt256? = nil,
        nextDifficulty: UInt256? = nil,
        nonce: UInt64 = 0,
        fetcher: Fetcher
    ) async throws -> Block {
        let homestead = previous.frontier
        let parentHomestead: LatticeStateHeader
        if let parentChainBlock = parentChainBlock {
            parentHomestead = parentChainBlock.homestead
        } else {
            parentHomestead = previous.parentHomestead
        }

        let blockDifficulty = difficulty ?? previous.difficulty
        let blockNextDifficulty = nextDifficulty ?? previous.nextDifficulty
        let previousCID = BlockHeader(node: previous).rawCID

        let transactionBodies = transactions.compactMap { $0.body.node }
        let frontier = try await computeFrontier(
            homestead: homestead,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )

        let block = Block(
            version: previous.version,
            previousBlock: VolumeImpl<Block>(rawCID: previousCID),
            transactions: buildTransactionsDictionary(transactions),
            difficulty: blockDifficulty,
            nextDifficulty: blockNextDifficulty,
            spec: previous.spec,
            parentHomestead: parentHomestead,
            homestead: homestead,
            frontier: frontier,
            childBlocks: buildChildBlocksDictionary(childBlocks),
            index: previous.index + 1,
            timestamp: timestamp,
            nonce: nonce
        )
        if let storer = fetcher as? Storer {
            try BlockHeader(node: previous).storeRecursively(storer: storer)
            try BlockHeader(node: block).storeRecursively(storer: storer)
        }
        return block
    }

    // MARK: - Mining (find valid nonce)

    public static func mine(
        block: Block,
        targetDifficulty: UInt256,
        maxAttempts: UInt64 = UInt64.max
    ) -> Block? {
        let sep: [UInt8] = [0x00]
        var prefix = Data()
        prefix.reserveCapacity(512)
        if let previousBlockCID = block.previousBlock?.rawCID {
            prefix.append(contentsOf: previousBlockCID.utf8)
        }
        prefix.append(contentsOf: sep)
        prefix.append(contentsOf: block.transactions.rawCID.utf8)
        prefix.append(contentsOf: sep)
        prefix.append(contentsOf: block.difficulty.toHexString().utf8)
        prefix.append(contentsOf: sep)
        prefix.append(contentsOf: block.nextDifficulty.toHexString().utf8)
        prefix.append(contentsOf: sep)
        prefix.append(contentsOf: block.spec.rawCID.utf8)
        prefix.append(contentsOf: sep)
        prefix.append(contentsOf: block.parentHomestead.rawCID.utf8)
        prefix.append(contentsOf: sep)
        prefix.append(contentsOf: block.homestead.rawCID.utf8)
        prefix.append(contentsOf: sep)
        prefix.append(contentsOf: block.frontier.rawCID.utf8)
        prefix.append(contentsOf: sep)
        prefix.append(contentsOf: block.childBlocks.rawCID.utf8)
        prefix.append(contentsOf: sep)
        prefix.append(contentsOf: String(block.index).utf8)
        prefix.append(contentsOf: sep)
        prefix.append(contentsOf: String(block.timestamp).utf8)
        prefix.append(contentsOf: sep)

        for nonce in 0..<maxAttempts {
            var data = prefix
            data.append(contentsOf: String(nonce).utf8)
            let hash = UInt256.hash(data)
            if targetDifficulty >= hash {
                return Block(
                    previousBlock: block.previousBlock,
                    transactions: block.transactions,
                    difficulty: block.difficulty,
                    nextDifficulty: block.nextDifficulty,
                    spec: block.spec,
                    parentHomestead: block.parentHomestead,
                    homestead: block.homestead,
                    frontier: block.frontier,
                    childBlocks: block.childBlocks,
                    index: block.index,
                    timestamp: block.timestamp,
                    nonce: nonce
                )
            }
        }
        return nil
    }

    // MARK: - Frontier Computation

    static func computeFrontier(
        homestead: LatticeStateHeader,
        transactionBodies: [TransactionBody],
        fetcher: Fetcher
    ) async throws -> LatticeStateHeader {
        if transactionBodies.isEmpty {
            return homestead
        }

        guard let homesteadNode = homestead.node else {
            let resolved = try await homestead.resolve(fetcher: fetcher)
            guard let resolvedNode = resolved.node else {
                throw BlockBuilderError.missingHomesteadState
            }
            return try await computeFrontierFromState(
                state: resolvedNode,
                transactionBodies: transactionBodies,
                fetcher: fetcher
            )
        }

        return try await computeFrontierFromState(
            state: homesteadNode,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )
    }

    static func computeFrontierFromState(
        state: LatticeState,
        transactionBodies: [TransactionBody],
        fetcher: Fetcher
    ) async throws -> LatticeStateHeader {
        let allAccountActions = transactionBodies.flatMap { $0.accountActions }
        let allActions = transactionBodies.flatMap { $0.actions }
        let allDepositActions = transactionBodies.flatMap { $0.depositActions }
        let allGenesisActions = transactionBodies.flatMap { $0.genesisActions }
        let allReceiptActions = transactionBodies.flatMap { $0.receiptActions }
        let allWithdrawalActions = transactionBodies.flatMap { $0.withdrawalActions }

        let (updatedState, _) = try await state.proveAndUpdateState(
            allAccountActions: allAccountActions,
            allActions: allActions,
            allDepositActions: allDepositActions,
            allGenesisActions: allGenesisActions,
            allReceiptActions: allReceiptActions,
            allWithdrawalActions: allWithdrawalActions,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )

        return LatticeStateHeader(node: updatedState)
    }

    // MARK: - Merkle Dictionary Construction

    static func buildTransactionsDictionary(
        _ transactions: [Transaction]
    ) -> HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>> {
        if transactions.isEmpty {
            return HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>(
                node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()
            )
        }

        var dict = MerkleDictionaryImpl<VolumeImpl<Transaction>>()
        for (i, tx) in transactions.enumerated() {
            let txHeader = VolumeImpl<Transaction>(node: tx)
            dict = (try? dict.inserting(key: String(i), value: txHeader)) ?? dict
        }
        return HeaderImpl(node: dict)
    }

    static func buildChildBlocksDictionary(
        _ childBlocks: [String: Block]
    ) -> HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>> {
        if childBlocks.isEmpty {
            return HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>(
                node: MerkleDictionaryImpl<VolumeImpl<Block>>()
            )
        }

        var dict = MerkleDictionaryImpl<VolumeImpl<Block>>()
        for (directory, block) in childBlocks {
            let blockHeader = VolumeImpl<Block>(node: block)
            dict = (try? dict.inserting(key: directory, value: blockHeader)) ?? dict
        }
        return HeaderImpl(node: dict)
    }
}
