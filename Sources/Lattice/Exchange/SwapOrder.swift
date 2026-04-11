import cashew
import Foundation

// MARK: - Swap Order

public struct SwapOrder: Sendable {
    public let maker: String
    public let sourceChain: String
    public let sourceAmount: UInt64
    public let destChain: String
    public let destAmount: UInt64
    public let timelock: UInt64
    public let nonce: UInt128
    public let fee: UInt64

    enum CodingKeys: String, CodingKey {
        case maker, sourceChain, sourceAmount, destChain, destAmount, timelock, nonce, fee
    }

    public init(maker: String, sourceChain: String, sourceAmount: UInt64,
                destChain: String, destAmount: UInt64, timelock: UInt64, nonce: UInt128,
                fee: UInt64 = 0) {
        self.maker = maker
        self.sourceChain = sourceChain
        self.sourceAmount = sourceAmount
        self.destChain = destChain
        self.destAmount = destAmount
        self.timelock = timelock
        self.nonce = nonce
        self.fee = fee
    }

    public func hash() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return CryptoUtils.doubleSha256(json)
    }
}

extension SwapOrder: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maker = try container.decode(String.self, forKey: .maker)
        sourceChain = try container.decode(String.self, forKey: .sourceChain)
        sourceAmount = try container.decode(UInt64.self, forKey: .sourceAmount)
        destChain = try container.decode(String.self, forKey: .destChain)
        destAmount = try container.decode(UInt64.self, forKey: .destAmount)
        timelock = try container.decode(UInt64.self, forKey: .timelock)
        nonce = try container.decode(UInt128.self, forKey: .nonce)
        fee = try container.decodeIfPresent(UInt64.self, forKey: .fee) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maker, forKey: .maker)
        try container.encode(sourceChain, forKey: .sourceChain)
        try container.encode(sourceAmount, forKey: .sourceAmount)
        try container.encode(destChain, forKey: .destChain)
        try container.encode(destAmount, forKey: .destAmount)
        try container.encode(timelock, forKey: .timelock)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(fee, forKey: .fee)
    }
}

// MARK: - Signed Order

public struct SignedOrder: Codable, Sendable {
    public let order: SwapOrder
    public let publicKey: String
    public let signature: String

    public init(order: SwapOrder, publicKey: String, signature: String) {
        self.order = order
        self.publicKey = publicKey
        self.signature = signature
    }

    public static func create(order: SwapOrder, privateKey: String, publicKey: String) -> SignedOrder? {
        guard let signature = CryptoUtils.sign(message: order.hash(), privateKeyHex: privateKey) else {
            return nil
        }
        return SignedOrder(order: order, publicKey: publicKey, signature: signature)
    }

    public var makerAddress: String {
        HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
    }

    public func verify() -> Bool {
        guard CryptoUtils.verify(message: order.hash(), signature: signature, publicKeyHex: publicKey) else {
            return false
        }
        return makerAddress == order.maker
    }
}

// MARK: - Order Cancellation

public struct OrderCancellation: Codable, Sendable {
    public let orderNonce: UInt128
    public let maker: String
    public let publicKey: String
    public let signature: String

    public init(orderNonce: UInt128, maker: String, publicKey: String, signature: String) {
        self.orderNonce = orderNonce
        self.maker = maker
        self.publicKey = publicKey
        self.signature = signature
    }

    public static func create(orderNonce: UInt128, maker: String, privateKey: String, publicKey: String) -> OrderCancellation? {
        let message = "cancel:\(orderNonce)"
        guard let signature = CryptoUtils.sign(message: CryptoUtils.doubleSha256(message), privateKeyHex: privateKey) else {
            return nil
        }
        return OrderCancellation(orderNonce: orderNonce, maker: maker, publicKey: publicKey, signature: signature)
    }

    public func verify() -> Bool {
        let message = "cancel:\(orderNonce)"
        guard CryptoUtils.verify(message: CryptoUtils.doubleSha256(message), signature: signature, publicKeyHex: publicKey) else {
            return false
        }
        return HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID == maker
    }
}

// MARK: - Matched Order

public struct MatchedOrder: Sendable {
    public let orderA: SignedOrder
    public let orderB: SignedOrder
    public let nonce: UInt128
    public let fillAmountA: UInt64
    public let fillAmountB: UInt64

    public init(orderA: SignedOrder, orderB: SignedOrder, nonce: UInt128,
                fillAmountA: UInt64, fillAmountB: UInt64) {
        self.orderA = orderA
        self.orderB = orderB
        self.nonce = nonce
        self.fillAmountA = fillAmountA
        self.fillAmountB = fillAmountB
    }

    enum CodingKeys: String, CodingKey {
        case orderA, orderB, nonce, fillAmountA, fillAmountB
    }

    public func ordersAreCompatible() -> Bool {
        guard orderA.order.sourceChain == orderB.order.destChain else { return false }
        guard orderA.order.destChain == orderB.order.sourceChain else { return false }
        guard orderA.order.maker != orderB.order.maker else { return false }
        guard orderA.order.timelock == orderB.order.timelock else { return false }
        guard orderA.order.timelock > 0 else { return false }
        guard fillAmountA > 0 && fillAmountB > 0 else { return false }
        guard fillAmountA <= orderA.order.sourceAmount else { return false }
        guard fillAmountB <= orderB.order.sourceAmount else { return false }
        // A's rate: fillAmountB / fillAmountA >= destAmount / sourceAmount
        let lhsA = UInt128(fillAmountB) &* UInt128(orderA.order.sourceAmount)
        let rhsA = UInt128(fillAmountA) &* UInt128(orderA.order.destAmount)
        guard lhsA >= rhsA else { return false }
        // B's rate: fillAmountA / fillAmountB >= destAmount / sourceAmount
        let lhsB = UInt128(fillAmountA) &* UInt128(orderB.order.sourceAmount)
        let rhsB = UInt128(fillAmountB) &* UInt128(orderB.order.destAmount)
        guard lhsB >= rhsB else { return false }
        return true
    }

    public func isValid() -> Bool {
        guard orderA.verify() && orderB.verify() else { return false }
        return ordersAreCompatible()
    }

    public var authorizedAddresses: Set<String> {
        [orderA.makerAddress, orderB.makerAddress]
    }

    // Proportional fee: fee * fillAmount / sourceAmount (floor)
    public var feeA: UInt64 {
        guard orderA.order.sourceAmount > 0 else { return 0 }
        return UInt64(UInt128(orderA.order.fee) &* UInt128(fillAmountA) / UInt128(orderA.order.sourceAmount))
    }

    public var feeB: UInt64 {
        guard orderB.order.sourceAmount > 0 else { return 0 }
        return UInt64(UInt128(orderB.order.fee) &* UInt128(fillAmountB) / UInt128(orderB.order.sourceAmount))
    }

    // Derive SwapAction: order A's maker locks fillAmountA on their source chain
    public func swapActionA() -> SwapAction {
        SwapAction(
            nonce: orderA.order.nonce,
            sender: orderA.order.maker,
            recipient: orderB.order.maker,
            amount: fillAmountA,
            timelock: orderA.order.timelock
        )
    }

    // Derive SwapAction: order B's maker locks fillAmountB on their source chain
    public func swapActionB() -> SwapAction {
        SwapAction(
            nonce: orderB.order.nonce,
            sender: orderB.order.maker,
            recipient: orderA.order.maker,
            amount: fillAmountB,
            timelock: orderB.order.timelock
        )
    }

    // Derive SettleAction for Nexus
    public func settleAction() -> SettleAction {
        let swapKeyA = SwapKey(swapAction: swapActionA()).description
        let swapKeyB = SwapKey(swapAction: swapActionB()).description
        return SettleAction(
            nonce: nonce,
            senderA: orderA.order.maker,
            senderB: orderB.order.maker,
            swapKeyA: swapKeyA,
            directoryA: orderA.order.sourceChain,
            swapKeyB: swapKeyB,
            directoryB: orderB.order.sourceChain
        )
    }

    // Derive claim: order A's maker claims fillAmountB on B's source chain
    public func claimForA() -> SwapClaimAction {
        SwapClaimAction(
            nonce: orderB.order.nonce,
            sender: orderB.order.maker,
            recipient: orderA.order.maker,
            amount: fillAmountB,
            timelock: orderB.order.timelock,
            isRefund: false
        )
    }

    // Derive claim: order B's maker claims fillAmountA on A's source chain
    public func claimForB() -> SwapClaimAction {
        SwapClaimAction(
            nonce: orderA.order.nonce,
            sender: orderA.order.maker,
            recipient: orderB.order.maker,
            amount: fillAmountA,
            timelock: orderA.order.timelock,
            isRefund: false
        )
    }

    // Compute fill amounts that maximize volume for two crossing orders
    public static func computeFill(
        orderA: SwapOrder, remainingA: UInt64,
        orderB: SwapOrder, remainingB: UInt64
    ) -> (fillA: UInt64, fillB: UInt64)? {
        guard remainingA > 0 && remainingB > 0 else { return nil }
        // Crossing condition: sA * sB >= dA * dB (using original order amounts for rate)
        let lhs = UInt128(orderA.sourceAmount) &* UInt128(orderB.sourceAmount)
        let rhs = UInt128(orderA.destAmount) &* UInt128(orderB.destAmount)
        guard lhs >= rhs else { return nil }
        // Execute at A's rate to maximize volume
        // fillA limited by A's remaining and B's remaining converted at A's rate
        let maxFromB = UInt128(remainingB) &* UInt128(orderA.sourceAmount) / UInt128(orderA.destAmount)
        let fillA = min(UInt64(clamping: maxFromB), remainingA)
        guard fillA > 0 else { return nil }
        // fillB at A's rate (ceiling to ensure A gets at least their rate)
        let raw = UInt128(fillA) &* UInt128(orderA.destAmount)
        let fillB128 = (raw + UInt128(orderA.sourceAmount) - 1) / UInt128(orderA.sourceAmount)
        let fillB = UInt64(clamping: fillB128)
        guard fillB > 0 && fillB <= remainingB else { return nil }
        // Verify B's rate: fillA * sB >= fillB * dB
        let checkB = UInt128(fillA) &* UInt128(orderB.sourceAmount)
        let needB = UInt128(fillB) &* UInt128(orderB.destAmount)
        guard checkB >= needB else { return nil }
        return (fillA, fillB)
    }
}

extension MatchedOrder: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        orderA = try container.decode(SignedOrder.self, forKey: .orderA)
        orderB = try container.decode(SignedOrder.self, forKey: .orderB)
        nonce = try container.decode(UInt128.self, forKey: .nonce)
        fillAmountA = try container.decodeIfPresent(UInt64.self, forKey: .fillAmountA) ?? orderA.order.sourceAmount
        fillAmountB = try container.decodeIfPresent(UInt64.self, forKey: .fillAmountB) ?? orderB.order.sourceAmount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(orderA, forKey: .orderA)
        try container.encode(orderB, forKey: .orderB)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(fillAmountA, forKey: .fillAmountA)
        try container.encode(fillAmountB, forKey: .fillAmountB)
    }
}
