import cashew
import Foundation

public struct Action: Codable, Sendable {
    let key: String
    let oldValue: String?
    let newValue: String?
    
    // WARNING: Should always run verify before this
    public func stateDelta() -> Int? {
        if oldValue == nil {
            guard let newCount = newValue!.data(using: .utf8)?.count else { return nil }
            guard let keyCount = key.data(using: .utf8)?.count else { return nil }
            return newCount + keyCount
        }
        if newValue == nil {
            guard let oldCount = oldValue!.data(using: .utf8)?.count else { return nil }
            guard let keyCount = key.data(using: .utf8)?.count else { return nil }
            return 0 - oldCount - keyCount
        }
        guard let oldCount = oldValue!.data(using: .utf8)?.count else { return nil }
        guard let newCount = newValue!.data(using: .utf8)?.count else { return nil }
        return newCount - oldCount
    }
    
    public func verify() -> Bool {
        if key.isEmpty { return false }
        return oldValue != nil || newValue != nil
    }
    
    public func totalSize() -> Int? {
        guard let dataSize = toData()?.count else { return nil }
        return dataSize
    }
}

extension Action: Scalar { }
