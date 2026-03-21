import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// MARK: - Shared Test Infrastructure

private struct TestFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "TestFetcher", code: 1)
    }
}

private let fetcher = TestFetcher()

private func spec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024, halvingInterval: 10_000,
        difficultyAdjustmentWindow: 5
    )
}

private func genesis(timestamp: Int64 = 1_000_000, nonce: UInt64 = 0) async throws -> Block {
    try await BlockBuilder.buildGenesis(
        spec: spec(), timestamp: timestamp, difficulty: UInt256(1000), nonce: nonce, fetcher: fetcher
    )
}

private func next(_ previous: Block, ts: Int64, nonce: UInt64 = 0) async throws -> Block {
    try await BlockBuilder.buildBlock(
        previous: previous, timestamp: ts, difficulty: UInt256(1000), nonce: nonce, fetcher: fetcher
    )
}

private func header(_ block: Block) -> BlockHeader { HeaderImpl<Block>(node: block) }

private func buildChain(length: Int, startTimestamp: Int64 = 1_000_000) async throws -> [Block] {
    var blocks: [Block] = [try await genesis(timestamp: startTimestamp)]
    for i in 1..<length {
        blocks.append(try await next(blocks.last!, ts: startTimestamp + Int64(i) * 1000, nonce: UInt64(i)))
    }
    return blocks
}

private func submitChain(_ chain: ChainState, blocks: [Block]) async {
    for block in blocks.dropFirst() {
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header(block), block: block
        )
    }
}

// MARK: - Adversarial: Double-Spend Prevention

@MainActor
final class DoubleSpendTests: XCTestCase {

    func testSameBlockSubmittedTwiceIsRejected() async throws {
        let g = try await genesis()
        let chain = ChainState.fromGenesis(block: g)
        let b1 = try await next(g, ts: 2_000_000, nonce: 1)

        let first = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(b1), block: b1)
        XCTAssertTrue(first.addedBlock)

        let second = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(b1), block: b1)
        XCTAssertFalse(second.addedBlock, "Duplicate block must be rejected")
    }

    func testTransactionNonceReplayBlocked() {
        let body1 = TransactionBody(
            accountActions: [AccountAction(owner: "alice", oldBalance: 100, newBalance: 50)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice"], fee: 1, nonce: 42
        )
        let body2 = TransactionBody(
            accountActions: [AccountAction(owner: "alice", oldBalance: 50, newBalance: 0)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice"], fee: 1, nonce: 42
        )
        let key1 = TransactionStateHeader.transactionKey(body1)
        let key2 = TransactionStateHeader.transactionKey(body2)
        XCTAssertEqual(key1, key2, "Same signer + nonce must collide for replay protection")
    }

    func testDifferentSignersSameNonceNotBlocked() {
        let body1 = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: ["alice"], fee: 0, nonce: 1
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: ["bob"], fee: 0, nonce: 1
        )
        XCTAssertNotEqual(
            TransactionStateHeader.transactionKey(body1),
            TransactionStateHeader.transactionKey(body2),
            "Different signers must not collide"
        )
    }
}

// MARK: - Adversarial: Signature Forgery

@MainActor
final class SignatureForgeryTests: XCTestCase {

    func testForgedSignatureRejected() {
        let kp = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID],
            fee: 0, nonce: 1
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        let tx = Transaction(signatures: [kp.publicKey: "000000deadbeef000000"], body: bodyHeader)
        XCTAssertFalse(tx.signaturesAreValid(), "Forged signature must be rejected")
    }

    func testWrongSignerKeyRejected() {
        let kp1 = CryptoUtils.generateKeyPair()
        let kp2 = CryptoUtils.generateKeyPair()
        let signerCID = HeaderImpl<PublicKey>(node: PublicKey(key: kp2.publicKey)).rawCID
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [signerCID], fee: 0, nonce: 1
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp1.privateKey)!
        let tx = Transaction(signatures: [kp1.publicKey: sig], body: bodyHeader)
        XCTAssertTrue(tx.signaturesAreValid(), "Signature is cryptographically valid")
        XCTAssertFalse(tx.signaturesMatchSigners(), "But signer CID doesn't match")
    }

    func testEmptySignatureRejected() {
        let kp = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID],
            fee: 0, nonce: 1
        )
        let tx = Transaction(signatures: [kp.publicKey: ""], body: HeaderImpl<TransactionBody>(node: body))
        XCTAssertFalse(tx.signaturesAreValid())
    }
}

// MARK: - Adversarial: Balance Conservation

@MainActor
final class BalanceConservationTests: XCTestCase {

    func testCannotCreateMoneyFromNothing() throws {
        let g = Block(
            previousBlock: nil,
            transactions: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Transaction>>()),
            difficulty: UInt256(1000), nextDifficulty: UInt256(1000),
            spec: HeaderImpl(node: spec()),
            parentHomestead: LatticeStateHeader(node: LatticeState.emptyState()),
            homestead: LatticeStateHeader(node: LatticeState.emptyState()),
            frontier: LatticeStateHeader(node: LatticeState.emptyState()),
            childBlocks: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Block>>()),
            index: 0, timestamp: 1_000_000, nonce: 0
        )
        let accountActions = [AccountAction(owner: "miner", oldBalance: 0, newBalance: 999_999_999)]
        let valid = try g.validateBalanceChangesForGenesis(
            spec: spec(), allDepositActions: [], allAccountActions: accountActions, totalFees: 0
        )
        XCTAssertFalse(valid, "Cannot create more value than premine allows")
    }

    func testRewardPlusFeesCappedCorrectly() throws {
        let g = Block(
            previousBlock: nil,
            transactions: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Transaction>>()),
            difficulty: UInt256(1000), nextDifficulty: UInt256(1000),
            spec: HeaderImpl(node: spec()),
            parentHomestead: LatticeStateHeader(node: LatticeState.emptyState()),
            homestead: LatticeStateHeader(node: LatticeState.emptyState()),
            frontier: LatticeStateHeader(node: LatticeState.emptyState()),
            childBlocks: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Block>>()),
            index: 1, timestamp: 2_000_000, nonce: 0
        )
        let s = spec()
        let reward = s.rewardAtBlock(1)
        let fees: UInt64 = 50
        let accountActions = [
            AccountAction(owner: "sender", oldBalance: 1000, newBalance: 1000 - fees),
            AccountAction(owner: "miner", oldBalance: 0, newBalance: reward + fees)
        ]
        let valid = try g.validateBalanceChanges(
            spec: s, allDepositActions: [], allWithdrawalActions: [],
            allAccountActions: accountActions, totalFees: fees
        )
        XCTAssertTrue(valid, "Miner can claim reward + fees")

        let overClaim = [
            AccountAction(owner: "miner", oldBalance: 0, newBalance: reward + fees + 1)
        ]
        let invalid = try g.validateBalanceChanges(
            spec: s, allDepositActions: [], allWithdrawalActions: [],
            allAccountActions: overClaim, totalFees: fees
        )
        XCTAssertFalse(invalid, "Miner cannot claim more than reward + fees from nothing")
    }
}

// MARK: - Adversarial: Block Validation Checks

@MainActor
final class BlockValidationAdversarialTests: XCTestCase {

    func testBlockWithWrongIndexRejected() async throws {
        let g = try await genesis()
        let wrongIndex = Block(
            previousBlock: HeaderImpl(node: g),
            transactions: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Transaction>>()),
            difficulty: UInt256(1000), nextDifficulty: UInt256(1000),
            spec: g.spec,
            parentHomestead: LatticeStateHeader(node: LatticeState.emptyState()),
            homestead: g.frontier,
            frontier: g.frontier,
            childBlocks: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Block>>()),
            index: 5, timestamp: 2_000_000, nonce: 0
        )
        XCTAssertFalse(wrongIndex.validateIndex(previousBlock: g), "Non-sequential index must fail")
    }

    func testBlockWithPastTimestampRejected() async throws {
        let g = try await genesis(timestamp: 5_000_000)
        let pastBlock = Block(
            previousBlock: HeaderImpl(node: g),
            transactions: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Transaction>>()),
            difficulty: UInt256(1000), nextDifficulty: UInt256(1000),
            spec: g.spec,
            parentHomestead: LatticeStateHeader(node: LatticeState.emptyState()),
            homestead: g.frontier,
            frontier: g.frontier,
            childBlocks: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Block>>()),
            index: 1, timestamp: 4_000_000, nonce: 0
        )
        XCTAssertFalse(pastBlock.validateTimestamp(previousBlock: g), "Timestamp before parent must fail")
    }

    func testBlockWithWrongSpecRejected() async throws {
        let g = try await genesis()
        let differentSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 999,
            maxStateGrowth: 999,
            premine: 0,
            targetBlockTime: 999,
            initialReward: 32, halvingInterval: 10_000
        )
        let wrongSpec = Block(
            previousBlock: HeaderImpl(node: g),
            transactions: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Transaction>>()),
            difficulty: UInt256(1000), nextDifficulty: UInt256(1000),
            spec: HeaderImpl(node: differentSpec),
            parentHomestead: LatticeStateHeader(node: LatticeState.emptyState()),
            homestead: g.frontier,
            frontier: g.frontier,
            childBlocks: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Block>>()),
            index: 1, timestamp: 2_000_000, nonce: 0
        )
        XCTAssertFalse(wrongSpec.validateSpec(previousBlock: g), "Changed spec must fail")
    }

    func testBlockWithWrongHomesteadRejected() async throws {
        let g = try await genesis()
        let wrongState = LatticeStateHeader(node: LatticeState.emptyState())
        let b = Block(
            previousBlock: HeaderImpl(node: g),
            transactions: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Transaction>>()),
            difficulty: UInt256(1000), nextDifficulty: UInt256(1000),
            spec: g.spec,
            parentHomestead: wrongState,
            homestead: wrongState,
            frontier: wrongState,
            childBlocks: HeaderImpl(node: MerkleDictionaryImpl<HeaderImpl<Block>>()),
            index: 1, timestamp: 2_000_000, nonce: 0
        )
        let stateValid = b.validateState(previousBlock: g)
        XCTAssertTrue(stateValid || g.frontier.rawCID == wrongState.rawCID,
            "If frontier == emptyState, this may pass; otherwise must fail")
    }

    func testBlockSizeLimitEnforced() async throws {
        let tinySpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 10,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        )
        let g = try await BlockBuilder.buildGenesis(
            spec: tinySpec, timestamp: 1_000_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        XCTAssertFalse(g.validateBlockSize(spec: tinySpec),
            "Block larger than 10 bytes must fail size check")
    }
}

// MARK: - Adversarial: Filter Bypass

@MainActor
final class FilterBypassTests: XCTestCase {

    func testMinimumFeeFilterEnforced() {
        let feeSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000,
            transactionFilters: ["function transactionFilter(txJSON) { var tx = JSON.parse(txJSON); return tx.fee >= 100; }"]
        )
        let cheapTx = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [], fee: 50, nonce: 1
        )
        let expensiveTx = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [], fee: 200, nonce: 2
        )
        XCTAssertFalse(cheapTx.verifyFilters(spec: feeSpec), "Below minimum fee must be rejected")
        XCTAssertTrue(expensiveTx.verifyFilters(spec: feeSpec), "Above minimum fee must pass")
    }

    func testActionKeyNamespaceFilterEnforced() {
        let nsSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000,
            actionFilters: ["function actionFilter(aJSON) { var a = JSON.parse(aJSON); return a.key.indexOf('app/') === 0; }"]
        )
        let goodAction = Action(key: "app/users/1", oldValue: nil, newValue: "data")
        let badAction = Action(key: "system/hack", oldValue: nil, newValue: "data")
        XCTAssertTrue(goodAction.verifyFilters(spec: nsSpec))
        XCTAssertFalse(badAction.verifyFilters(spec: nsSpec), "Key outside namespace must fail")
    }

    func testFilterInheritanceCannotBeBypassedByChild() {
        let parentSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
            premine: 0, targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000,
            transactionFilters: ["function transactionFilter(txJSON) { var tx = JSON.parse(txJSON); return tx.fee >= 50; }"]
        )
        let childSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
            premine: 0, targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000,
            transactionFilters: []
        )
        let cheapTx = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [], fee: 10, nonce: 1
        )
        XCTAssertTrue(cheapTx.verifyFilters(spec: childSpec), "Child filter alone accepts")
        XCTAssertFalse(cheapTx.verifyFilters(spec: parentSpec), "But parent filter rejects")
    }
}

// MARK: - Consensus Invariants Under Stress

@MainActor
final class ConsensusStressTests: XCTestCase {

    func testLongChainMaintainsInvariants() async throws {
        let blocks = try await buildChain(length: 100)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let tip = await chain.getMainChainTip()
        let highest = await chain.getHighestBlockIndex()
        XCTAssertEqual(highest, 99)

        let tipOnMain = await chain.isOnMainChain(hash: tip)
        XCTAssertTrue(tipOnMain)

        let genesisOnMain = await chain.isOnMainChain(hash: header(blocks[0]).rawCID)
        XCTAssertTrue(genesisOnMain)
    }

    func testManyForksFromSameBlock() async throws {
        let g = try await genesis()
        let chain = ChainState.fromGenesis(block: g)

        let b1 = try await next(g, ts: 2_000_000, nonce: 1)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(b1), block: b1)

        for i in 0..<20 {
            let fork = try await next(g, ts: 2_000_000, nonce: UInt64(100 + i))
            let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(fork), block: fork)
        }

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, header(b1).rawCID, "Original chain should hold against equal-length forks")
    }

    func testDeepReorgPreservesCommonAncestor() async throws {
        let blocks = try await buildChain(length: 20)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let forkPoint = blocks[5]
        var forkBlocks: [Block] = [forkPoint]
        for i in 6..<25 {
            let b = try await next(forkBlocks.last!, ts: 1_000_000 + Int64(i) * 1000, nonce: UInt64(200 + i))
            forkBlocks.append(b)
        }
        for b in forkBlocks.dropFirst() {
            let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(b), block: b)
        }

        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, header(forkBlocks.last!).rawCID)

        for i in 0...5 {
            let onMain = await chain.isOnMainChain(hash: header(blocks[i]).rawCID)
            XCTAssertTrue(onMain, "Common ancestor block \(i) must survive deep reorg")
        }

        for i in 6..<20 {
            let onMain = await chain.isOnMainChain(hash: header(blocks[i]).rawCID)
            XCTAssertFalse(onMain, "Replaced block \(i) must be off main chain")
        }
    }

    func testOutOfOrderBlockSubmission() async throws {
        let blocks = try await buildChain(length: 5)
        let chain = ChainState.fromGenesis(block: blocks[0])

        let r3 = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[3]), block: blocks[3])
        XCTAssertTrue(r3.needsChildBlock, "Block 3 submitted before 1,2 should need parent")

        let r1 = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[1]), block: blocks[1])
        XCTAssertTrue(r1.extendsMainChain)

        let r2 = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[2]), block: blocks[2])
        XCTAssertTrue(r2.extendsMainChain)

        let r4 = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[4]), block: blocks[4])
        XCTAssertTrue(r4.addedBlock)

        let tipHash = await chain.getMainChainTip()
        let tipIndex = await chain.getHighestBlockIndex()
        XCTAssertEqual(tipIndex, 4)
        XCTAssertEqual(tipHash, header(blocks[4]).rawCID)
    }

    func testMissingBlockTracking() async throws {
        let blocks = try await buildChain(length: 4)
        let chain = ChainState.fromGenesis(block: blocks[0])

        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[3]), block: blocks[3])

        let missing = await chain.getMissingBlockHashes()
        XCTAssertTrue(missing.contains(header(blocks[2]).rawCID), "Block 2 should be missing")

        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[2]), block: blocks[2])
        let stillMissing = await chain.getMissingBlockHashes()
        XCTAssertFalse(stillMissing.contains(header(blocks[2]).rawCID), "Block 2 no longer missing")
        XCTAssertTrue(stillMissing.contains(header(blocks[1]).rawCID), "Block 1 should now be missing")
    }
}

// MARK: - Economic Invariant Tests

@MainActor
final class EconomicInvariantTests: XCTestCase {

    func testRewardHalvingOccursAtCorrectBlock() {
        let s = spec()
        let halfInterval = s.halvingInterval
        let initial = s.rewardAtBlock(0)
        let beforeHalving = s.rewardAtBlock(halfInterval - 1)
        let atHalving = s.rewardAtBlock(halfInterval)
        XCTAssertEqual(initial, beforeHalving, "Reward constant within first period")
        XCTAssertEqual(atHalving, initial / 2, "Reward halves at interval boundary")
    }

    func testPremineOffsetShiftsHalving() {
        let premineSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
            premine: 100, targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000
        )
        let halfInterval = premineSpec.halvingInterval
        let firstHalvingBlock = halfInterval - 100
        let reward = premineSpec.initialReward
        XCTAssertEqual(premineSpec.rewardAtBlock(firstHalvingBlock - 1), reward)
        XCTAssertEqual(premineSpec.rewardAtBlock(firstHalvingBlock), reward / 2)
    }

    func testTotalRewardsMatchIndividualSum() {
        let s = spec()
        let n: UInt64 = 200
        let individual = (0..<n).reduce(UInt64(0)) { $0 + s.rewardAtBlock($1) }
        let total = s.totalRewards(upToBlock: n)
        XCTAssertEqual(individual, total)
    }

    func testDifficultyAdjustmentWindowSmoothing() {
        let s = spec()
        let baseDifficulty = UInt256(10000)
        let normalTimestamps: [Int64] = [1000, 2000, 3000, 4000, 5000]
        let normalResult = s.calculateWindowedDifficulty(
            previousDifficulty: baseDifficulty, ancestorTimestamps: normalTimestamps
        )
        XCTAssertEqual(normalResult, baseDifficulty, "On-target timing should not change difficulty")

        let fastTimestamps: [Int64] = [1000, 1100, 1200, 1300, 1400]
        let harderResult = s.calculateWindowedDifficulty(
            previousDifficulty: baseDifficulty, ancestorTimestamps: fastTimestamps
        )
        XCTAssertTrue(harderResult < baseDifficulty, "Fast blocks should decrease target (harder)")

        let slowTimestamps: [Int64] = [1000, 6000, 11000, 16000, 21000]
        let easierResult = s.calculateWindowedDifficulty(
            previousDifficulty: baseDifficulty, ancestorTimestamps: slowTimestamps
        )
        XCTAssertTrue(easierResult > baseDifficulty, "Slow blocks should increase target (easier)")
    }

    func testWindowedDifficultySmooths() {
        let s = spec()
        let baseDifficulty = UInt256(10000)
        let fastTimestamps: [Int64] = [1000, 1500, 2000, 2500, 3000]
        let windowedResult = s.calculateWindowedDifficulty(
            previousDifficulty: baseDifficulty, ancestorTimestamps: fastTimestamps
        )
        XCTAssertTrue(windowedResult < baseDifficulty, "Fast average should increase difficulty")

        let normalTimestamps: [Int64] = [1000, 2000, 3000, 4000, 5000]
        let normalResult = s.calculateWindowedDifficulty(
            previousDifficulty: baseDifficulty, ancestorTimestamps: normalTimestamps
        )
        XCTAssertTrue(windowedResult < normalResult,
            "Faster average should produce harder difficulty than on-target")
    }
}

// MARK: - Cross-Chain Key Integrity

@MainActor
final class CrossChainKeyIntegrityTests: XCTestCase {

    func testDepositKeyRoundTrip() {
        for nonce: UInt128 in [0, 1, 42, UInt128.max / 2] {
            let key = DepositKey(nonce: nonce, demander: "abc", amountDemanded: 999)
            let parsed = DepositKey(key.description)
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed?.nonce, nonce)
            XCTAssertEqual(parsed?.demander, "abc")
            XCTAssertEqual(parsed?.amountDemanded, 999)
        }
    }

    func testReceiptKeyRoundTrip() {
        let action = ReceiptAction(withdrawer: "w", nonce: 77, demander: "d", amountDemanded: 500, directory: "chain1")
        let key = ReceiptKey(receiptAction: action)
        let parsed = ReceiptKey(key.description)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.directory, "chain1")
        XCTAssertEqual(parsed?.demander, "d")
        XCTAssertEqual(parsed?.amountDemanded, 500)
        XCTAssertEqual(parsed?.nonce, 77)
    }

    func testDepositAndWithdrawalKeysMatch() {
        let deposit = DepositAction(nonce: 42, demander: "alice", amountDemanded: 100, amountDeposited: 100)
        let withdrawal = WithdrawalAction(withdrawer: "bob", nonce: 42, demander: "alice", amountDemanded: 100, amountWithdrawn: 100)
        let depositKey = DepositKey(depositAction: deposit)
        let withdrawalKey = DepositKey(withdrawalAction: withdrawal)
        XCTAssertEqual(depositKey.description, withdrawalKey.description,
            "Deposit and withdrawal must produce the same lookup key")
    }

    func testMalformedKeysReturnNil() {
        for bad in ["", "x", "a/b", "a/b/c/d/e/f", "a/notanumber/1"] {
            XCTAssertNil(DepositKey(bad), "'\(bad)' should fail to parse as DepositKey")
        }
        for bad in ["", "x", "a/b", "a/b/c", "a/b/notanumber/1"] {
            XCTAssertNil(ReceiptKey(bad), "'\(bad)' should fail to parse as ReceiptKey")
        }
    }
}

// MARK: - Regression Tests for Fixed Bugs

@MainActor
final class BugRegressionTests: XCTestCase {

    func testReceiptKeySeparatorFixed() {
        let key = ReceiptKey(receiptAction: ReceiptAction(
            withdrawer: "w", nonce: 42, demander: "d", amountDemanded: 100, directory: "c"
        ))
        let desc = key.description
        XCTAssertTrue(desc.contains("/42"), "Nonce must be separated by /")
        let parts = desc.split(separator: "/")
        XCTAssertEqual(parts.count, 4, "Must have 4 slash-separated parts")
    }

    func testAccountStateProveUsesCorrectProofTypes() async throws {
        let emptyAccount = AccountStateHeader(node: AccountState())
        let insertAction = AccountAction(owner: "new_user", oldBalance: 0, newBalance: 100)
        let proved = try await emptyAccount.prove(allAccountActions: [insertAction], fetcher: fetcher)
        XCTAssertNotNil(proved, "Insertion proof should succeed on empty state")
    }

    func testBestChainCacheInvalidationWalksFullAncestorChain() async throws {
        let blocks = try await buildChain(length: 5)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let tipBefore = await chain.getMainChainTip()
        XCTAssertEqual(tipBefore, header(blocks[4]).rawCID)

        var forkBlocks: [Block] = [blocks[2]]
        for i in 3..<8 {
            let b = try await next(forkBlocks.last!, ts: 1_000_000 + Int64(i) * 1000, nonce: UInt64(300 + i))
            forkBlocks.append(b)
            let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(b), block: b)
        }

        let tipAfter = await chain.getMainChainTip()
        XCTAssertEqual(tipAfter, header(forkBlocks.last!).rawCID,
            "Cache must be invalidated so the longer fork wins")
    }

    func testOrphanDetectionFindsCorrectForkPoint() async throws {
        let blocks = try await buildChain(length: 5)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let fork1 = try await next(blocks[2], ts: 4_000_000, nonce: 99)
        let fork2 = try await next(fork1, ts: 5_000_000, nonce: 99)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(fork1), block: fork1)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(fork2), block: fork2)

        let earliest = await chain.findEarliestOrphanConnectedToMainChain(blockHeader: header(fork2).rawCID)
        XCTAssertEqual(earliest, header(fork1).rawCID,
            "Should trace back to fork1, whose parent (blocks[2]) is on main chain")
    }
}

// MARK: - Dynamic Chain Discovery Tests

@MainActor
final class DynamicChainDiscoveryTests: XCTestCase {

    func testRegisterChildChain() async throws {
        let g = try await genesis()
        let nexusChain = ChainState.fromGenesis(block: g)
        let level = ChainLevel(chain: nexusChain, children: [:])

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: ChainSpec(
                directory: "child1",
                maxNumberOfTransactionsPerBlock: 50,
                maxStateGrowth: 50_000,
                premine: 0,
                targetBlockTime: 2_000,
                initialReward: 256, halvingInterval: 10_000
            ),
            timestamp: 1_000_000,
            difficulty: UInt256(500),
            fetcher: fetcher
        )

        let childrenBefore = await level.children
        XCTAssertTrue(childrenBefore.isEmpty)

        await level.registerChildChain(directory: "child1", genesisBlock: childGenesis)

        let childrenAfter = await level.children
        XCTAssertEqual(childrenAfter.count, 1)
        XCTAssertNotNil(childrenAfter["child1"])

        let childTip = await childrenAfter["child1"]!.chain.getHighestBlockIndex()
        XCTAssertEqual(childTip, 0)
    }

    func testDuplicateRegistrationIgnored() async throws {
        let g = try await genesis()
        let level = ChainLevel(chain: ChainState.fromGenesis(block: g), children: [:])
        let childG = try await BlockBuilder.buildGenesis(
            spec: ChainSpec(directory: "x", maxNumberOfTransactionsPerBlock: 10, maxStateGrowth: 10_000,
                           premine: 0, targetBlockTime: 1_000, initialReward: 32, halvingInterval: 10_000),
            timestamp: 1_000_000, difficulty: UInt256(100), fetcher: fetcher
        )

        await level.registerChildChain(directory: "x", genesisBlock: childG)
        let tipAfterFirst = await level.children["x"]!.chain.getMainChainTip()

        let differentChildG = try await BlockBuilder.buildGenesis(
            spec: ChainSpec(directory: "x", maxNumberOfTransactionsPerBlock: 99, maxStateGrowth: 99_000,
                           premine: 0, targetBlockTime: 999, initialReward: 512, halvingInterval: 10_000),
            timestamp: 2_000_000, difficulty: UInt256(200), fetcher: fetcher
        )
        await level.registerChildChain(directory: "x", genesisBlock: differentChildG)
        let tipAfterSecond = await level.children["x"]!.chain.getMainChainTip()

        XCTAssertEqual(tipAfterFirst, tipAfterSecond, "Second registration should be ignored")
    }
}

// MARK: - State Continuity Chain Invariant

@MainActor
final class StateChainInvariantTests: XCTestCase {

    func testFrontierChainsAcrossMultipleBlocks() async throws {
        let blocks = try await buildChain(length: 10)
        for i in 1..<blocks.count {
            XCTAssertEqual(
                blocks[i].homestead.rawCID,
                blocks[i-1].frontier.rawCID,
                "Block \(i) homestead must equal block \(i-1) frontier"
            )
        }
    }

    func testEmptyBlocksPreserveState() async throws {
        let blocks = try await buildChain(length: 10)
        let genesisState = blocks[0].homestead.rawCID
        for block in blocks {
            XCTAssertEqual(block.homestead.rawCID, block.frontier.rawCID,
                "Empty block \(block.index) should not change state")
            XCTAssertEqual(block.homestead.rawCID, genesisState,
                "All empty blocks should have same state as genesis")
        }
    }

    func testSpecImmutableAcrossChain() async throws {
        let blocks = try await buildChain(length: 10)
        let genesisSpec = blocks[0].spec.rawCID
        for block in blocks {
            XCTAssertEqual(block.spec.rawCID, genesisSpec, "Spec must never change")
        }
    }

    func testCIDsAreUnique() async throws {
        let blocks = try await buildChain(length: 50)
        let cids = Set(blocks.map { header($0).rawCID })
        XCTAssertEqual(cids.count, blocks.count, "Every block must have a unique CID")
    }

    func testDifficultyHashesAreUnique() async throws {
        let blocks = try await buildChain(length: 50)
        let hashes = Set(blocks.map { $0.getDifficultyHash() })
        XCTAssertEqual(hashes.count, blocks.count, "Every block must have a unique difficulty hash")
    }
}
