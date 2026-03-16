import cashew
import Foundation

public struct ReceiptAction: Codable, Sendable {
    let withdrawer: String
    let nonce: UInt128
    // cryptographic hash of demander public key
    let demander: String
    // Total amount to send
    let amountDemanded: UInt64
    let directory: String
    
    init(withdrawer: String, nonce: UInt128, demander: String, amountDemanded: UInt64, directory: String) {
        self.withdrawer = withdrawer
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.directory = directory
    }
    
    func stateDelta() throws -> Int {
        guard let withdrawerKeyCount = withdrawer.data(using: .utf8)?.count else { throw ValidationErrors.serializationError }
        guard let demanderKeyCount = demander.data(using: .utf8)?.count else { throw ValidationErrors.serializationError }
        guard let directoryCount = directory.data(using: .utf8)?.count else { throw ValidationErrors.serializationError }
        return withdrawerKeyCount + demanderKeyCount + directoryCount + 24
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
