import UInt256
import cashew
import Foundation

public struct DepositAction: Codable, Sendable {
    // "id" of demand
    let nonce: UInt128
    // CID of recipient public key
    let demander: String
    // Total amount to send
    let amountDemanded: UInt64
    // Total amount deposited
    let amountDeposited: UInt64
    
    init(nonce: UInt128, demander: String, amountDemanded: UInt64, amountDeposited: UInt64) {
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.amountDeposited = amountDeposited
    }
    
    func stateDelta() -> Int {
        return 32 + demander.count
    }
    
    public func totalSize() -> Int? {
        return toData()?.count
    }
    
    public func toData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}
