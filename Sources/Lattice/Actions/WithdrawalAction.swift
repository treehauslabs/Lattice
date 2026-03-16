import cashew
import Foundation

public let WITHDRAWAL_PROPERTIES = Set(["withdrawer", "demander"])

public struct WithdrawalAction: Codable, Sendable {
    let withdrawer: String
    let nonce: UInt128
    // cryptographic hash of demander public key
    let demander: String
    let amountDemanded: UInt64
    let amountWithdrawn: UInt64
    
    init(withdrawer: String, nonce: UInt128, demander: String, amountDemanded: UInt64, amountWithdrawn: UInt64) {
        self.withdrawer = withdrawer
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.amountWithdrawn = amountWithdrawn
    }
    
    func stateDelta() throws -> Int {
        guard let withdrawerKeyCount = withdrawer.data(using: .utf8)?.count else { throw ValidationErrors.serializationError }
        guard let demanderKeyCount = demander.data(using: .utf8)?.count else { throw ValidationErrors.serializationError }
        return withdrawerKeyCount + demanderKeyCount + 32
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
