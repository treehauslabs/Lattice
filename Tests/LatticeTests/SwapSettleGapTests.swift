import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// MARK: - Helpers

private func f() -> StorableFetcher { StorableFetcher() }

private func s(_ dir: String = "Nexus", premine: UInt64 = 0) -> ChainSpec {
    ChainSpec(directory: dir, maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
}

private func childSpec(_ dir: String = "Child", premine: UInt64 = 1000) -> ChainSpec {
    ChainSpec(directory: dir, maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
}

private func tx(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = HeaderImpl<TransactionBody>(node: body)
    let sig = CryptoUtils.sign(message: h.rawCID, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: sig], body: h)
}

private func multiTx(_ body: TransactionBody, _ kps: [(privateKey: String, publicKey: String)]) -> Transaction {
    let h = HeaderImpl<TransactionBody>(node: body)
    var sigs = [String: String]()
    for kp in kps {
        sigs[kp.publicKey] = CryptoUtils.sign(message: h.rawCID, privateKeyHex: kp.privateKey)!
    }
    return Transaction(signatures: sigs, body: h)
}

private func id(_ pubKey: String) -> String {
    HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
}

private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private func premineGenesis(
    spec: ChainSpec, owner: (privateKey: String, publicKey: String),
    fetcher: StorableFetcher, time: Int64
) async throws -> Block {
    let addr = id(owner.publicKey)
    let body = TransactionBody(
        accountActions: [AccountAction(owner: addr, delta: Int64(spec.premineAmount()))],
        actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
        peerActions: [], settleActions: [], signers: [addr], fee: 0, nonce: 0
    )
    return try await BlockBuilder.buildGenesis(
        spec: spec, transactions: [tx(body, owner)],
        timestamp: time, difficulty: UInt256(1000), fetcher: fetcher
    )
}

/// Build an empty nexus genesis + first block, returning (genesis, block1, reward).
/// The first block distributes the reward to `owner`.
private func fundedNexus(
    spec: ChainSpec, owner: (privateKey: String, publicKey: String),
    fetcher: StorableFetcher, base: Int64
) async throws -> (genesis: Block, block1: Block, balance: UInt64) {
    let addr = id(owner.publicKey)
    let genesis = try await BlockBuilder.buildGenesis(
        spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
    )
    let reward = spec.rewardAtBlock(1)
    let fundBody = TransactionBody(
        accountActions: [AccountAction(owner: addr, delta: Int64(reward))],
        actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
        peerActions: [], settleActions: [], signers: [addr], fee: 0, nonce: 0, chainPath: ["Nexus"]
    )
    let block1 = try await BlockBuilder.buildBlock(
        previous: genesis, transactions: [tx(fundBody, owner)],
        timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
    )
    return (genesis, block1, reward)
}

// ============================================================================
// MARK: - 1. Settlement on Child Chain (not Nexus)
// ============================================================================

@MainActor
final class SettleOnChildChainTests: XCTestCase {

    func testSettleOnChildChain() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let cSpec = childSpec("Child")
        let nexusSpec = s("Nexus")
        let childPremine = cSpec.premineAmount()
        let childReward = cSpec.initialReward

        let childGenesis = try await premineGenesis(spec: cSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let t1 = base + 1000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: t1,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let swapKeyA = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: 500, timelock: 1000)).description
        let swapKeyB = SwapKey(swapAction: SwapAction(nonce: 2, sender: bobAddr, recipient: aliceAddr, amount: 500, timelock: 1000)).description

        // Settlement on child chain — not the nexus
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(childPremine + childReward) - Int64(childPremine))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [SettleAction(
                nonce: 1, senderA: aliceAddr, senderB: bobAddr,
                swapKeyA: swapKeyA, directoryA: "SomeChain",
                swapKeyB: swapKeyB, directoryB: "OtherChain"
            )],
            signers: [aliceAddr, bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus", "Child"]
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [multiTx(settleBody, [alice, bob])],
            parentChainBlock: nexusBlock1,
            timestamp: t1, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await childBlock1.validate(
            nexusHash: childBlock1.getDifficultyHash(),
            parentChainBlock: nexusBlock1,
            chainPath: ["Nexus", "Child"],
            fetcher: fetcher
        )
        XCTAssertTrue(valid, "Settlement should be valid on a child chain, not just the nexus")
    }

    func testSettleOnChildUsedByGrandchild() async throws {
        let fetcher = f()
        let base = now() - 50_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let cSpec = s("Child")
        let gcSpec = childSpec("Grandchild")
        let gcPremine = gcSpec.premineAmount()
        let gcReward = gcSpec.initialReward

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: cSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let gcGenesis = try await premineGenesis(spec: gcSpec, owner: alice, fetcher: fetcher, time: base)

        let t1 = base + 1000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: t1,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Grandchild: create swap
        let swapAmount: UInt64 = 300
        let swap = SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000)
        let swapKey = SwapKey(swapAction: swap).description

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(gcPremine - swapAmount + gcReward) - Int64(gcPremine))],
            actions: [], swapActions: [swap],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let gcBlock1 = try await BlockBuilder.buildBlock(
            previous: gcGenesis, transactions: [tx(swapBody, alice)],
            parentChainBlock: childGenesis,
            timestamp: t1, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Child: create settlement for the grandchild's swap
        let childReward = cSpec.rewardAtBlock(1)
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(childReward))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [SettleAction(
                nonce: 1, senderA: aliceAddr, senderB: aliceAddr,
                swapKeyA: swapKey, directoryA: "Grandchild",
                swapKeyB: swapKey, directoryB: "Grandchild"
            )],
            signers: [aliceAddr], fee: 0, nonce: 0
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(settleBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Child block 2 so homestead includes settlement
        let t2 = base + 2000
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1, timestamp: t2,
            difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1, parentChainBlock: nexusBlock2,
            timestamp: t2, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        // Grandchild: claim swap using child's settlement
        let balAfterSwap = gcPremine - swapAmount + gcReward
        let claimBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(balAfterSwap + swapAmount + gcReward) - Int64(balAfterSwap))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000, isRefund: false)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 2
        )
        let gcBlock2 = try await BlockBuilder.buildBlock(
            previous: gcBlock1, transactions: [tx(claimBody, alice)],
            parentChainBlock: childBlock2,
            timestamp: t2, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await gcBlock2.validate(
            nexusHash: gcBlock2.getDifficultyHash(),
            parentChainBlock: childBlock2,
            fetcher: fetcher
        )
        XCTAssertTrue(valid, "Grandchild should claim swap using settlement from child chain (non-nexus parent)")
    }
}

// ============================================================================
// MARK: - 2. Multiple Swaps in a Single Transaction
// ============================================================================

@MainActor
final class MultipleSwapTests: XCTestCase {

    func testMultipleSwapsInSingleTransaction() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let reward = nexusSpec.rewardAtBlock(1)
        let swap1: UInt64 = 200
        let swap2: UInt64 = 300
        let totalLocked = swap1 + swap2

        // credits = reward - totalLocked = 524
        // available = 0 + reward + 0 + 0 - totalLocked = 524 ✓
        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward - totalLocked))],
            actions: [],
            swapActions: [
                SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swap1, timelock: 1000),
                SwapAction(nonce: 2, sender: aliceAddr, recipient: aliceAddr, amount: swap2, timelock: 1000)
            ],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid, "Block with multiple swaps in one transaction should be valid")
    }

    func testMultipleSwapsFromDifferentSendersInBlock() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let nexusSpec = s("Nexus")
        // Fund alice first
        let (_, block1, aliceBal) = try await fundedNexus(spec: nexusSpec, owner: alice, fetcher: fetcher, base: base)

        let reward2 = nexusSpec.rewardAtBlock(2)
        let aliceSwapAmt: UInt64 = 200
        let bobFund: UInt64 = 300
        let bobSwapAmt: UInt64 = 100

        // Alice: debit 300 to bob, lock 200 in swap, receive reward
        let aliceTxBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(aliceSwapAmt + bobFund)),
                AccountAction(owner: bobAddr, delta: Int64(bobFund)),
                AccountAction(owner: aliceAddr, delta: Int64(reward2))
            ],
            actions: [],
            swapActions: [SwapAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: aliceSwapAmt, timelock: 1000)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        // Bob: lock 100 in swap
        let bobTxBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: -Int64(bobSwapAmt))],
            actions: [],
            swapActions: [SwapAction(nonce: 1, sender: bobAddr, recipient: aliceAddr, amount: bobSwapAmt, timelock: 1000)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1,
            transactions: [tx(aliceTxBody, alice), tx(bobTxBody, bob)],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await block2.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid, "Block with swaps from different senders should be valid")
    }
}

// ============================================================================
// MARK: - 3. Multiple Settlements in a Single Transaction
// ============================================================================

@MainActor
final class MultipleSettleTests: XCTestCase {

    func testMultipleSettlementsInSingleTransaction() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward = nexusSpec.rewardAtBlock(1)

        let swapKeyA1 = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: 500, timelock: 1000)).description
        let swapKeyB1 = SwapKey(swapAction: SwapAction(nonce: 1, sender: bobAddr, recipient: aliceAddr, amount: 500, timelock: 1000)).description
        let swapKeyA2 = SwapKey(swapAction: SwapAction(nonce: 2, sender: aliceAddr, recipient: bobAddr, amount: 300, timelock: 2000)).description
        let swapKeyB2 = SwapKey(swapAction: SwapAction(nonce: 2, sender: bobAddr, recipient: aliceAddr, amount: 300, timelock: 2000)).description

        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [
                SettleAction(nonce: 1, senderA: aliceAddr, senderB: bobAddr,
                    swapKeyA: swapKeyA1, directoryA: "ChildA",
                    swapKeyB: swapKeyB1, directoryB: "ChildB"),
                SettleAction(nonce: 2, senderA: aliceAddr, senderB: bobAddr,
                    swapKeyA: swapKeyA2, directoryA: "ChildA",
                    swapKeyB: swapKeyB2, directoryB: "ChildB")
            ],
            signers: [aliceAddr, bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [multiTx(settleBody, [alice, bob])],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid, "Multiple settlements in one transaction should be valid")
    }

    func testDuplicateSettleKeysAcrossSettlementsRejected() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward = nexusSpec.rewardAtBlock(1)

        let swapKeyA = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: 500, timelock: 1000)).description
        let swapKeyB = SwapKey(swapAction: SwapAction(nonce: 1, sender: bobAddr, recipient: aliceAddr, amount: 500, timelock: 1000)).description

        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [
                SettleAction(nonce: 1, senderA: aliceAddr, senderB: bobAddr,
                    swapKeyA: swapKeyA, directoryA: "ChildA",
                    swapKeyB: swapKeyB, directoryB: "ChildB"),
                SettleAction(nonce: 2, senderA: aliceAddr, senderB: bobAddr,
                    swapKeyA: swapKeyA, directoryA: "ChildA",
                    swapKeyB: swapKeyB, directoryB: "ChildB")
            ],
            signers: [aliceAddr, bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: genesis, transactions: [multiTx(settleBody, [alice, bob])],
                timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
            )
            XCTFail("Duplicate settle keys across settlements in same block should throw")
        } catch {
            // Expected: conflictingActions
        }
    }
}

// ============================================================================
// MARK: - 4. Swap with Non-Zero Fees
// ============================================================================

@MainActor
final class SwapWithFeesTests: XCTestCase {

    func testSwapWithNonZeroFees() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward = nexusSpec.rewardAtBlock(1)
        let swapAmount: UInt64 = 500
        let fee: UInt64 = 10

        // credits <= debits + reward + fees + claimed - locked
        // credit = reward + fee - swapAmount = 1024 + 10 - 500 = 534
        // available = 0 + 1024 + 10 + 0 - 500 = 534 ✓
        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward + fee - swapAmount))],
            actions: [],
            swapActions: [SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: fee, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid, "Swap with non-zero fee should be valid")
    }

    func testSwapClaimWithNonZeroFees() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward1 = nexusSpec.rewardAtBlock(1)
        let swapAmount: UInt64 = 500
        let fee: UInt64 = 5

        // Block 1: swap
        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward1 - swapAmount))],
            actions: [], swapActions: [SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Block 2: settle
        let reward2 = nexusSpec.rewardAtBlock(2)
        let swapKey = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000)).description
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward2))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: aliceAddr, senderB: aliceAddr, swapKeyA: swapKey, directoryA: "Nexus", swapKeyB: swapKey, directoryB: "Nexus")],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [tx(settleBody, alice)],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        // Block 3: claim with fee
        let reward3 = nexusSpec.rewardAtBlock(3)
        let claimBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(swapAmount + reward3 + fee))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000, isRefund: false)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: fee, nonce: 2, chainPath: ["Nexus"]
        )
        let block3 = try await BlockBuilder.buildBlock(
            previous: block2, transactions: [tx(claimBody, alice)],
            timestamp: base + 3000, difficulty: UInt256(1000), nonce: 3, fetcher: fetcher
        )
        let valid = try await block3.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid, "Swap claim with non-zero fee should be valid")
    }

    func testFeeExceedsAvailableWithSwapLockRejected() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward = nexusSpec.rewardAtBlock(1)
        let swapAmount: UInt64 = 500
        let fee: UInt64 = 10

        // Over-credit by 1: available = reward + fee - swapAmount = 534
        let overCreditDelta = Int64(reward + fee - swapAmount) + 1
        let body = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: overCreditDelta)],
            actions: [],
            swapActions: [SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: fee, nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "Over-crediting beyond reward + fee - swapLocked should be rejected")
    }
}

// ============================================================================
// MARK: - 5. Settle with Missing Signature
// ============================================================================

@MainActor
final class SettleMissingSignatureTests: XCTestCase {

    func testSettleWithOnlyOneSenderSignatureRejected() {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let swapKeyA = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: 500, timelock: 1000)).description
        let swapKeyB = SwapKey(swapAction: SwapAction(nonce: 1, sender: bobAddr, recipient: aliceAddr, amount: 500, timelock: 1000)).description

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: aliceAddr, senderB: bobAddr,
                swapKeyA: swapKeyA, directoryA: "A", swapKeyB: swapKeyB, directoryB: "B")],
            signers: [aliceAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.settleActionsAreValid(), "Settle with only senderA as signer should be rejected")
    }

    func testSettleWithOnlySenderBSignatureRejected() {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let swapKeyA = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: 500, timelock: 1000)).description
        let swapKeyB = SwapKey(swapAction: SwapAction(nonce: 1, sender: bobAddr, recipient: aliceAddr, amount: 500, timelock: 1000)).description

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: aliceAddr, senderB: bobAddr,
                swapKeyA: swapKeyA, directoryA: "A", swapKeyB: swapKeyB, directoryB: "B")],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.settleActionsAreValid(), "Settle with only senderB as signer should be rejected")
    }

    func testSettleMissingSignatureBlockValidationFails() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward = nexusSpec.rewardAtBlock(1)

        let swapKeyA = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: 500, timelock: 1000)).description
        let swapKeyB = SwapKey(swapAction: SwapAction(nonce: 1, sender: bobAddr, recipient: aliceAddr, amount: 500, timelock: 1000)).description

        // Both listed as signers but only alice signs the transaction
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: aliceAddr, senderB: bobAddr,
                swapKeyA: swapKeyA, directoryA: "A", swapKeyB: swapKeyB, directoryB: "B")],
            signers: [aliceAddr, bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let singleSigTx = tx(settleBody, alice)
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [singleSigTx],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "Block with settle signed by only one party should fail validation")
    }
}

// ============================================================================
// MARK: - 6. Refund vs Settlement Claim Mutual Exclusion
// ============================================================================

@MainActor
final class SwapClaimMutualExclusionTests: XCTestCase {

    func testRefundAndSettlementClaimInSameBlockConflicts() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward1 = nexusSpec.rewardAtBlock(1)
        let swapAmount: UInt64 = 500
        let timelock: UInt64 = 1

        // Block 1: swap
        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward1 - swapAmount))],
            actions: [], swapActions: [SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Block 2: settle
        let reward2 = nexusSpec.rewardAtBlock(2)
        let swapKey = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock)).description
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward2))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: aliceAddr, senderB: aliceAddr, swapKeyA: swapKey, directoryA: "Nexus", swapKeyB: swapKey, directoryB: "Nexus")],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [tx(settleBody, alice)],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        // Block 3: both refund and settlement claim in same block — should conflict
        let reward3 = nexusSpec.rewardAtBlock(3)
        let refundTxBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(swapAmount + reward3))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock, isRefund: true)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 2, chainPath: ["Nexus"]
        )
        let claimTxBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(swapAmount))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock, isRefund: false)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 3, chainPath: ["Nexus"]
        )
        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: block2,
                transactions: [tx(refundTxBody, alice), tx(claimTxBody, alice)],
                timestamp: base + 3000, difficulty: UInt256(1000), nonce: 3, fetcher: fetcher
            )
            XCTFail("Refund and settlement claim for same swap in same block should throw conflictingActions")
        } catch {
            // Expected: both try to delete the same swap key
        }
    }

    func testRefundSucceedsThenSettlementClaimFails() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward1 = nexusSpec.rewardAtBlock(1)
        let swapAmount: UInt64 = 500
        let timelock: UInt64 = 1

        // Block 1: swap
        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward1 - swapAmount))],
            actions: [], swapActions: [SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Block 2: settle
        let reward2 = nexusSpec.rewardAtBlock(2)
        let swapKey = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock)).description
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward2))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: aliceAddr, senderB: aliceAddr, swapKeyA: swapKey, directoryA: "Nexus", swapKeyB: swapKey, directoryB: "Nexus")],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [tx(settleBody, alice)],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        // Block 3: refund succeeds (blockIndex 3 > timelock 1)
        let reward3 = nexusSpec.rewardAtBlock(3)
        let refundBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(swapAmount + reward3))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock, isRefund: true)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 2, chainPath: ["Nexus"]
        )
        let block3 = try await BlockBuilder.buildBlock(
            previous: block2, transactions: [tx(refundBody, alice)],
            timestamp: base + 3000, difficulty: UInt256(1000), nonce: 3, fetcher: fetcher
        )
        let valid = try await block3.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid, "Refund after timelock should succeed even when settlement exists")

        // Block 4: settlement claim fails — swap already deleted by refund
        let reward4 = nexusSpec.rewardAtBlock(4)
        let claimBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(swapAmount + reward4))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock, isRefund: false)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 3, chainPath: ["Nexus"]
        )
        do {
            let block4 = try await BlockBuilder.buildBlock(
                previous: block3, transactions: [tx(claimBody, alice)],
                timestamp: base + 4000, difficulty: UInt256(1000), nonce: 4, fetcher: fetcher
            )
            let claimValid = try await block4.validateNexus(fetcher: fetcher)
            XCTAssertFalse(claimValid, "Settlement claim after refund should fail — swap already deleted")
        } catch {
            // Expected: deletion proof fails on non-existent swap
        }
    }

    func testSettlementClaimSucceedsThenRefundFails() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward1 = nexusSpec.rewardAtBlock(1)
        let swapAmount: UInt64 = 500
        let timelock: UInt64 = 1

        // Block 1: swap
        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward1 - swapAmount))],
            actions: [], swapActions: [SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Block 2: settle
        let reward2 = nexusSpec.rewardAtBlock(2)
        let swapKey = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock)).description
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward2))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: aliceAddr, senderB: aliceAddr, swapKeyA: swapKey, directoryA: "Nexus", swapKeyB: swapKey, directoryB: "Nexus")],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [tx(settleBody, alice)],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        // Block 3: settlement claim succeeds
        let reward3 = nexusSpec.rewardAtBlock(3)
        let claimBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(swapAmount + reward3))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock, isRefund: false)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 2, chainPath: ["Nexus"]
        )
        let block3 = try await BlockBuilder.buildBlock(
            previous: block2, transactions: [tx(claimBody, alice)],
            timestamp: base + 3000, difficulty: UInt256(1000), nonce: 3, fetcher: fetcher
        )
        let valid = try await block3.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid, "Settlement claim should succeed")

        // Block 4: refund fails — swap already deleted
        let reward4 = nexusSpec.rewardAtBlock(4)
        let refundBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(swapAmount + reward4))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock, isRefund: true)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 3, chainPath: ["Nexus"]
        )
        do {
            let block4 = try await BlockBuilder.buildBlock(
                previous: block3, transactions: [tx(refundBody, alice)],
                timestamp: base + 4000, difficulty: UInt256(1000), nonce: 4, fetcher: fetcher
            )
            let refundValid = try await block4.validateNexus(fetcher: fetcher)
            XCTAssertFalse(refundValid, "Refund after settlement claim should fail — swap already deleted")
        } catch {
            // Expected: deletion proof fails on non-existent swap
        }
    }
}

// ============================================================================
// MARK: - 7. Delta Model + Swap Interactions
// ============================================================================

@MainActor
final class DeltaModelSwapTests: XCTestCase {

    func testDebitCombinedWithSwapLock() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let nexusSpec = s("Nexus")
        let (_, block1, aliceBal) = try await fundedNexus(spec: nexusSpec, owner: alice, fetcher: fetcher, base: base)

        let reward2 = nexusSpec.rewardAtBlock(2)
        let swapAmount: UInt64 = 300
        let transfer: UInt64 = 200

        // Alice: debit transfer to bob + lock swap + receive reward
        // debits = transfer + swapAmount... wait, swap lock isn't a debit.
        // credits = reward2 + transfer (bob credit)
        // debits = transfer (alice debit)
        // available = transfer + reward2 + 0 + 0 - swapAmount
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(transfer)),
                AccountAction(owner: bobAddr, delta: Int64(transfer)),
                AccountAction(owner: aliceAddr, delta: Int64(reward2 - swapAmount))
            ],
            actions: [],
            swapActions: [SwapAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: swapAmount, timelock: 1000)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [tx(body, alice)],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await block2.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid, "Debit transfer combined with swap lock should be valid")
    }

    func testSwapLockExceedsAvailableFundsRejected() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward = nexusSpec.rewardAtBlock(1)

        // Lock more than reward: available = 0 + reward + 0 + 0 - (reward+1) < 0
        let overLock = reward + 1
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            swapActions: [SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: overLock, timelock: 1000)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "Swap lock exceeding available funds should be rejected")
    }

    func testSwapClaimCombinedWithCreditTransfer() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let reward1 = nexusSpec.rewardAtBlock(1)
        let swapAmount: UInt64 = 500

        // Block 1: swap
        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward1 - swapAmount))],
            actions: [], swapActions: [SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000)],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Block 2: settle
        let reward2 = nexusSpec.rewardAtBlock(2)
        let swapKey = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000)).description
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward2))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: aliceAddr, senderB: aliceAddr, swapKeyA: swapKey, directoryA: "Nexus", swapKeyB: swapKey, directoryB: "Nexus")],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [tx(settleBody, alice)],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        // Block 3: claim + distribute some to bob
        let reward3 = nexusSpec.rewardAtBlock(3)
        let toBob: UInt64 = 200
        let claimBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(swapAmount + reward3 - toBob)),
                AccountAction(owner: bobAddr, delta: Int64(toBob))
            ],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000, isRefund: false)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 2, chainPath: ["Nexus"]
        )
        let block3 = try await BlockBuilder.buildBlock(
            previous: block2, transactions: [tx(claimBody, alice)],
            timestamp: base + 3000, difficulty: UInt256(1000), nonce: 3, fetcher: fetcher
        )
        let valid = try await block3.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid, "Swap claim combined with transfer to another party should be valid")
    }

    func testSwapLockOverflowRejected() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Two swaps whose amounts overflow UInt64
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            swapActions: [
                SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: UInt64.max, timelock: 1000),
                SwapAction(nonce: 2, sender: aliceAddr, recipient: aliceAddr, amount: 1, timelock: 1000)
            ],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "Swap lock amount overflow should be rejected")
    }
}
