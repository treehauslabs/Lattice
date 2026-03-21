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

        return Block(
            previousBlock: nil,
            transactions: buildTransactionsDictionary(transactions),
            difficulty: difficulty,
            nextDifficulty: difficulty,
            spec: HeaderImpl<ChainSpec>(node: spec),
            parentHomestead: homestead,
            homestead: homestead,
            frontier: frontier,
            childBlocks: buildChildBlocksDictionary(childBlocks),
            index: 0,
            timestamp: timestamp,
            nonce: nonce
        )
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

        let transactionBodies = transactions.compactMap { $0.body.node }
        let frontier = try await computeFrontier(
            homestead: homestead,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )

        return Block(
            previousBlock: HeaderImpl<Block>(node: previous),
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
    }

    // MARK: - Mining (find valid nonce)

    public static func mine(
        block: Block,
        targetDifficulty: UInt256,
        maxAttempts: UInt64 = UInt64.max
    ) -> Block? {
        var prefix = Data()
        prefix.reserveCapacity(512)
        if let previousBlockCID = block.previousBlock?.rawCID {
            prefix.append(contentsOf: previousBlockCID.utf8)
        }
        prefix.append(contentsOf: block.transactions.rawCID.utf8)
        prefix.append(contentsOf: block.difficulty.toHexString().utf8)
        prefix.append(contentsOf: block.nextDifficulty.toHexString().utf8)
        prefix.append(contentsOf: block.spec.rawCID.utf8)
        prefix.append(contentsOf: block.parentHomestead.rawCID.utf8)
        prefix.append(contentsOf: block.homestead.rawCID.utf8)
        prefix.append(contentsOf: block.frontier.rawCID.utf8)
        prefix.append(contentsOf: block.childBlocks.rawCID.utf8)
        prefix.append(contentsOf: String(block.index).utf8)
        prefix.append(contentsOf: String(block.timestamp).utf8)

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
        let allPeerActions = transactionBodies.flatMap { $0.peerActions }
        let allReceiptActions = transactionBodies.flatMap { $0.receiptActions }
        let allWithdrawalActions = transactionBodies.flatMap { $0.withdrawalActions }

        let updatedState = try await state.proveAndUpdateState(
            allAccountActions: allAccountActions,
            allActions: allActions,
            allDepositActions: allDepositActions,
            allGenesisActions: allGenesisActions,
            allPeerActions: allPeerActions,
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
    ) -> HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Transaction>>> {
        if transactions.isEmpty {
            return HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Transaction>>>(
                node: MerkleDictionaryImpl<HeaderImpl<Transaction>>()
            )
        }

        var dict = MerkleDictionaryImpl<HeaderImpl<Transaction>>()
        for (i, tx) in transactions.enumerated() {
            let txHeader = HeaderImpl<Transaction>(node: tx)
            dict = (try? dict.inserting(key: String(i), value: txHeader)) ?? dict
        }
        return HeaderImpl(node: dict)
    }

    static func buildChildBlocksDictionary(
        _ childBlocks: [String: Block]
    ) -> HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Block>>> {
        if childBlocks.isEmpty {
            return HeaderImpl<MerkleDictionaryImpl<HeaderImpl<Block>>>(
                node: MerkleDictionaryImpl<HeaderImpl<Block>>()
            )
        }

        var dict = MerkleDictionaryImpl<HeaderImpl<Block>>()
        for (directory, block) in childBlocks {
            let blockHeader = HeaderImpl<Block>(node: block)
            dict = (try? dict.inserting(key: directory, value: blockHeader)) ?? dict
        }
        return HeaderImpl(node: dict)
    }
}
