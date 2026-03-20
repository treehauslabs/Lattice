import Foundation
import cashew

public actor Mempool {
    private var pending: [String: (transaction: Transaction, fee: UInt64, receivedAt: ContinuousClock.Instant)]
    private let maxSize: Int

    public init(maxSize: Int = 10_000) {
        self.pending = [:]
        self.maxSize = maxSize
    }

    public var count: Int { pending.count }

    public func add(transaction: Transaction) -> Bool {
        guard let body = transaction.body.node else { return false }
        if !transaction.signaturesAreValid() { return false }
        if !transaction.signaturesMatchSigners() { return false }

        let txCID = transaction.body.rawCID
        if pending[txCID] != nil { return false }

        if pending.count >= maxSize {
            evictLowestFee()
        }

        pending[txCID] = (
            transaction: transaction,
            fee: body.fee,
            receivedAt: .now
        )
        return true
    }

    public func remove(txCID: String) {
        pending.removeValue(forKey: txCID)
    }

    public func removeAll(txCIDs: Set<String>) {
        for cid in txCIDs {
            pending.removeValue(forKey: cid)
        }
    }

    public func contains(txCID: String) -> Bool {
        pending[txCID] != nil
    }

    public func selectTransactions(maxCount: Int) -> [Transaction] {
        let sorted = pending.values.sorted { $0.fee > $1.fee }
        return Array(sorted.prefix(maxCount).map { $0.transaction })
    }

    public func allTransactions() -> [Transaction] {
        pending.values.map { $0.transaction }
    }

    public func totalFees() -> UInt64 {
        pending.values.reduce(0) { $0 + $1.fee }
    }

    private func evictLowestFee() {
        guard let lowest = pending.min(by: { $0.value.fee < $1.value.fee }) else { return }
        pending.removeValue(forKey: lowest.key)
    }

    public func pruneExpired(olderThan age: Duration) {
        let cutoff = ContinuousClock.Instant.now - age
        let expired = pending.filter { $0.value.receivedAt < cutoff }
        for key in expired.keys {
            pending.removeValue(forKey: key)
        }
    }
}
