import Foundation
import cashew
import UInt256

public protocol MinerDelegate: AnyObject, Sendable {
    func minerDidProduceBlock(_ block: Block, hash: String) async
}

public actor MinerLoop {
    private let chainState: ChainState
    private let mempool: Mempool
    private let fetcher: Fetcher
    private let spec: ChainSpec
    private var mining: Bool
    private var currentTask: Task<Void, Never>?
    public weak var delegate: MinerDelegate?

    public init(chainState: ChainState, mempool: Mempool, fetcher: Fetcher, spec: ChainSpec) {
        self.chainState = chainState
        self.mempool = mempool
        self.fetcher = fetcher
        self.spec = spec
        self.mining = false
    }

    public var isMining: Bool { mining }

    public func start() {
        guard !mining else { return }
        mining = true
        currentTask = Task { [weak self] in
            await self?.mineLoop()
        }
    }

    public func stop() {
        mining = false
        currentTask?.cancel()
        currentTask = nil
    }

    private func mineLoop() async {
        while mining && !Task.isCancelled {
            do {
                let previousBlock = try await resolveCurrentTip()
                guard let previousBlock = previousBlock else {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }

                let transactions = await mempool.selectTransactions(
                    maxCount: Int(spec.maxNumberOfTransactionsPerBlock)
                )

                let template = try await BlockBuilder.buildBlock(
                    previous: previousBlock,
                    transactions: transactions,
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    difficulty: previousBlock.nextDifficulty,
                    nonce: 0,
                    fetcher: fetcher
                )

                let batchSize: UInt64 = 10_000
                var nonce: UInt64 = 0

                while mining && !Task.isCancelled {
                    let tipChanged = await hasTipChanged(previousHash: HeaderImpl<Block>(node: previousBlock).rawCID)
                    if tipChanged { break }

                    if let mined = BlockBuilder.mine(
                        block: withNonce(template, startNonce: nonce),
                        targetDifficulty: previousBlock.nextDifficulty,
                        maxAttempts: batchSize
                    ) {
                        let hash = HeaderImpl<Block>(node: mined).rawCID

                        let confirmedCIDs = Set(transactions.map { $0.body.rawCID })
                        await mempool.removeAll(txCIDs: confirmedCIDs)

                        await delegate?.minerDidProduceBlock(mined, hash: hash)
                        break
                    }

                    nonce += batchSize
                    await Task.yield()
                }
            } catch {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func resolveCurrentTip() async throws -> Block? {
        let tipHash = await chainState.getMainChainTip()
        let tipData = try await fetcher.fetch(rawCid: tipHash)
        return Block(data: tipData)
    }

    private func hasTipChanged(previousHash: String) async -> Bool {
        let currentTip = await chainState.getMainChainTip()
        return currentTip != previousHash
    }

    private func withNonce(_ block: Block, startNonce: UInt64) -> Block {
        Block(
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
            nonce: startNonce
        )
    }
}
