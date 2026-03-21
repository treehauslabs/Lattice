import cashew
import Foundation

public struct SwapAction: Codable, Sendable {
    public let nonce: UInt128
    public let sender: String
    public let recipient: String
    public let amount: UInt64
    public let timelock: UInt64

    public init(nonce: UInt128, sender: String, recipient: String, amount: UInt64, timelock: UInt64) {
        self.nonce = nonce
        self.sender = sender
        self.recipient = recipient
        self.amount = amount
        self.timelock = timelock
    }

    func stateDelta() -> Int {
        return sender.utf8.count + recipient.utf8.count + 32
    }

    public func totalSize() -> Int? {
        return toData()?.count
    }

    public func toData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}

public struct SettleAction: Codable, Sendable {
    public let nonce: UInt128
    public let senderA: String
    public let senderB: String
    public let swapKeyA: String
    public let directoryA: String
    public let swapKeyB: String
    public let directoryB: String

    public init(nonce: UInt128, senderA: String, senderB: String, swapKeyA: String, directoryA: String, swapKeyB: String, directoryB: String) {
        self.nonce = nonce
        self.senderA = senderA
        self.senderB = senderB
        self.swapKeyA = swapKeyA
        self.directoryA = directoryA
        self.swapKeyB = swapKeyB
        self.directoryB = directoryB
    }

    func stateDelta() -> Int {
        return directoryA.utf8.count + swapKeyA.utf8.count + directoryB.utf8.count + swapKeyB.utf8.count + 32
    }

    public func totalSize() -> Int? {
        return toData()?.count
    }

    public func toData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}

public struct SwapClaimAction: Codable, Sendable {
    public let nonce: UInt128
    public let sender: String
    public let recipient: String
    public let amount: UInt64
    public let timelock: UInt64
    public let isRefund: Bool

    public init(nonce: UInt128, sender: String, recipient: String, amount: UInt64, timelock: UInt64, isRefund: Bool) {
        self.nonce = nonce
        self.sender = sender
        self.recipient = recipient
        self.amount = amount
        self.timelock = timelock
        self.isRefund = isRefund
    }

    func stateDelta() -> Int {
        return 0 - sender.utf8.count - recipient.utf8.count - 32
    }

    public func totalSize() -> Int? {
        return toData()?.count
    }

    public func toData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}
