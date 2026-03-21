import UInt256
import cashew
import CID
import Foundation

public struct AccountAction: Codable, Sendable {
    public let owner: String
    public let oldBalance: UInt64
    public let newBalance: UInt64

    public init(owner: String, oldBalance: UInt64, newBalance: UInt64) {
        self.owner = owner
        self.oldBalance = oldBalance
        self.newBalance = newBalance
    }
    
    public func verify() -> Bool {
        if oldBalance == newBalance { return false }
        return true
    }
    
    public func stateDelta() -> Int {
        let ownerCount = owner.utf8.count
        if newBalance == 0 {
            return 0 - ownerCount - 8
        }
        if oldBalance == 0 {
            return ownerCount + 8
        }
        return 0
    }
    
    public func totalSize() -> Int? {
        return toData()?.count
    }
    
    public func toData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}
