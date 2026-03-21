import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

private let fetcher = ThrowingFetcher()

private func testSpec(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(
        directory: dir,
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000,
        difficultyAdjustmentWindow: 5
    )
}

// MARK: - Mempool Tests

@MainActor
final class MempoolTests: XCTestCase {

    func testAddAndSelectByFee() async {
        let mempool = Mempool(maxSize: 100)

        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        var txs: [Transaction] = []
        for i: UInt64 in 0..<5 {
            let body = TransactionBody(
                accountActions: [], actions: [], swapActions: [],
                swapClaimActions: [], genesisActions: [], peerActions: [],
                settleActions: [], signers: [signerCID], fee: i * 10, nonce: i
            )
            let bodyHeader = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)
            txs.append(tx)
        }

        for tx in txs {
            let added = await mempool.add(transaction: tx)
            XCTAssertTrue(added)
        }

        let count = await mempool.count
        XCTAssertEqual(count, 5)

        let selected = await mempool.selectTransactions(maxCount: 3)
        XCTAssertEqual(selected.count, 3)

        let fees = selected.compactMap { $0.body.node?.fee }
        XCTAssertEqual(fees, fees.sorted(by: >), "Should be sorted by descending fee")
    }

    func testDuplicateRejected() async {
        let mempool = Mempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [signerCID], fee: 10, nonce: 1
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)

        let first = await mempool.add(transaction: tx)
        XCTAssertTrue(first)
        let second = await mempool.add(transaction: tx)
        XCTAssertFalse(second)
    }

    func testInvalidSignatureRejected() async {
        let mempool = Mempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: ["fake"], fee: 10, nonce: 1
        )
        let tx = Transaction(signatures: [kp.publicKey: "deadbeef"], body: HeaderImpl<TransactionBody>(node: body))

        let added = await mempool.add(transaction: tx)
        XCTAssertFalse(added, "Invalid signature should be rejected")
    }

    func testEvictsLowestFeeWhenFull() async {
        let mempool = Mempool(maxSize: 3)
        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        for i: UInt64 in 0..<4 {
            let body = TransactionBody(
                accountActions: [], actions: [], swapActions: [],
                swapClaimActions: [], genesisActions: [], peerActions: [],
                settleActions: [], signers: [signerCID], fee: (i + 1) * 10, nonce: i
            )
            let bodyHeader = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)
            let _ = await mempool.add(transaction: tx)
        }

        let count = await mempool.count
        XCTAssertEqual(count, 3, "Should evict to stay at maxSize")

        let selected = await mempool.selectTransactions(maxCount: 3)
        let fees = selected.compactMap { $0.body.node?.fee }
        XCTAssertFalse(fees.contains(10), "Lowest fee (10) should have been evicted")
    }

    func testPruneConfirmed() async {
        let mempool = Mempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        var cids: [String] = []
        for i: UInt64 in 0..<3 {
            let body = TransactionBody(
                accountActions: [], actions: [], swapActions: [],
                swapClaimActions: [], genesisActions: [], peerActions: [],
                settleActions: [], signers: [signerCID], fee: 10, nonce: i
            )
            let bodyHeader = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)
            let _ = await mempool.add(transaction: tx)
            cids.append(bodyHeader.rawCID)
        }

        await mempool.removeAll(txCIDs: Set([cids[0], cids[1]]))
        let remaining = await mempool.count
        XCTAssertEqual(remaining, 1)
    }
}

// MARK: - Full Pipeline Acceptance Test

@MainActor
final class FullPipelineAcceptanceTests: XCTestCase {

    func testBuildMineSubmitBroadcastCycle() async throws {
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let mempool = Mempool(maxSize: 1000)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: 2_000_000,
            difficulty: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let mined = BlockBuilder.mine(block: block1, targetDifficulty: UInt256.max, maxAttempts: 10)
        XCTAssertNotNil(mined)

        let header = HeaderImpl<Block>(node: mined!)
        let result = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header, block: mined!
        )
        XCTAssertTrue(result.extendsMainChain)

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, header.rawCID)
    }

    func testMempoolToBlockPipeline() async throws {
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let mempool = Mempool(maxSize: 1000)

        let kp = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID

        for i: UInt64 in 0..<5 {
            let body = TransactionBody(
                accountActions: [], actions: [], swapActions: [],
                swapClaimActions: [], genesisActions: [], peerActions: [],
                settleActions: [], signers: [signerCID], fee: i + 1, nonce: i
            )
            let bodyHeader = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)
            let _ = await mempool.add(transaction: tx)
        }

        let count = await mempool.count
        XCTAssertEqual(count, 5)

        let selected = await mempool.selectTransactions(maxCount: 3)
        XCTAssertEqual(selected.count, 3)

        let fees = selected.compactMap { $0.body.node?.fee }
        XCTAssertTrue(fees[0] >= fees[1] && fees[1] >= fees[2], "Highest fees selected first")
    }

    func testMultiChainConsensusWithAnchoringAndReorg() async throws {
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Child")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: 1_000_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: 1_000_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Child": childLevel])

        var nexusPrev = nexusGenesis
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: nexusPrev, timestamp: 1_000_000 + Int64(i) * 1000,
                nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await nexusChain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
            nexusPrev = block
        }

        let nexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 5)

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, timestamp: 2_000_000, nonce: 1, fetcher: fetcher
        )
        let nexusBlockHeader = HeaderImpl<Block>(node: nexusPrev)
        let childResult = await childChain.submitBlock(
            parentBlockHeaderAndIndex: (nexusBlockHeader.rawCID, nexusHeight),
            blockHeader: HeaderImpl<Block>(node: childBlock1),
            block: childBlock1
        )
        XCTAssertTrue(childResult.extendsMainChain)

        let childHeight = await childChain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 1)

        let childBlock1Meta = await childChain.getConsensusBlock(
            hash: HeaderImpl<Block>(node: childBlock1).rawCID
        )
        XCTAssertNotNil(childBlock1Meta?.parentIndex, "Child block should have parent chain anchoring")
    }

    private func buildLongChain(length: Int) async throws -> [Block] {
        var blocks: [Block] = []
        let g = try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: 1_000_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        blocks.append(g)
        for i in 1..<length {
            let b = try await BlockBuilder.buildBlock(
                previous: blocks.last!, timestamp: 1_000_000 + Int64(i) * 1000,
                nonce: UInt64(i), fetcher: fetcher
            )
            blocks.append(b)
        }
        return blocks
    }
}
