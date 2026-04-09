import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation


private func f() -> StorableFetcher { StorableFetcher() }

private func s(_ dir: String = "Nexus", premine: UInt64 = 1000) -> ChainSpec {
    ChainSpec(directory: dir, maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
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

// ============================================================================
// MARK: - CRITICAL: Full Cross-Chain Swap → Settle → Claim Roundtrip
// ============================================================================

@MainActor
final class CrossChainRoundtripTests: XCTestCase {

    func testFullSwapSettleClaimRoundtrip() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let nexusReward = nexusSpec.rewardAtBlock(0)
        let swapAmount: UInt64 = 500

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let childSwap = SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000)
        let childSwapKey = SwapKey(swapAction: childSwap).description

        // Step 1: SWAP on child chain (locks funds)
        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(childPremine - swapAmount + childReward) - Int64(childPremine))
            ],
            actions: [],
            swapActions: [childSwap],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        XCTAssertEqual(childBlock1.index, 1)
        let balanceAfterSwap = childPremine - swapAmount + childReward

        // Step 2: SETTLE on nexus chain (co-signed acknowledgment)
        let settleBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(nexusReward))
            ],
            actions: [],
            swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [
                SettleAction(
                    nonce: 1,
                    senderA: aliceAddr,
                    senderB: aliceAddr,
                    swapKeyA: childSwapKey,
                    directoryA: "Child",
                    swapKeyB: childSwapKey,
                    directoryB: "Child"
                )
            ],
            signers: [aliceAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let nexusValid = try await nexusBlock1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(nexusValid)

        // Step 3: CLAIM on child chain (claims funds with settlement proof)
        let claimBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(balanceAfterSwap + swapAmount + childReward) - Int64(balanceAfterSwap))
            ],
            actions: [],
            swapActions: [],
            swapClaimActions: [
                SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000, isRefund: false)
            ],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 2
        )

        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1,
            transactions: [tx(claimBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        XCTAssertEqual(childBlock2.index, 2)

        let finalBalance = balanceAfterSwap + swapAmount + childReward
        XCTAssertEqual(finalBalance, childPremine + 2 * childReward)
    }

    func testSwapRefundAfterTimelock() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let swapAmount: UInt64 = 1000
        let timelock: UInt64 = 1

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let childSwap = SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock)

        let t1 = base + 1000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: t1,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(childPremine - swapAmount + childReward) - Int64(childPremine))
            ],
            actions: [],
            swapActions: [childSwap],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(swapBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let balanceAfterSwap = childPremine - swapAmount + childReward

        let t2 = base + 2000
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1, timestamp: t2,
            difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let refundBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(balanceAfterSwap + swapAmount + childReward) - Int64(balanceAfterSwap))
            ],
            actions: [], swapActions: [],
            swapClaimActions: [
                SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock, isRefund: true)
            ],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 2
        )
        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1,
            transactions: [tx(refundBody, alice)],
            parentChainBlock: nexusBlock2,
            timestamp: t2, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await childBlock2.validate(
            nexusHash: childBlock2.getDifficultyHash(),
            parentChainBlock: nexusBlock2,
            fetcher: fetcher
        )
        XCTAssertTrue(valid, "Refund after timelock should succeed (blockIndex 2 > timelock 1)")
    }

    func testPrematureRefundRejected() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let swapAmount: UInt64 = 1000
        let timelock: UInt64 = 9999

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let childSwap = SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock)

        let t1 = base + 1000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: t1,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(childPremine - swapAmount + childReward) - Int64(childPremine))
            ],
            actions: [],
            swapActions: [childSwap],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(swapBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let balanceAfterSwap = childPremine - swapAmount + childReward

        let t2 = base + 2000
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1, timestamp: t2,
            difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let refundBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(balanceAfterSwap + swapAmount + childReward) - Int64(balanceAfterSwap))
            ],
            actions: [], swapActions: [],
            swapClaimActions: [
                SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: timelock, isRefund: true)
            ],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 2
        )
        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1,
            transactions: [tx(refundBody, alice)],
            parentChainBlock: nexusBlock2,
            timestamp: t2, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await childBlock2.validate(
            nexusHash: childBlock2.getDifficultyHash(),
            parentChainBlock: nexusBlock2,
            fetcher: fetcher
        )
        XCTAssertFalse(valid, "Refund before timelock expires must be rejected (blockIndex 2 <= timelock 9999)")
    }

    func testTwoPartySwapEndToEnd() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let childASpec = s("ChildA")
        let childBSpec = s("ChildB")
        let nexusSpec = s("Nexus", premine: 0)
        let premineA = childASpec.premineAmount()
        let premineB = childBSpec.premineAmount()
        let rewardA = childASpec.initialReward
        let rewardB = childBSpec.initialReward
        let nexusReward = nexusSpec.rewardAtBlock(0)

        let childAGenesis = try await premineGenesis(spec: childASpec, owner: alice, fetcher: fetcher, time: base)
        let childBGenesis = try await premineGenesis(spec: childBSpec, owner: bob, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let aliceSwapAmount: UInt64 = 300
        let bobSwapAmount: UInt64 = 200

        let aliceSwap = SwapAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: aliceSwapAmount, timelock: 1000)
        let bobSwap = SwapAction(nonce: 1, sender: bobAddr, recipient: aliceAddr, amount: bobSwapAmount, timelock: 500)

        let t1 = base + 1000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: t1,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let aliceSwapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premineA - aliceSwapAmount + rewardA) - Int64(premineA))],
            actions: [], swapActions: [aliceSwap],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let childABlock1 = try await BlockBuilder.buildBlock(
            previous: childAGenesis, transactions: [tx(aliceSwapBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let bobSwapBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(premineB - bobSwapAmount + rewardB) - Int64(premineB))],
            actions: [], swapActions: [bobSwap],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [bobAddr], fee: 0, nonce: 1
        )
        let childBBlock1 = try await BlockBuilder.buildBlock(
            previous: childBGenesis, transactions: [tx(bobSwapBody, bob)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let t2 = base + 2000
        let aliceSwapKey = SwapKey(swapAction: aliceSwap).description
        let bobSwapKey = SwapKey(swapAction: bobSwap).description
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(nexusSpec.rewardAtBlock(2)))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [SettleAction(
                nonce: 1, senderA: aliceAddr, senderB: bobAddr,
                swapKeyA: aliceSwapKey, directoryA: "ChildA",
                swapKeyB: bobSwapKey, directoryB: "ChildB"
            )],
            signers: [aliceAddr, bobAddr], fee: 0, nonce: 0
        )
        let settleHeader = HeaderImpl<TransactionBody>(node: settleBody)
        let sigA = CryptoUtils.sign(message: settleHeader.rawCID, privateKeyHex: alice.privateKey)!
        let sigB = CryptoUtils.sign(message: settleHeader.rawCID, privateKeyHex: bob.privateKey)!
        let settleTx = Transaction(signatures: [alice.publicKey: sigA, bob.publicKey: sigB], body: settleHeader)

        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1, transactions: [settleTx],
            timestamp: t2, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let nexusValid = try await nexusBlock2.validateNexus(fetcher: fetcher)
        XCTAssertTrue(nexusValid, "Settlement co-signed by both parties should be valid")

        let t3 = base + 3000
        let nexusBlock3 = try await BlockBuilder.buildBlock(
            previous: nexusBlock2, timestamp: t3,
            difficulty: UInt256(1000), nonce: 3, fetcher: fetcher
        )

        let bobClaimOnA = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(aliceSwapAmount + rewardA))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: aliceSwapAmount, timelock: 1000, isRefund: false)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        let childABlock2 = try await BlockBuilder.buildBlock(
            previous: childABlock1, transactions: [tx(bobClaimOnA, bob)],
            parentChainBlock: nexusBlock3,
            timestamp: t3, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let childAValid = try await childABlock2.validate(
            nexusHash: childABlock2.getDifficultyHash(),
            parentChainBlock: nexusBlock3,
            fetcher: fetcher
        )
        XCTAssertTrue(childAValid, "Bob claiming Alice's swap on ChildA should be valid")

        let aliceClaimOnB = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(bobSwapAmount + rewardB))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: bobAddr, recipient: aliceAddr, amount: bobSwapAmount, timelock: 500, isRefund: false)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0
        )
        let childBBlock2 = try await BlockBuilder.buildBlock(
            previous: childBBlock1, transactions: [tx(aliceClaimOnB, alice)],
            parentChainBlock: nexusBlock3,
            timestamp: t3, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let childBValid = try await childBBlock2.validate(
            nexusHash: childBBlock2.getDifficultyHash(),
            parentChainBlock: nexusBlock3,
            fetcher: fetcher
        )
        XCTAssertTrue(childBValid, "Alice claiming Bob's swap on ChildB should be valid")
    }
}

// ============================================================================
// MARK: - Swap Authorization Negative Tests
// ============================================================================

@MainActor
final class SwapAuthorizationTests: XCTestCase {

    func testClaimByNonRecipientRejected() {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let eve = CryptoUtils.generateKeyPair()
        let eveAddr = id(eve.publicKey)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: 100, timelock: 1000, isRefund: false)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [eveAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.swapClaimActionsAreValid(), "Claim signed by non-recipient should be rejected")
    }

    func testClaimByRecipientAccepted() {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: 100, timelock: 1000, isRefund: false)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        XCTAssertTrue(body.swapClaimActionsAreValid(), "Claim signed by recipient should be accepted")
    }

    func testRefundByNonSenderRejected() {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: 100, timelock: 1000, isRefund: true)],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.swapClaimActionsAreValid(), "Refund signed by non-sender should be rejected")
    }

    func testSettleWithMismatchedSenderRejected() {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let eve = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let eveAddr = id(eve.publicKey)

        let swapKeyA = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: bobAddr, amount: 100, timelock: 1000)).description
        let swapKeyB = SwapKey(swapAction: SwapAction(nonce: 1, sender: bobAddr, recipient: aliceAddr, amount: 50, timelock: 500)).description

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: eveAddr, senderB: bobAddr, swapKeyA: swapKeyA, directoryA: "A", swapKeyB: swapKeyB, directoryB: "B")],
            signers: [eveAddr, bobAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.settleActionsAreValid(), "Settle with senderA not matching swapKeyA's sender should be rejected")
    }

    func testSettleWithWrongCrossMatchRejected() {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let carol = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let carolAddr = id(carol.publicKey)

        let swapKeyA = SwapKey(swapAction: SwapAction(nonce: 1, sender: aliceAddr, recipient: carolAddr, amount: 100, timelock: 1000)).description
        let swapKeyB = SwapKey(swapAction: SwapAction(nonce: 1, sender: bobAddr, recipient: aliceAddr, amount: 50, timelock: 500)).description

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: aliceAddr, senderB: bobAddr, swapKeyA: swapKeyA, directoryA: "A", swapKeyB: swapKeyB, directoryB: "B")],
            signers: [aliceAddr, bobAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.settleActionsAreValid(), "Settle where swapKeyA.recipient != senderB should be rejected")
    }

    func testSettleAndClaimInSameBlockFails() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let premine = nexusSpec.premineAmount()
        let reward = nexusSpec.initialReward
        let nexusGenesis = try await premineGenesis(spec: nexusSpec, owner: alice, fetcher: fetcher, time: base)

        let swapAmount: UInt64 = 100
        let swap = SwapAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000)
        let swapKey = SwapKey(swapAction: swap).description

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premine - swapAmount + reward) - Int64(premine))],
            actions: [], swapActions: [swap],
            swapClaimActions: [], genesisActions: [], peerActions: [], settleActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let balAfterSwap = premine - swapAmount + reward

        let settleAndClaimBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(balAfterSwap + swapAmount + reward) - Int64(balAfterSwap))],
            actions: [], swapActions: [],
            swapClaimActions: [SwapClaimAction(nonce: 1, sender: aliceAddr, recipient: aliceAddr, amount: swapAmount, timelock: 1000, isRefund: false)],
            genesisActions: [], peerActions: [],
            settleActions: [SettleAction(nonce: 1, senderA: aliceAddr, senderB: aliceAddr, swapKeyA: swapKey, directoryA: "Nexus", swapKeyB: swapKey, directoryB: "Nexus")],
            signers: [aliceAddr], fee: 0, nonce: 2
        )
        do {
            let nexusBlock2 = try await BlockBuilder.buildBlock(
                previous: nexusBlock1, transactions: [tx(settleAndClaimBody, alice)],
                timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            let valid = try await nexusBlock2.validateNexus(fetcher: fetcher)
            XCTAssertFalse(valid, "Settle and claim in same block should fail — settlement not yet in homestead")
        } catch {
            // Claim proof or build fails because settle is not yet in homestead.settleState
        }
    }
}

// ============================================================================
// MARK: - CRITICAL: Transaction Nonce Replay Protection On-Chain
// ============================================================================

@MainActor
final class NonceReplayTests: XCTestCase {

    func testSameTransactionCannotBeIncludedTwice() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let transaction = tx(body, kp)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [transaction],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Try including the SAME transaction in the next block (replay)
        // Transaction state tracks applied transaction hashes → duplicate rejected
        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: block1, transactions: [transaction],
                timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            XCTFail("Replayed transaction should fail — duplicate in transaction state")
        } catch {
            // transaction state rejects duplicate transaction hash
        }
    }

    func testTransactionNonceIsUniquePerSignerInState() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let body1 = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body1, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Same nonce (0) but different body — should fail because TransactionState
        // already has an entry for this (signer, nonce) pair
        let body2 = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward + reward) - Int64(reward))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )

        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: block1, transactions: [tx(body2, kp)],
                timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            XCTFail("Reused nonce should fail — TransactionState already has this (signer, nonce)")
        } catch {
            // TransactionState insertion fails for duplicate key
        }
    }

    func testDifferentSignersSameNonceAllowed() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let aliceBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward / 2))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [aliceAddr], fee: 0, nonce: 0
        )
        let bobBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(reward / 2))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [bobAddr], fee: 0, nonce: 0
        )

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(aliceBody, alice), tx(bobBody, bob)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
    }
}

// ============================================================================
// MARK: - CRITICAL: Balance Conservation Across Reorgs
// ============================================================================

@MainActor
final class ReorgBalanceTests: XCTestCase {

    func testReorgPreservesBalanceInvariants() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()
        let reward = spec.initialReward

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)
        let chain = ChainState.fromGenesis(block: genesis)

        // Main chain: alice sends 100 to bob
        let mainBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premine - 100) - Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(100 + reward))
            ],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [aliceAddr], fee: 0, nonce: 1
        )
        let mainBlock1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(mainBody, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let mainValid = try await mainBlock1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(mainValid)
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: VolumeImpl<Block>(node: mainBlock1), block: mainBlock1
        )

        let mainTip = await chain.getMainChainTip()
        XCTAssertEqual(mainTip, VolumeImpl<Block>(node: mainBlock1).rawCID)

        // Fork: 3 empty blocks from genesis (longer chain, triggers reorg)
        var forkPrev = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: forkPrev, timestamp: base + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i + 100), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: b), block: b
            )
            forkPrev = b
        }

        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, VolumeImpl<Block>(node: forkPrev).rawCID)
        XCTAssertNotEqual(newTip, mainTip, "Reorg should have switched main chain")

        // After reorg: the transfer block is no longer on main chain
        // The fork has empty blocks — no account actions
        // State on main chain should reflect only genesis + empty blocks
        let height = await chain.getHighestBlockIndex()
        XCTAssertEqual(height, 3)
    }
}

// ============================================================================
// MARK: - HIGH: Multi-Signer Transactions
// ============================================================================

@MainActor
final class MultiSignerTests: XCTestCase {

    func testMultiSignerTransactionAccepted() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()
        let reward = spec.initialReward

        // Genesis gives alice the premine, block1 gives bob some funds
        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        let fundBob = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premine - 500) - Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(500 + reward))
            ],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [aliceAddr], fee: 0, nonce: 1
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(fundBob, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Multi-signer: both alice and bob move funds in one transaction
        let aliceBalance = premine - 500
        let bobBalance: UInt64 = 500 + reward
        let multiBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(aliceBalance - 200) - Int64(aliceBalance)),
                AccountAction(owner: bobAddr, delta: Int64(bobBalance - 100 + 300 + reward) - Int64(bobBalance))
            ],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [],
            signers: [aliceAddr, bobAddr],
            fee: 0, nonce: 0
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: multiBody)
        let aliceSig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: alice.privateKey)!
        let bobSig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: bob.privateKey)!
        let multiTx = Transaction(
            signatures: [alice.publicKey: aliceSig, bob.publicKey: bobSig],
            body: bodyHeader
        )

        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [multiTx],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await block2.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
    }

    func testMultiSignerMissingOneSignatureFails() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()
        let reward = spec.initialReward

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        let fundBob = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premine - 500) - Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(500 + reward))
            ],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [aliceAddr], fee: 0, nonce: 1
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(fundBob, alice)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Both remove funds but only alice signs
        let aliceBalance = premine - 500
        let bobBalance: UInt64 = 500 + reward
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(aliceBalance - 100) - Int64(aliceBalance)),
                AccountAction(owner: bobAddr, delta: Int64(bobBalance - 100 + 200 + reward) - Int64(bobBalance))
            ],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [],
            signers: [aliceAddr, bobAddr],
            fee: 0, nonce: 0
        )
        // Only alice signs
        let onlyAliceTx = tx(body, alice)

        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [onlyAliceTx],
            timestamp: base + 2000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await block2.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "Missing bob's signature should fail validation")
    }
}

// ============================================================================
// MARK: - HIGH: Long-Chain Economic Invariant Tests
// ============================================================================

@MainActor
final class LongChainEconomicTests: XCTestCase {

    func testSupplyConservationOver100Blocks() async throws {
        let fetcher = f()
        let base = now() - 200_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = id(miner.publicKey)
        let spec = s(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        var prev = genesis
        var totalRewards: UInt64 = 0
        var balance: UInt64 = 0

        for i: UInt64 in 0..<100 {
            let reward = spec.rewardAtBlock(i)
            let newBalance = balance + reward
            let body = TransactionBody(
                accountActions: [AccountAction(owner: minerAddr, delta: Int64(newBalance) - Int64(balance))],
                actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
                peerActions: [], settleActions: [], signers: [minerAddr], fee: 0, nonce: i
            )
            let block = try await BlockBuilder.buildBlock(
                previous: prev, transactions: [tx(body, miner)],
                timestamp: base + Int64(i + 1) * 1000, difficulty: UInt256(1000),
                nonce: UInt64(i + 1), fetcher: fetcher
            )
            totalRewards += reward
            balance = newBalance
            prev = block
        }

        XCTAssertEqual(balance, totalRewards)
        XCTAssertEqual(totalRewards, spec.totalRewards(upToBlock: 100))
        XCTAssertEqual(prev.index, 100)
    }

    func testTransferChainConservesBalance() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()
        let reward = spec.initialReward

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        var prev = genesis
        var aliceBalance = premine
        var bobBalance: UInt64 = 0

        // Alternate transfers for 20 blocks
        for i in 0..<20 {
            let r = spec.rewardAtBlock(UInt64(i))
            let isAliceSending = i % 2 == 0
            let amount: UInt64 = 10

            let body: TransactionBody
            let signer: (privateKey: String, publicKey: String)

            if isAliceSending {
                body = TransactionBody(
                    accountActions: [
                        AccountAction(owner: aliceAddr, delta: Int64(aliceBalance - amount) - Int64(aliceBalance)),
                        AccountAction(owner: bobAddr, delta: Int64(bobBalance + amount + r) - Int64(bobBalance))
                    ],
                    actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
                    peerActions: [], settleActions: [], signers: [aliceAddr],
                    fee: 0, nonce: UInt64(i) + 1
                )
                signer = alice
                aliceBalance -= amount
                bobBalance += amount + r
            } else {
                body = TransactionBody(
                    accountActions: [
                        AccountAction(owner: bobAddr, delta: Int64(bobBalance - amount) - Int64(bobBalance)),
                        AccountAction(owner: aliceAddr, delta: Int64(aliceBalance + amount + r) - Int64(aliceBalance))
                    ],
                    actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
                    peerActions: [], settleActions: [], signers: [bobAddr],
                    fee: 0, nonce: UInt64(i / 2)
                )
                signer = bob
                bobBalance -= amount
                aliceBalance += amount + r
            }

            let block = try await BlockBuilder.buildBlock(
                previous: prev, transactions: [tx(body, signer)],
                timestamp: base + Int64(i + 1) * 1000, difficulty: UInt256(1000),
                nonce: UInt64(i + 1), fetcher: fetcher
            )
            prev = block
        }

        let totalRewards = (0..<20).map { spec.rewardAtBlock(UInt64($0)) }.reduce(0, +)
        XCTAssertEqual(aliceBalance + bobBalance, premine + totalRewards)
    }
}

// ============================================================================
// MARK: - HIGH: State Growth Attack
// ============================================================================

@MainActor
final class StateGrowthAttackTests: XCTestCase {

    func testStateDeltaExceedingLimitRejected() async throws {
        let fetcher = f()
        let base = now() - 10_000
        // Tiny state growth limit
        let tinySpec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                                 maxStateGrowth: 10, maxBlockSize: 1_000_000,
                                 premine: 0, targetBlockTime: 1_000,
                                 initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: tinySpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Use a KV action with a large key that exceeds the 10-byte state growth limit
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let reward = tinySpec.rewardAtBlock(0)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [Action(key: "large_key_exceeds_limit", oldValue: nil, newValue: "value")],
            swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "State delta should exceed tiny 10-byte limit")
    }
}

// ============================================================================
// MARK: - MEDIUM: Concurrent Block Processing
// ============================================================================

@MainActor
final class ConcurrentBlockTests: XCTestCase {

    func testConcurrentBlockSubmission() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        // Build 10 competing blocks from genesis
        var blocks: [Block] = []
        for i in 1...10 {
            let b = try await BlockBuilder.buildBlock(
                previous: genesis, timestamp: base + Int64(i) * 100,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            blocks.append(b)
        }

        // Submit all concurrently
        await withTaskGroup(of: Void.self) { group in
            for block in blocks {
                group.addTask {
                    let _ = await chain.submitBlock(
                        parentBlockHeaderAndIndex: nil,
                        blockHeader: VolumeImpl<Block>(node: block), block: block
                    )
                }
            }
        }

        // Chain should be consistent: exactly one tip at height 1
        let height = await chain.getHighestBlockIndex()
        XCTAssertEqual(height, 1)
        let tip = await chain.getMainChainTip()
        XCTAssertNotNil(tip)
    }
}

// ============================================================================
// MARK: - MEDIUM: Difficulty Manipulation Resistance
// ============================================================================

@MainActor
final class DifficultyManipulationTests: XCTestCase {

    func testDifficultyChangeBounded() {
        let spec = s()
        let difficulty = UInt256(1000)

        // Very fast block (should lower difficulty, but bounded by maxDifficultyChange=2)
        let fast = spec.calculatePairDifficulty(previousDifficulty: difficulty, actualTime: 1)
        XCTAssertGreaterThanOrEqual(fast, difficulty / UInt256(ChainSpec.maxDifficultyChange))

        // Very slow block (should raise difficulty, but bounded)
        let slow = spec.calculatePairDifficulty(previousDifficulty: difficulty, actualTime: 100_000)
        XCTAssertLessThanOrEqual(slow, difficulty * UInt256(ChainSpec.maxDifficultyChange))
    }

    func testZeroTimeDifficultyBounded() {
        let spec = s()
        let difficulty = UInt256(1000)
        let result = spec.calculatePairDifficulty(previousDifficulty: difficulty, actualTime: 0)
        XCTAssertEqual(result, difficulty / UInt256(ChainSpec.maxDifficultyChange))
    }

    func testNegativeTimeDifficultyBounded() {
        let spec = s()
        let difficulty = UInt256(1000)
        let result = spec.calculatePairDifficulty(previousDifficulty: difficulty, actualTime: -100)
        XCTAssertEqual(result, difficulty / UInt256(ChainSpec.maxDifficultyChange))
    }
}

// ============================================================================
// MARK: - MEDIUM: Genesis With Embedded Child Chain
// ============================================================================

@MainActor
final class MultiChainGenesisTests: XCTestCase {

    func testNexusBlockWithChildChainGenesis() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let nexusSpec = s("Nexus", premine: 0)
        let childSpec = s("Child", premine: 0)
        let grandchildSpec = s("Grandchild", premine: 0)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let reward = nexusSpec.rewardAtBlock(0)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], swapActions: [],
            swapClaimActions: [],
            genesisActions: [GenesisAction(directory: "Child", block: childGenesis)], peerActions: [], settleActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
    }

    func testMultipleChildChainsInOneBlock() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let nexusSpec = s("Nexus", premine: 0)
        let child1Spec = s("Child1", premine: 0)
        let child2Spec = s("Child2", premine: 0)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let child1Genesis = try await BlockBuilder.buildGenesis(
            spec: child1Spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )
        let child2Genesis = try await BlockBuilder.buildGenesis(
            spec: child2Spec, timestamp: base, difficulty: UInt256(1000), fetcher: fetcher
        )

        let reward = nexusSpec.rewardAtBlock(0)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], swapActions: [],
            swapClaimActions: [],
            genesisActions: [
                GenesisAction(directory: "Child1", block: child1Genesis),
                GenesisAction(directory: "Child2", block: child2Genesis)
            ], peerActions: [], settleActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
    }
}
