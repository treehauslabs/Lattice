import cashew
import Foundation

public let WITHDRAWAL_PROPERTIES = Set(["withdrawer", "demander"])

public struct WithdrawalAction: Codable, Sendable {
    public let withdrawer: String
    public let nonce: UInt128
    public let demander: String
    public let amountDemanded: UInt64
    public let amountWithdrawn: UInt64

    public init(withdrawer: String, nonce: UInt128, demander: String, amountDemanded: UInt64, amountWithdrawn: UInt64) {
        self.withdrawer = withdrawer
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.amountWithdrawn = amountWithdrawn
    }
    
    func stateDelta() -> Int {
        withdrawer.utf8.count + demander.utf8.count + 32
    }
    
    public func totalSize() -> Int? {
        guard let withdrawerKeySize = withdrawer.toData()?.count else { return nil }
        guard let demanderKeySize = demander.toData()?.count else { return nil }
        guard let dataSize = toData()?.count else { return nil }
        return withdrawerKeySize + demanderKeySize + dataSize
    }
    
    public func toData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}
