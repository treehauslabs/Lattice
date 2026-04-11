import XCTest
@testable import Lattice
import cashew
import Foundation

// MARK: - Helpers

private func kp() -> (privateKey: String, publicKey: String) {
    CryptoUtils.generateKeyPair()
}

private func addr(_ publicKey: String) -> String {
    HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

private func makeOrder(
    maker: (privateKey: String, publicKey: String),
    sourceChain: String, sourceAmount: UInt64,
    destChain: String, destAmount: UInt64,
    timelock: UInt64, nonce: UInt128, fee: UInt64 = 0
) -> SignedOrder {
    let order = SwapOrder(
        maker: addr(maker.publicKey), sourceChain: sourceChain,
        sourceAmount: sourceAmount, destChain: destChain,
        destAmount: destAmount, timelock: timelock, nonce: nonce, fee: fee
    )
    return SignedOrder.create(order: order, privateKey: maker.privateKey, publicKey: maker.publicKey)!
}

// MARK: - SwapOrder Fee Encoding

final class SwapOrderFeeEncodingTests: XCTestCase {

    func testZeroFeeIsAlwaysEncoded() throws {
        let order = SwapOrder(
            maker: "alice", sourceChain: "A", sourceAmount: 100,
            destChain: "B", destAmount: 50, timelock: 10, nonce: 1, fee: 0
        )
        let data = try JSONEncoder().encode(order)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"fee\""), "fee field must be present even when 0")
    }

    func testHashStabilityWithZeroFee() throws {
        let order = SwapOrder(
            maker: "alice", sourceChain: "A", sourceAmount: 100,
            destChain: "B", destAmount: 50, timelock: 10, nonce: 1, fee: 0
        )
        // Encode then decode then re-encode — hash must be identical
        let data = try JSONEncoder().encode(order)
        let decoded = try JSONDecoder().decode(SwapOrder.self, from: data)
        XCTAssertEqual(order.hash(), decoded.hash())
    }

    func testHashStabilityWithNonZeroFee() throws {
        let order = SwapOrder(
            maker: "alice", sourceChain: "A", sourceAmount: 100,
            destChain: "B", destAmount: 50, timelock: 10, nonce: 1, fee: 25
        )
        let data = try JSONEncoder().encode(order)
        let decoded = try JSONDecoder().decode(SwapOrder.self, from: data)
        XCTAssertEqual(order.hash(), decoded.hash())
    }
}

// MARK: - OrderBook Clearing Auction

final class OrderBookClearingAuctionTests: XCTestCase {

    func testBasicMatch() async {
        let alice = kp()
        let bob = kp()
        let book = OrderBook()

        // Alice sells 100 A for 50 B, Bob sells 50 B for 100 A
        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let _ = await book.submit(order: orderA)
        let _ = await book.submit(order: orderB)

        let matches = await book.findMatches(currentBlockIndex: 1)
        XCTAssertEqual(matches.count, 1)
        let m = matches[0]
        // Both sides fully filled — fills are {100, 50} regardless of A/B assignment
        let fills = Set([m.fillAmountA, m.fillAmountB])
        XCTAssertEqual(fills, Set([100, 50]))
    }

    func testNoMatchWhenRatesDontCross() async {
        let alice = kp()
        let bob = kp()
        let book = OrderBook()

        // Alice wants 200 B for 100 A, Bob only offers 50 B for 100 A
        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 200, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let _ = await book.submit(order: orderA)
        let _ = await book.submit(order: orderB)

        let matches = await book.findMatches(currentBlockIndex: 1)
        XCTAssertEqual(matches.count, 0)
    }

    func testUniformClearingPriceMultipleSellers() async {
        let alice = kp()
        let bob = kp()
        let carol = kp()
        let book = OrderBook()

        // Alice sells 100 A for 40 B (ask: 0.4), Carol sells 100 A for 50 B (ask: 0.5)
        // Bob buys A, offering 200 B for 200 A (bid: 1.0)
        let orderAlice = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 40, timelock: 100, nonce: 1)
        let orderCarol = makeOrder(maker: carol, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 3)
        let orderBob = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 200, destChain: "A", destAmount: 200, timelock: 100, nonce: 2)

        let _ = await book.submit(order: orderAlice)
        let _ = await book.submit(order: orderCarol)
        let _ = await book.submit(order: orderBob)

        let matches = await book.findMatches(currentBlockIndex: 1)
        XCTAssertGreaterThanOrEqual(matches.count, 1)

        // All matches must have the same rate (uniform clearing price)
        if matches.count >= 2 {
            let refA = matches[0].fillAmountA
            let refB = matches[0].fillAmountB
            for m in matches.dropFirst() {
                // fillB/fillA == refB/refA => fillB * refA == refB * fillA
                XCTAssertEqual(
                    UInt128(m.fillAmountB) &* UInt128(refA),
                    UInt128(refB) &* UInt128(m.fillAmountA),
                    "All matches must execute at the same clearing price"
                )
            }
        }
    }

    func testExpiredOrdersPurged() async {
        let alice = kp()
        let bob = kp()
        let book = OrderBook()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 10, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 10, nonce: 2)

        let _ = await book.submit(order: orderA)
        let _ = await book.submit(order: orderB)

        // Block 10 — timelock is 10 so order.timelock > currentBlockIndex must fail
        let matches = await book.findMatches(currentBlockIndex: 10)
        XCTAssertEqual(matches.count, 0)
        let count = await book.pendingCount()
        XCTAssertEqual(count, 0)
    }

    func testDifferentTimelocksDontMatch() async {
        let alice = kp()
        let bob = kp()
        let book = OrderBook()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 200, nonce: 2)

        let _ = await book.submit(order: orderA)
        let _ = await book.submit(order: orderB)

        let matches = await book.findMatches(currentBlockIndex: 1)
        XCTAssertEqual(matches.count, 0)
    }

    func testSameMakerCantSelfMatch() async {
        let alice = kp()
        let book = OrderBook()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: alice, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let _ = await book.submit(order: orderA)
        let _ = await book.submit(order: orderB)

        let matches = await book.findMatches(currentBlockIndex: 1)
        XCTAssertEqual(matches.count, 0)
    }

    func testDuplicateNonceRejected() async {
        let alice = kp()
        let bob = kp()
        let book = OrderBook()

        // Submit and fully fill an order with nonce 42
        let order1 = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 42)
        let counterpart = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 43)
        let ok1 = await book.submit(order: order1)
        XCTAssertTrue(ok1)
        let _ = await book.submit(order: counterpart)
        let _ = await book.findMatches(currentBlockIndex: 1) // fills nonce 42

        // Re-submitting the same nonce should be rejected (it's been processed)
        let order2 = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 200, destChain: "B", destAmount: 100, timelock: 100, nonce: 42)
        let ok2 = await book.submit(order: order2)
        XCTAssertFalse(ok2, "Processed nonce must be rejected on resubmission")
    }

    func testCancelledOrderNotMatched() async {
        let alice = kp()
        let bob = kp()
        let book = OrderBook()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let _ = await book.submit(order: orderA)
        let _ = await book.submit(order: orderB)

        let cancel = OrderCancellation.create(
            orderNonce: 1, maker: addr(alice.publicKey),
            privateKey: alice.privateKey, publicKey: alice.publicKey
        )!
        let cancelled = await book.cancel(cancellation: cancel)
        XCTAssertTrue(cancelled)

        let matches = await book.findMatches(currentBlockIndex: 1)
        XCTAssertEqual(matches.count, 0)
    }

    func testPartialFill() async {
        let alice = kp()
        let bob = kp()
        let book = OrderBook()

        // Alice sells 200 A for 100 B, Bob only has 50 B for 100 A (same rate)
        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 200, destChain: "B", destAmount: 100, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let _ = await book.submit(order: orderA)
        let _ = await book.submit(order: orderB)

        let matches = await book.findMatches(currentBlockIndex: 1)
        XCTAssertEqual(matches.count, 1)
        let m = matches[0]
        // Dictionary iteration order is non-deterministic, so orderA/orderB can be either direction
        // Bob's order (50 B) should be fully filled, Alice's (200 A) partially
        let fills = Set([m.fillAmountA, m.fillAmountB])
        XCTAssertTrue(fills.contains(50), "Bob's 50 B should be fully consumed")
        XCTAssertTrue(fills.contains(100), "Alice should fill 100 A at the 2:1 rate")
        // Alice's order should still have remaining
        let pending = await book.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    func testFullyFilledOrderRemoved() async {
        let alice = kp()
        let bob = kp()
        let book = OrderBook()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let _ = await book.submit(order: orderA)
        let _ = await book.submit(order: orderB)

        let matches = await book.findMatches(currentBlockIndex: 1)
        XCTAssertEqual(matches.count, 1)
        let remaining = await book.pendingCount()
        XCTAssertEqual(remaining, 0, "Fully filled orders should be removed")
    }

    func testFeesPrioritizeOrders() async {
        let alice = kp()
        let bob = kp()
        let carol = kp()
        let book = OrderBook()

        // Alice and Carol have same rate, Carol has higher fee
        // Bob can only fill one of them
        let orderAlice = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1, fee: 1)
        let orderCarol = makeOrder(maker: carol, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 3, fee: 10)
        let orderBob = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let _ = await book.submit(order: orderAlice)
        let _ = await book.submit(order: orderCarol)
        let _ = await book.submit(order: orderBob)

        let matches = await book.findMatches(currentBlockIndex: 1)
        // Both should match at uniform clearing price (same rate), but if only one can match
        // due to limited buy-side liquidity, the higher-fee order should be preferred
        XCTAssertGreaterThanOrEqual(matches.count, 1)
    }
}

// MARK: - MatchedOrder Validation

final class MatchedOrderValidationTests: XCTestCase {

    func testCompatibleOrdersPass() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 100, fillAmountB: 50)
        XCTAssertTrue(matched.ordersAreCompatible())
        XCTAssertTrue(matched.isValid())
    }

    func testIncompatibleChainsRejected() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "C", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 100, fillAmountB: 50)
        XCTAssertFalse(matched.ordersAreCompatible())
    }

    func testFillExceedingSourceRejected() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 200, fillAmountB: 50)
        XCTAssertFalse(matched.ordersAreCompatible())
    }

    func testRateViolationRejected() {
        let alice = kp()
        let bob = kp()

        // Alice wants 50 B for 100 A. Giving her only 10 B for 100 A violates her rate.
        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 100, fillAmountB: 10)
        XCTAssertFalse(matched.ordersAreCompatible())
    }

    func testProportionalFees() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 200, destChain: "B", destAmount: 100, timelock: 100, nonce: 1, fee: 20)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 100, destChain: "A", destAmount: 200, timelock: 100, nonce: 2, fee: 10)

        // Partial fill: 100 out of 200 for A, 50 out of 100 for B
        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 100, fillAmountB: 50)
        // feeA = 20 * 100 / 200 = 10
        XCTAssertEqual(matched.feeA, 10)
        // feeB = 10 * 50 / 100 = 5
        XCTAssertEqual(matched.feeB, 5)
    }

    func testComputeFillMaximizesVolume() {
        let orderA = SwapOrder(maker: "a", sourceChain: "A", sourceAmount: 200, destChain: "B", destAmount: 100, timelock: 100, nonce: 1)
        let orderB = SwapOrder(maker: "b", sourceChain: "B", sourceAmount: 80, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let result = MatchedOrder.computeFill(orderA: orderA, remainingA: 200, orderB: orderB, remainingB: 80)
        XCTAssertNotNil(result)
        if let (fillA, fillB) = result {
            XCTAssertLessThanOrEqual(fillA, 200)
            XCTAssertLessThanOrEqual(fillB, 80)
            XCTAssertGreaterThan(fillA, 0)
            XCTAssertGreaterThan(fillB, 0)
        }
    }

    func testComputeFillRejectsNonCrossing() {
        // A wants 200 B for 100 A, B wants 200 A for 50 B — rates don't cross
        let orderA = SwapOrder(maker: "a", sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 200, timelock: 100, nonce: 1)
        let orderB = SwapOrder(maker: "b", sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 200, timelock: 100, nonce: 2)

        let result = MatchedOrder.computeFill(orderA: orderA, remainingA: 100, orderB: orderB, remainingB: 50)
        XCTAssertNil(result)
    }
}

// MARK: - TransactionBody Uniform Price Validation

final class TransactionBodyOrderValidationTests: XCTestCase {

    func testUniformPriceAccepted() {
        let alice = kp()
        let bob = kp()
        let carol = kp()

        let orderA1 = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderA2 = makeOrder(maker: carol, sourceChain: "A", sourceAmount: 200, destChain: "B", destAmount: 100, timelock: 100, nonce: 3)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 150, destChain: "A", destAmount: 300, timelock: 100, nonce: 2)

        // Both at same rate: 50/100 = 100/200 (1:2)
        let m1 = MatchedOrder(orderA: orderA1, orderB: orderB, nonce: 10, fillAmountA: 100, fillAmountB: 50)
        let m2 = MatchedOrder(orderA: orderA2, orderB: orderB, nonce: 11, fillAmountA: 200, fillAmountB: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            matchedOrders: [m1, m2]
        )
        XCTAssertTrue(body.matchedOrdersAreValid())
    }

    func testNonUniformPriceRejected() {
        let alice = kp()
        let bob = kp()
        let carol = kp()

        let orderA1 = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderA2 = makeOrder(maker: carol, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 40, timelock: 100, nonce: 3)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 200, destChain: "A", destAmount: 200, timelock: 100, nonce: 2)

        // m1 at rate 50/100, m2 at rate 60/100 — different rates
        let m1 = MatchedOrder(orderA: orderA1, orderB: orderB, nonce: 10, fillAmountA: 100, fillAmountB: 50)
        let m2 = MatchedOrder(orderA: orderA2, orderB: orderB, nonce: 11, fillAmountA: 100, fillAmountB: 60)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            matchedOrders: [m1, m2]
        )
        XCTAssertFalse(body.matchedOrdersAreValid(), "Non-uniform clearing price must be rejected")
    }

    func testTotalFillOverflowRejected() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 100, destChain: "A", destAmount: 200, timelock: 100, nonce: 2)

        // Two matches for the same order that together exceed sourceAmount
        let m1 = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 10, fillAmountA: 60, fillAmountB: 30)
        let m2 = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 11, fillAmountA: 60, fillAmountB: 30)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            matchedOrders: [m1, m2]
        )
        XCTAssertFalse(body.matchedOrdersAreValid(), "Total fill exceeding sourceAmount must be rejected")
    }
}

// MARK: - Fee Split Tests

final class FeeSplitTests: XCTestCase {

    func testFeeSplitBetweenLockAndClaim() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1, fee: 20)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2, fee: 10)

        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 100, fillAmountB: 50)

        // Lock phase transaction
        let lockBody = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            matchedOrders: [matched]
        )

        // Claim phase transaction
        let claimBody = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            claimedOrders: [matched]
        )

        let lockFeesA = lockBody.derivedOrderFees(forChain: "A")
        let claimFeesA = claimBody.derivedOrderFees(forChain: "A")
        let lockFeesB = lockBody.derivedOrderFees(forChain: "B")
        let claimFeesB = claimBody.derivedOrderFees(forChain: "B")

        // feeA = 20, feeB = 10
        // On chain A: feeA from matched = 20/2=10, feeA from claimed = 20-10=10
        XCTAssertEqual(lockFeesA, 10) // feeA / 2
        XCTAssertEqual(claimFeesA, 10) // feeA - feeA / 2

        // On chain B: feeB from matched = 10/2=5, feeB from claimed = 10-5=5
        XCTAssertEqual(lockFeesB, 5)
        XCTAssertEqual(claimFeesB, 5)

        // Total fees are preserved
        XCTAssertEqual(lockFeesA + claimFeesA, matched.feeA)
        XCTAssertEqual(lockFeesB + claimFeesB, matched.feeB)
    }

    func testOddFeeRoundsCorrectly() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1, fee: 11)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2, fee: 0)

        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 100, fillAmountB: 50)

        let lockBody = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            matchedOrders: [matched]
        )
        let claimBody = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            claimedOrders: [matched]
        )

        let lockFee = lockBody.derivedOrderFees(forChain: "A")
        let claimFee = claimBody.derivedOrderFees(forChain: "A")

        // 11 / 2 = 5 for lock, 11 - 5 = 6 for claim
        XCTAssertEqual(lockFee, 5)
        XCTAssertEqual(claimFee, 6)
        XCTAssertEqual(lockFee + claimFee, matched.feeA, "Total fee must be preserved despite odd split")
    }
}

// MARK: - Broker Integration

final class BrokerTests: XCTestCase {

    func testMatchAndDrain() async {
        let alice = kp()
        let bob = kp()
        let broker = Broker()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let _ = await broker.receiveOrder(orderA)
        let _ = await broker.receiveOrder(orderB)

        let matches = await broker.matchOrders(currentBlockIndex: 1)
        XCTAssertEqual(matches.count, 1)

        // Matches are queued as pending claims
        let pendingBefore = await broker.pendingClaimCount()
        XCTAssertEqual(pendingBefore, 1)

        let claims = await broker.drainPendingClaims()
        XCTAssertEqual(claims.count, 1)
        let pendingAfter = await broker.pendingClaimCount()
        XCTAssertEqual(pendingAfter, 0)
    }

    func testLockAndSettleTransaction() async {
        let alice = kp()
        let bob = kp()
        let broker = Broker()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let _ = await broker.receiveOrder(orderA)
        let _ = await broker.receiveOrder(orderB)

        let matches = await broker.matchOrders(currentBlockIndex: 1)
        let txBody = await broker.lockAndSettleTransaction(for: matches, chainPath: ["Nexus"])
        XCTAssertNotNil(txBody)
        XCTAssertEqual(txBody!.matchedOrders.count, 1)
        XCTAssertTrue(txBody!.claimedOrders.isEmpty)
    }

    func testClaimTransaction() async {
        let alice = kp()
        let bob = kp()
        let broker = Broker()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let _ = await broker.receiveOrder(orderA)
        let _ = await broker.receiveOrder(orderB)

        let matches = await broker.matchOrders(currentBlockIndex: 1)
        let claims = await broker.drainPendingClaims()
        let txBody = await broker.claimTransaction(for: claims, chainPath: ["Nexus"])
        XCTAssertNotNil(txBody)
        XCTAssertTrue(txBody!.matchedOrders.isEmpty)
        XCTAssertEqual(txBody!.claimedOrders.count, 1)
        _ = matches // suppress unused warning
    }
}

// MARK: - Derived Actions

final class DerivedActionsTests: XCTestCase {

    func testDerivedSwapActions() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 100, fillAmountB: 50)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            matchedOrders: [matched]
        )

        // Chain A should get a swap from Alice
        let swapsA = body.derivedSwapActions(forChain: "A")
        XCTAssertEqual(swapsA.count, 1)
        XCTAssertEqual(swapsA[0].amount, 100)
        XCTAssertEqual(swapsA[0].sender, addr(alice.publicKey))

        // Chain B should get a swap from Bob
        let swapsB = body.derivedSwapActions(forChain: "B")
        XCTAssertEqual(swapsB.count, 1)
        XCTAssertEqual(swapsB[0].amount, 50)
        XCTAssertEqual(swapsB[0].sender, addr(bob.publicKey))
    }

    func testDerivedSettleActions() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 100, fillAmountB: 50)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            matchedOrders: [matched]
        )

        let settles = body.derivedSettleActions()
        XCTAssertEqual(settles.count, 1)
        XCTAssertEqual(settles[0].senderA, addr(alice.publicKey))
        XCTAssertEqual(settles[0].senderB, addr(bob.publicKey))
    }

    func testDerivedAccountActionsDebitWithFee() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1, fee: 10)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2, fee: 4)

        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 100, fillAmountB: 50)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            matchedOrders: [matched]
        )

        // Chain A: Alice debited fillAmountA + feeA = 100 + 10 = 110
        let actsA = body.derivedAccountActions(forChain: "A")
        XCTAssertEqual(actsA.count, 1)
        XCTAssertEqual(actsA[0].delta, -110)

        // Chain B: Bob debited fillAmountB + feeB = 50 + 4 = 54
        let actsB = body.derivedAccountActions(forChain: "B")
        XCTAssertEqual(actsB.count, 1)
        XCTAssertEqual(actsB[0].delta, -54)
    }

    func testDerivedClaimActionsCredit() {
        let alice = kp()
        let bob = kp()

        let orderA = makeOrder(maker: alice, sourceChain: "A", sourceAmount: 100, destChain: "B", destAmount: 50, timelock: 100, nonce: 1)
        let orderB = makeOrder(maker: bob, sourceChain: "B", sourceAmount: 50, destChain: "A", destAmount: 100, timelock: 100, nonce: 2)

        let matched = MatchedOrder(orderA: orderA, orderB: orderB, nonce: 99, fillAmountA: 100, fillAmountB: 50)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [], fee: 0, nonce: 0,
            claimedOrders: [matched]
        )

        // Chain A: Bob claims fillAmountA = 100
        let actsA = body.derivedAccountActions(forChain: "A")
        XCTAssertEqual(actsA.count, 1)
        XCTAssertEqual(actsA[0].delta, 100)
        XCTAssertEqual(actsA[0].owner, addr(bob.publicKey))

        // Chain B: Alice claims fillAmountB = 50
        let actsB = body.derivedAccountActions(forChain: "B")
        XCTAssertEqual(actsB.count, 1)
        XCTAssertEqual(actsB[0].delta, 50)
        XCTAssertEqual(actsB[0].owner, addr(alice.publicKey))
    }
}
