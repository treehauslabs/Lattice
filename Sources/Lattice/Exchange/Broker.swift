import Foundation
import cashew

public actor Broker {
    public let orderBook: OrderBook
    private var pendingClaims: [MatchedOrder] = []

    public init() {
        self.orderBook = OrderBook()
    }

    // MARK: - Order Ingestion (gossip endpoint)

    public func receiveOrder(_ order: SignedOrder) async -> Bool {
        await orderBook.submit(order: order)
    }

    public func receiveCancellation(_ cancellation: OrderCancellation) async -> Bool {
        await orderBook.cancel(cancellation: cancellation)
    }

    // MARK: - Matching

    public func matchOrders(currentBlockIndex: UInt64) async -> [MatchedOrder] {
        let matches = await orderBook.findMatches(currentBlockIndex: currentBlockIndex)
        pendingClaims.append(contentsOf: matches)
        return matches
    }

    // MARK: - Phase 1: Lock + Settle (Block N)

    public func lockAndSettleTransaction(for matches: [MatchedOrder], chainPath: [String]) -> TransactionBody? {
        let valid = matches.filter { $0.isValid() }
        if valid.isEmpty { return nil }
        return TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [], fee: 0, nonce: 0,
            chainPath: chainPath, matchedOrders: valid
        )
    }

    // MARK: - Phase 2: Claim (Block N+1)

    public func drainPendingClaims() -> [MatchedOrder] {
        let claims = pendingClaims
        pendingClaims.removeAll()
        return claims
    }

    public func claimTransaction(for matches: [MatchedOrder], chainPath: [String]) -> TransactionBody? {
        let valid = matches.filter { $0.isValid() }
        if valid.isEmpty { return nil }
        return TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [], fee: 0, nonce: 0,
            chainPath: chainPath, claimedOrders: valid
        )
    }

    public func pendingClaimCount() -> Int {
        pendingClaims.count
    }
}
