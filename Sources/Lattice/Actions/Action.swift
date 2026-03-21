import cashew
import Foundation
import JavaScriptCore

public struct Action: Codable, Sendable {
    public let key: String
    public let oldValue: String?
    public let newValue: String?

    public init(key: String, oldValue: String?, newValue: String?) {
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
    }
    
    public func stateDelta() -> Int {
        let keyCount = key.utf8.count
        if oldValue == nil {
            return newValue!.utf8.count + keyCount
        }
        if newValue == nil {
            return 0 - oldValue!.utf8.count - keyCount
        }
        return newValue!.utf8.count - oldValue!.utf8.count
    }
    
    public func verify() -> Bool {
        if key.isEmpty { return false }
        return oldValue != nil || newValue != nil
    }
    
    public func totalSize() throws -> Int {
        guard let dataSize = toData()?.count else { throw ValidationErrors.serializationError }
        return dataSize
    }
    
    public func toData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    func verifyFilters(spec: ChainSpec) -> Bool {
        return spec.actionFilters.allSatisfy { verifyFilter($0) }
    }

    func verifyFilter(_ filter: String) -> Bool {
        guard let context = JSContext() else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let actionData = try? encoder.encode(self) else { return false }
        guard let actionJson = String(bytes: actionData, encoding: .utf8) else { return false }
        context.evaluateScript(filter)
        guard let transactionFilter = context.objectForKeyedSubscript("actionFilter") else { return false }
        guard let result = transactionFilter.call(withArguments: [actionJson]) else { return false }
        return result.isBoolean ? result.toBool() : false
    }
}
