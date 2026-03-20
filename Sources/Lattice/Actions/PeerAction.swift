import cashew
import Foundation

public struct PeerAction: Codable, Sendable {
    public let owner: String
    public let IpAddress: String
    public let refreshed: Int64
    public let fullNode: Bool
    public let type: PeerActionType
    
    func stateDelta() throws -> Int {
        guard let ownerKeyCount = owner.data(using: .utf8)?.count else { throw ValidationErrors.serializationError }
        guard let ipAddressCount = IpAddress.data(using: .utf8)?.count else { throw ValidationErrors.serializationError }
        return  ownerKeyCount + ipAddressCount + 13
    }
    
    public func totalSize() -> Int? {
        guard let ownerKeySize = owner.toData()?.count else { return nil }
        guard let dataSize = toData()?.count else { return nil }
        return ownerKeySize + dataSize
    }
    
    public func toData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}

public enum PeerActionType: Int, Codable, Sendable {
    case insert = 0, update, delete
}
