import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

private func f() -> StorableFetcher { StorableFetcher() }

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
    fetcher: StorableFetcher, time: Int64
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

// ============================================================================
// MARK: - 1. Double Withdrawal: Same Deposit Withdrawn Twice
// ============================================================================

@MainActor
final class DoubleWithdrawalTests: XCTestCase {

    func testSameDepositCannotBeWithdrawnTwice() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let premine = childSpec.premineAmount()
        let cr = childSpec.initialReward
        let nr = nexusSpec.rewardAtBlock(0)
        let amount: UInt64 = 500

        let childGenesis = try await premineGenesis(spec: childSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Deposit
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: premine, newBalance: premine - amount + cr)],
            actions: [],
            depositActions: [DepositAction(nonce: 1, demander: kpAddr, amountDemanded: amount, amountDeposited: amount)],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(depositBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let bal1 = premine - amount + cr

        // Receipt on nexus
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: nr)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, directory: "Child")],
            withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(receiptBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // First withdrawal — should succeed
        let w1Body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: bal1, newBalance: bal1 + amount + cr)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, amountWithdrawn: amount)],
            signers: [kpAddr], fee: 0, nonce: 2
        )
        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1,
            transactions: [tx(w1Body, kp)],
            parentChainBlock: nexusBlock1,
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let bal2 = bal1 + amount + cr

        // Second withdrawal of the SAME deposit — should fail
        let w2Body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: bal2, newBalance: bal2 + amount + cr)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, amountWithdrawn: amount)],
            signers: [kpAddr], fee: 0, nonce: 3
        )

        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: childBlock2,
                transactions: [tx(w2Body, kp)],
                parentChainBlock: nexusBlock1,
                timestamp: base + 3000, difficulty: UInt256(1000), nonce: 3, fetcher: fetcher
            )
            XCTFail("Second withdrawal of same deposit should fail — WithdrawalState key already exists")
        } catch {
            // WithdrawalState insertion fails for duplicate DepositKey
        }
    }
}

// ============================================================================
// MARK: - 2. Phantom Receipt: Receipt Without Corresponding Deposit
// ============================================================================

@MainActor
final class PhantomReceiptTests: XCTestCase {

    func testReceiptWithoutDepositBuildSucceedsButWithdrawalCannotProveDeposit() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let premine = childSpec.premineAmount()
        let cr = childSpec.initialReward
        let nr = nexusSpec.rewardAtBlock(0)

        // Child genesis with premine, NO deposit ever made
        let childGenesis = try await premineGenesis(spec: childSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Phantom receipt on nexus (claims deposit nonce=99 which never happened)
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: nr)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 99, demander: kpAddr, amountDemanded: 1000, directory: "Child")],
            withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(receiptBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        // Receipt itself is accepted on nexus (nexus doesn't verify deposit existence)
        let nv = try await nexusBlock1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(nv, "Receipt is accepted on nexus — nexus doesn't cross-verify deposits")

        // But trying to WITHDRAW on child chain fails — deposit doesn't exist in child's deposit state
        let withdrawBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: premine, newBalance: premine + 1000 + cr)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 99, demander: kpAddr, amountDemanded: 1000, amountWithdrawn: 1000)],
            signers: [kpAddr], fee: 0, nonce: 1
        )

        // Build an empty block first to advance child chain (so we have a parent chain reference)
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, timestamp: base + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let badBlock = try await BlockBuilder.buildBlock(
            previous: childBlock1,
            transactions: [tx(withdrawBody, kp)],
            parentChainBlock: nexusBlock1,
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await badBlock.validate(
            nexusHash: badBlock.getDifficultyHash(),
            parentChainBlock: nexusBlock1,
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Withdrawal referencing phantom deposit should fail validation")
    }
}

// ============================================================================
// MARK: - 3. Cross-Chain Replay: Child A Deposit Replayed on Child B
// ============================================================================

@MainActor
final class CrossChainReplayTests: XCTestCase {

    func testDepositOnChildACannotBeWithdrawnOnChildB() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let childASpec = s("ChildA")
        let childBSpec = s("ChildB")
        let nexusSpec = s("Nexus", premine: 0)
        let premineA = childASpec.premineAmount()
        let premineB = childBSpec.premineAmount()
        let crA = childASpec.initialReward
        let nr = nexusSpec.rewardAtBlock(0)
        let amount: UInt64 = 500

        let childAGenesis = try await premineGenesis(spec: childASpec, owner: kp, fetcher: fetcher, time: base)
        let childBGenesis = try await premineGenesis(spec: childBSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Deposit on child A
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: premineA, newBalance: premineA - amount + crA)],
            actions: [],
            depositActions: [DepositAction(nonce: 1, demander: kpAddr, amountDemanded: amount, amountDeposited: amount)],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )
        let _ = try await BlockBuilder.buildBlock(
            previous: childAGenesis, transactions: [tx(depositBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Receipt on nexus for directory "ChildA"
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: nr)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, directory: "ChildA")],
            withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(receiptBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Try to withdraw on child B using child A's deposit — should fail
        let crB = childBSpec.initialReward
        let replayBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: premineB, newBalance: premineB + amount + crB)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, amountWithdrawn: amount)],
            signers: [kpAddr], fee: 0, nonce: 1
        )

        let replayBlock = try await BlockBuilder.buildBlock(
            previous: childBGenesis,
            transactions: [tx(replayBody, kp)],
            parentChainBlock: nexusBlock1,
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await replayBlock.validate(
            nexusHash: replayBlock.getDifficultyHash(),
            parentChainBlock: nexusBlock1,
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Withdrawal on child B using child A deposit should fail — no deposit exists on B")
    }
}

// ============================================================================
// MARK: - 4. Selfish Mining: Withheld Chain vs Honest Chain
// ============================================================================

@MainActor
final class SelfishMiningTests: XCTestCase {

    func testHonestChainNotDisadvantagedByWithholding() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        // Honest miner publishes 3 blocks immediately
        var honestPrev = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: honestPrev, timestamp: base + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: b), block: b
            )
            honestPrev = b
        }

        let honestTip = await chain.getMainChainTip()
        XCTAssertEqual(honestTip, HeaderImpl<Block>(node: honestPrev).rawCID)

        // Selfish miner withholds 3 blocks (same length), publishes all at once
        var selfishPrev = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: selfishPrev, timestamp: base + Int64(i) * 500,
                difficulty: UInt256(1000), nonce: UInt64(i + 200), fetcher: fetcher
            )
            selfishPrev = b
        }

        // Submit all withheld blocks
        var cursor = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: cursor, timestamp: base + Int64(i) * 500,
                difficulty: UInt256(1000), nonce: UInt64(i + 200), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: b), block: b
            )
            cursor = b
        }

        // Equal-length selfish chain should NOT replace honest chain (first-seen wins)
        let finalTip = await chain.getMainChainTip()
        XCTAssertEqual(finalTip, honestTip, "Equal-length withheld chain should not displace honest chain")
    }

    func testLongerSelfishChainDoesReorg() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        // Honest: 3 blocks
        var honestPrev = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: honestPrev, timestamp: base + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: b), block: b
            )
            honestPrev = b
        }

        // Selfish: 4 blocks (longer, wins)
        var selfishPrev = genesis
        for i in 1...4 {
            let b = try await BlockBuilder.buildBlock(
                previous: selfishPrev, timestamp: base + Int64(i) * 500,
                difficulty: UInt256(1000), nonce: UInt64(i + 300), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: b), block: b
            )
            selfishPrev = b
        }

        let finalTip = await chain.getMainChainTip()
        XCTAssertEqual(finalTip, HeaderImpl<Block>(node: selfishPrev).rawCID, "Longer chain wins regardless of timing")
    }
}

// ============================================================================
// MARK: - 5. Transaction Filters End-to-End in Block Validation
// ============================================================================

@MainActor
final class TransactionFilterBlockTests: XCTestCase {

    func testMinimumFeeFilterEnforcedInBlockValidation() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let filteredSpec = ChainSpec(
            directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
            premine: 0, targetBlockTime: 1_000, initialRewardExponent: 10,
            difficultyAdjustmentWindow: 5,
            transactionFilters: ["function transactionFilter(tx) { var t = JSON.parse(tx); return t.fee >= 10; }"]
        )

        let genesis = try await BlockBuilder.buildGenesis(
            spec: filteredSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let reward = filteredSpec.rewardAtBlock(0)

        // Block with fee=5 (below filter minimum of 10)
        let lowFeeBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: reward)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 5, nonce: 0
        )
        let lowFeeBlock = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(lowFeeBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let lowFeeValid = try await lowFeeBlock.validateNexus(fetcher: fetcher)
        XCTAssertFalse(lowFeeValid, "Block with fee below filter minimum should fail validation")

        // Block with fee=10 (meets filter)
        let okFeeBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: reward)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 10, nonce: 0
        )
        let okFeeBlock = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(okFeeBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let okFeeValid = try await okFeeBlock.validateNexus(fetcher: fetcher)
        XCTAssertTrue(okFeeValid, "Block with fee meeting filter should pass validation")
    }
}

// ============================================================================
// MARK: - 6. General State (Action) Mutations Through Block Lifecycle
// ============================================================================

@MainActor
final class GeneralStateBlockTests: XCTestCase {

    func testInsertReadUpdateDeleteGeneralState() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Block 1: Insert key-value pair
        let insertBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: reward)],
            actions: [Action(key: "greeting", oldValue: nil, newValue: "hello")],
            depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(insertBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let v1 = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(v1)
        XCTAssertNotEqual(block1.frontier.rawCID, block1.homestead.rawCID)

        // Block 2: Update the value
        let updateBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: reward, newBalance: reward + reward)],
            actions: [Action(key: "greeting", oldValue: "hello", newValue: "world")],
            depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 1
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [tx(updateBody, kp)],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let v2 = try await block2.validateNexus(fetcher: fetcher)
        XCTAssertTrue(v2)

        // Block 3: Delete the key
        let deleteBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: reward * 2, newBalance: reward * 3)],
            actions: [Action(key: "greeting", oldValue: "world", newValue: nil)],
            depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 2
        )
        let block3 = try await BlockBuilder.buildBlock(
            previous: block2, transactions: [tx(deleteBody, kp)],
            timestamp: base + 3000, difficulty: UInt256(1000), nonce: 3, fetcher: fetcher
        )
        let v3 = try await block3.validateNexus(fetcher: fetcher)
        XCTAssertTrue(v3)
    }

    func testInsertWithWrongOldValueFails() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let insertBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: reward)],
            actions: [Action(key: "key1", oldValue: nil, newValue: "value1")],
            depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(insertBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Update with wrong oldValue
        let wrongBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: reward, newBalance: reward + reward)],
            actions: [Action(key: "key1", oldValue: "WRONG", newValue: "value2")],
            depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 1
        )

        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: block1, transactions: [tx(wrongBody, kp)],
                timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            XCTFail("Update with wrong oldValue should throw")
        } catch {
            // GeneralState.updateState checks oldValue matches actual
        }
    }
}

// ============================================================================
// MARK: - 7. Peer State Mutations Through Block Lifecycle
// ============================================================================

@MainActor
final class PeerStateBlockTests: XCTestCase {

    func testInsertAndUpdatePeerAction() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Block 1: Register a peer
        let insertBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: reward)],
            actions: [],
            depositActions: [], genesisActions: [],
            peerActions: [PeerAction(owner: kpAddr, IpAddress: "192.168.1.1", refreshed: base, fullNode: true, type: .insert)],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(insertBody, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let v1 = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(v1)

        // Block 2: Update the peer
        let updateBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: reward, newBalance: reward + reward)],
            actions: [],
            depositActions: [], genesisActions: [],
            peerActions: [PeerAction(owner: kpAddr, IpAddress: "10.0.0.1", refreshed: base + 1000, fullNode: false, type: .update)],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 1
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [tx(updateBody, kp)],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let v2 = try await block2.validateNexus(fetcher: fetcher)
        XCTAssertTrue(v2)

        // Block 3: Delete the peer
        let deleteBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: reward * 2, newBalance: reward * 3)],
            actions: [],
            depositActions: [], genesisActions: [],
            peerActions: [PeerAction(owner: kpAddr, IpAddress: "", refreshed: 0, fullNode: false, type: .delete)],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 2
        )
        let block3 = try await BlockBuilder.buildBlock(
            previous: block2, transactions: [tx(deleteBody, kp)],
            timestamp: base + 3000, difficulty: UInt256(1000), nonce: 3, fetcher: fetcher
        )
        let v3 = try await block3.validateNexus(fetcher: fetcher)
        XCTAssertTrue(v3)
    }
}
