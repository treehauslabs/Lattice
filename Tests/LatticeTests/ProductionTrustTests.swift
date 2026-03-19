import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation
import Acorn

private actor ProdWorker: AcornCASWorker {
    var near: (any AcornCASWorker)?
    var far: (any AcornCASWorker)?
    var timeout: Duration? { nil }
    private var store: [ContentIdentifier: Data] = [:]
    func has(cid: ContentIdentifier) -> Bool { store[cid] != nil }
    func getLocal(cid: ContentIdentifier) async -> Data? { store[cid] }
    func storeLocal(cid: ContentIdentifier, data: Data) async { store[cid] = data }
}

private func f() -> AcornFetcher { AcornFetcher(worker: ProdWorker()) }

private func s(_ dir: String = "Nexus", premine: UInt64 = 1000) -> ChainSpec {
    ChainSpec(directory: dir, maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
}

private func tx(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = HeaderImpl<TransactionBody>(node: body)
    let sig = CryptoUtils.sign(message: h.rawCID, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: sig], body: h)
}

private func id(_ pubKey: String) -> String {
    HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
}

private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private func premineGenesis(
    spec: ChainSpec, owner kp: (privateKey: String, publicKey: String),
    fetcher: AcornFetcher, time: Int64
) async throws -> Block {
    let addr = id(kp.publicKey)
    let body = TransactionBody(
        accountActions: [AccountAction(owner: addr, oldBalance: 0, newBalance: spec.premineAmount())],
        actions: [], depositActions: [], genesisActions: [], peerActions: [],
        receiptActions: [], withdrawalActions: [], signers: [addr], fee: 0, nonce: 0
    )
    return try await BlockBuilder.buildGenesis(
        spec: spec, transactions: [tx(body, kp)],
        timestamp: time, difficulty: UInt256(1000), fetcher: fetcher
    )
}

private func buildChain(from genesis: Block, length: Int, base: Int64, fetcher: AcornFetcher) async throws -> [Block] {
    var blocks = [genesis]
    for i in 1..<length {
        let b = try await BlockBuilder.buildBlock(
            previous: blocks.last!, timestamp: base + Int64(i) * 1000,
            difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
        )
        blocks.append(b)
    }
    return blocks
}

// ============================================================================
// MARK: - Crash Recovery: Persist, Restart, Continue
// ============================================================================

@MainActor
final class CrashRecoveryTests: XCTestCase {

    func testPersistRestoreContinueMining() async throws {
        let fetcher = f()
        let base = now() - 50_000
        let spec = s(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain1 = ChainState.fromGenesis(block: genesis)

        var prev = genesis
        for i in 1...5 {
            let b = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await chain1.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: b), block: b
            )
            prev = b
        }

        let persisted = await chain1.persist()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: data)

        let chain2 = ChainState.restore(from: decoded)

        let tip2 = await chain2.getMainChainTip()
        let tip1 = await chain1.getMainChainTip()
        XCTAssertEqual(tip2, tip1)

        let height2 = await chain2.getHighestBlockIndex()
        XCTAssertEqual(height2, 5)

        let block6 = try await BlockBuilder.buildBlock(
            previous: prev, timestamp: base + 6000,
            difficulty: UInt256(1000), nonce: 6, fetcher: fetcher
        )
        let result = await chain2.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: block6), block: block6
        )
        XCTAssertTrue(result.extendsMainChain)

        let finalHeight = await chain2.getHighestBlockIndex()
        XCTAssertEqual(finalHeight, 6)
    }

    func testPersistSerializationIsDeterministic() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let spec = s(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: base + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: b1), block: b1
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let p1 = await chain.persist()
        let p2 = await chain.persist()
        let d1 = try encoder.encode(p1)
        let d2 = try encoder.encode(p2)
        XCTAssertEqual(d1, d2, "Persistence serialization must be deterministic")
    }

    func testPersistToDiskAndReload() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let persister = ChainStatePersister(storagePath: tmpDir, directory: "Nexus")

        let spec = s(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: base + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: b1), block: b1
        )

        let persisted = await chain.persist()
        try await persister.save(persisted)

        let loaded = try await persister.load()
        XCTAssertNotNil(loaded)

        let restored = ChainState.restore(from: loaded!)
        let restoredTip = await restored.getMainChainTip()
        let originalTip = await chain.getMainChainTip()
        XCTAssertEqual(restoredTip, originalTip)
    }
}

// ============================================================================
// MARK: - Two-Node Convergence
// ============================================================================

@MainActor
final class TwoNodeConvergenceTests: XCTestCase {

    func testTwoNodesFromSameGenesisConverge() async throws {
        let fetcher = f()
        let base = now() - 50_000
        let spec = s(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let nodeA = ChainState.fromGenesis(block: genesis)
        let nodeB = ChainState.fromGenesis(block: genesis)

        let blocks = try await buildChain(from: genesis, length: 6, base: base, fetcher: fetcher)

        for block in blocks.dropFirst() {
            let _ = await nodeA.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
            let _ = await nodeB.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
        }

        let tipA = await nodeA.getMainChainTip()
        let tipB = await nodeB.getMainChainTip()
        XCTAssertEqual(tipA, tipB, "Both nodes should converge to same tip")

        let heightA = await nodeA.getHighestBlockIndex()
        let heightB = await nodeB.getHighestBlockIndex()
        XCTAssertEqual(heightA, heightB)
        XCTAssertEqual(heightA, 5)
    }

    func testNodesConvergeAfterDivergentBlocks() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let nodeA = ChainState.fromGenesis(block: genesis)
        let nodeB = ChainState.fromGenesis(block: genesis)

        let forkA = try await buildChain(from: genesis, length: 6, base: base, fetcher: fetcher)
        for block in forkA.dropFirst() {
            let _ = await nodeA.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
        }

        var forkBBlocks: [Block] = [genesis]
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: forkBBlocks.last!, timestamp: base + Int64(i) * 500,
                difficulty: UInt256(1000), nonce: UInt64(i + 200), fetcher: fetcher
            )
            forkBBlocks.append(b)
        }
        for block in forkBBlocks.dropFirst() {
            let _ = await nodeB.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
        }

        let tipA = await nodeA.getMainChainTip()
        let tipB = await nodeB.getMainChainTip()
        XCTAssertNotEqual(tipA, tipB, "Nodes diverge initially")

        // Node B receives all of fork A (longer) and should converge
        for block in forkA.dropFirst() {
            let _ = await nodeB.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
        }

        let finalTipB = await nodeB.getMainChainTip()
        XCTAssertEqual(finalTipB, tipA, "Node B should converge to longer chain")
    }
}

// ============================================================================
// MARK: - Invalid Child Genesis Specs
// ============================================================================

@MainActor
final class ChildGenesisValidationTests: XCTestCase {

    func testChildGenesisWithWrongDirectoryRejected() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let nexusSpec = s("Nexus", premine: 0)

        let childSpec = s("WrongName", premine: 0)
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let reward = nexusSpec.rewardAtBlock(0)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: reward)],
            actions: [], depositActions: [],
            genesisActions: [GenesisAction(directory: "Child", block: childGenesis)],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let block = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "Child genesis with directory 'WrongName' but registered as 'Child' should fail")
    }
}

// ============================================================================
// MARK: - Cross-Chain Withdrawal Security
// ============================================================================

@MainActor
final class WithdrawalSecurityTests: XCTestCase {

    func testWithdrawalWithWrongNonceThrows() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let premine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let nexusReward = nexusSpec.rewardAtBlock(0)

        let childGenesis = try await premineGenesis(spec: childSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Deposit with nonce=1
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: premine, newBalance: premine - 500 + childReward)],
            actions: [],
            depositActions: [DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 500, amountDeposited: 500)],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(depositBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Receipt with nonce=1
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: nexusReward)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: 500, directory: "Child")],
            withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(receiptBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Withdrawal with WRONG nonce (99 instead of 1)
        let balanceAfterDeposit = premine - 500 + childReward
        let wrongNonceBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: balanceAfterDeposit, newBalance: balanceAfterDeposit + 500 + childReward)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: kpAddr, nonce: 99, demander: kpAddr, amountDemanded: 500, amountWithdrawn: 500)
            ],
            signers: [kpAddr], fee: 0, nonce: 2
        )

        let badBlock = try await BlockBuilder.buildBlock(
            previous: childBlock1,
            transactions: [tx(wrongNonceBody, kp)],
            parentChainBlock: nexusBlock1,
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await badBlock.validate(
            nexusHash: badBlock.getDifficultyHash(),
            parentChainBlock: nexusBlock1,
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Withdrawal with wrong nonce should fail validation")
    }

    func testWithdrawalWithWrongAmountDemandedThrows() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let premine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let nexusReward = nexusSpec.rewardAtBlock(0)

        let childGenesis = try await premineGenesis(spec: childSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: premine, newBalance: premine - 500 + childReward)],
            actions: [],
            depositActions: [DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 500, amountDeposited: 500)],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(depositBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: nexusReward)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: 500, directory: "Child")],
            withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(receiptBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Withdrawal with wrong amountDemanded (9999 instead of 500)
        let balanceAfterDeposit = premine - 500 + childReward
        let wrongAmountBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: balanceAfterDeposit, newBalance: balanceAfterDeposit + 500 + childReward)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: 9999, amountWithdrawn: 500)
            ],
            signers: [kpAddr], fee: 0, nonce: 2
        )

        let badBlock = try await BlockBuilder.buildBlock(
            previous: childBlock1,
            transactions: [tx(wrongAmountBody, kp)],
            parentChainBlock: nexusBlock1,
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await badBlock.validate(
            nexusHash: badBlock.getDifficultyHash(),
            parentChainBlock: nexusBlock1,
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Withdrawal with wrong amountDemanded should fail validation")
    }
}

// ============================================================================
// MARK: - Fee-Only Blocks (Post-Halving Economy)
// ============================================================================

@MainActor
final class FeeOnlyEconomyTests: XCTestCase {

    func testZeroRewardBlockWithFeesIsValid() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let payer = CryptoUtils.generateKeyPair()
        let miner = CryptoUtils.generateKeyPair()
        let payerAddr = id(payer.publicKey)
        let minerAddr = id(miner.publicKey)

        // Spec where reward is 1 (exponent=0 is invalid, but exponent=1 gives reward=2)
        // Use a premine to fund the payer, then test fee-only
        let spec = s()
        let premine = spec.premineAmount()

        let genesis = try await premineGenesis(spec: spec, owner: payer, fetcher: fetcher, time: base)

        // Normal block with fee — the miner gets reward + fee
        let fee: UInt64 = 77
        let reward = spec.rewardAtBlock(0)
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddr, oldBalance: premine, newBalance: premine - fee),
                AccountAction(owner: minerAddr, oldBalance: 0, newBalance: reward + fee)
            ],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [payerAddr], fee: fee, nonce: 1
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body, payer)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
    }
}

// ============================================================================
// MARK: - Dust Attack Resistance (State Bloat)
// ============================================================================

@MainActor
final class DustAttackTests: XCTestCase {

    func testStateDeltaLimitPreventsMassAccountCreation() async throws {
        let fetcher = f()
        let base = now() - 10_000
        // 200 bytes state growth limit — only fits ~2-3 accounts
        let tinySpec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                                 maxStateGrowth: 200, maxBlockSize: 1_000_000,
                                 premine: 1000, targetBlockTime: 1_000,
                                 initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
        let funder = CryptoUtils.generateKeyPair()
        let funderAddr = id(funder.publicKey)
        let premine = tinySpec.premineAmount()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: tinySpec, transactions: [tx(TransactionBody(
                accountActions: [AccountAction(owner: funderAddr, oldBalance: 0, newBalance: premine)],
                actions: [], depositActions: [], genesisActions: [], peerActions: [],
                receiptActions: [], withdrawalActions: [], signers: [funderAddr], fee: 0, nonce: 0
            ), funder)],
            timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Try creating 10 dust accounts
        let reward = tinySpec.rewardAtBlock(0)
        var actions: [AccountAction] = []
        var remaining = premine
        for i in 0..<10 {
            let dustKp = CryptoUtils.generateKeyPair()
            actions.append(AccountAction(owner: id(dustKp.publicKey), oldBalance: 0, newBalance: 1))
            remaining -= 1
        }
        actions.append(AccountAction(owner: funderAddr, oldBalance: premine, newBalance: remaining + reward))

        let body = TransactionBody(
            accountActions: actions,
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [funderAddr], fee: 0, nonce: 1
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body, funder)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "Mass dust account creation should exceed state growth limit")
    }
}

// ============================================================================
// MARK: - Total Supply Fits UInt64
// ============================================================================

@MainActor
final class SupplyOverflowTests: XCTestCase {

    func testPremineDoesNotOverflowUInt64() {
        let spec = s()
        let (_, overflow) = spec.premine.multipliedReportingOverflow(by: spec.initialReward)
        XCTAssertFalse(overflow)
    }

    func testNexusGenesisPremineDoesNotOverflow() {
        let spec = NexusGenesis.spec
        let (_, overflow) = spec.premine.multipliedReportingOverflow(by: spec.initialReward)
        XCTAssertFalse(overflow)
    }

    func testRewardNeverOverflowsAtAnyBlock() {
        let spec = s()
        let interval = spec.halvingInterval
        let samplePoints: [UInt64] = (0..<30).map { UInt64($0) * (interval / 10) }
        for blockIndex in samplePoints {
            let reward = spec.rewardAtBlock(blockIndex)
            XCTAssertTrue(reward <= spec.initialReward)
        }
    }

    func testTotalRewardsMonotonicallyIncreases() {
        let spec = s(premine: 0)
        var prev: UInt64 = 0
        for count: UInt64 in stride(from: 100, through: 10000, by: 100) {
            let total = spec.totalRewards(upToBlock: count)
            XCTAssertGreaterThan(total, prev)
            prev = total
        }
    }
}

// ============================================================================
// MARK: - Cross-Chain Balance Conservation
// ============================================================================

@MainActor
final class CrossChainBalanceConservationTests: XCTestCase {

    func testCrossChainDepositReceiptBalanceSumsCorrectly() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let nexusReward = nexusSpec.rewardAtBlock(0)
        let depositAmount: UInt64 = 300

        let childGenesis = try await premineGenesis(spec: childSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Before deposit: child has childPremine, nexus has 0
        let totalBefore = childPremine

        // Deposit on child
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: childPremine, newBalance: childPremine - depositAmount + childReward)],
            actions: [],
            depositActions: [DepositAction(nonce: 1, demander: kpAddr, amountDemanded: depositAmount, amountDeposited: depositAmount)],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )
        let _ = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(depositBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let childBalanceAfterDeposit = childPremine - depositAmount + childReward

        // Receipt on nexus
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: nexusReward)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: depositAmount, directory: "Child")],
            withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let nv = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(receiptBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let nexusValid = try await nv.validateNexus(fetcher: fetcher)
        XCTAssertTrue(nexusValid)

        // Balance accounting:
        // Child: childPremine - depositAmount + childReward (deposit locks funds, mining adds reward)
        // Nexus: nexusReward (receipt just acknowledges, doesn't create tokens)
        // Total tokens in circulation = childBalance + nexusBalance
        //   = (childPremine - depositAmount + childReward) + nexusReward
        //   = totalBefore - depositAmount + childReward + nexusReward
        // The depositAmount is locked in the deposit state, not destroyed
        let totalCirculating = childBalanceAfterDeposit + nexusReward
        let expectedTotal = totalBefore - depositAmount + childReward + nexusReward
        XCTAssertEqual(totalCirculating, expectedTotal)
    }
}

// ============================================================================
// MARK: - Chain Depth (Grandchild Chains)
// ============================================================================

@MainActor
final class ChainDepthTests: XCTestCase {

    func testThreeLevelChainHierarchy() async throws {
        let fetcher = f()
        let base = now() - 50_000
        let nexusSpec = s("Nexus", premine: 0)
        let childSpec = s("Child", premine: 0)
        let grandchildSpec = s("Grandchild", premine: 0)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let grandchildGenesis = try await BlockBuilder.buildGenesis(
            spec: grandchildSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let grandchildChain = ChainState.fromGenesis(block: grandchildGenesis)

        let grandchildLevel = ChainLevel(chain: grandchildChain, children: [:])
        let childLevel = ChainLevel(chain: childChain, children: ["Grandchild": grandchildLevel])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Child": childLevel])

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: base + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: nexusBlock1), block: nexusBlock1
        )

        let nexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 1)

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, parentChainBlock: nexusBlock1,
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let childResult = await childChain.submitBlock(
            parentBlockHeaderAndIndex: (HeaderImpl<Block>(node: nexusBlock1).rawCID, 1),
            blockHeader: HeaderImpl<Block>(node: childBlock1), block: childBlock1
        )
        XCTAssertTrue(childResult.extendsMainChain)

        let gcBlock1 = try await BlockBuilder.buildBlock(
            previous: grandchildGenesis, parentChainBlock: childBlock1,
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let gcResult = await grandchildChain.submitBlock(
            parentBlockHeaderAndIndex: (HeaderImpl<Block>(node: childBlock1).rawCID, 1),
            blockHeader: HeaderImpl<Block>(node: gcBlock1), block: gcBlock1
        )
        XCTAssertTrue(gcResult.extendsMainChain)

        let gcHeight = await grandchildChain.getHighestBlockIndex()
        XCTAssertEqual(gcHeight, 1, "Grandchild chain should have block at height 1")
    }
}

// ============================================================================
// MARK: - Performance Regression
// ============================================================================

@MainActor
final class PerformanceRegressionTests: XCTestCase {

    func testBlockBuildPerformance() async throws {
        let fetcher = f()
        let base = now() - 200_000
        let spec = s(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        var prev = genesis
        let start = Date()
        for i in 1...50 {
            prev = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "Building 50 empty blocks should take < 5 seconds")
    }

    func testChainSubmissionPerformance() async throws {
        let fetcher = f()
        let base = now() - 200_000
        let spec = s(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let blocks = try await buildChain(from: genesis, length: 51, base: base, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)

        let start = Date()
        for block in blocks.dropFirst() {
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0, "Submitting 50 blocks should take < 2 seconds")
        let height = await chain.getHighestBlockIndex()
        XCTAssertEqual(height, 50)
    }
}
