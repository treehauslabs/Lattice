import cashew

public struct SwapKey: LosslessStringConvertible {
    public let nonce: UInt128
    public let sender: String
    public let recipient: String
    public let amount: UInt64
    public let timelock: UInt64

    public init(swapAction: SwapAction) {
        nonce = swapAction.nonce
        sender = swapAction.sender
        recipient = swapAction.recipient
        amount = swapAction.amount
        timelock = swapAction.timelock
    }

    public init(swapClaimAction: SwapClaimAction) {
        nonce = swapClaimAction.nonce
        sender = swapClaimAction.sender
        recipient = swapClaimAction.recipient
        amount = swapClaimAction.amount
        timelock = swapClaimAction.timelock
    }

    public init?(_ description: String) {
        let split = description.split(separator: "/", maxSplits: 5, omittingEmptySubsequences: true)
        guard split.count >= 5 else { return nil }
        sender = String(split[0])
        recipient = String(split[1])
        guard let amount = UInt64(String(split[2])) else { return nil }
        guard let timelock = UInt64(String(split[3])) else { return nil }
        guard let nonce = UInt128(String(split[4])) else { return nil }
        self.amount = amount
        self.timelock = timelock
        self.nonce = nonce
    }

    public var description: String {
        return "\(sender)/\(recipient)/\(amount)/\(timelock)/\(nonce)"
    }
}

public typealias SwapState = MerkleDictionaryImpl<UInt64>
public typealias SwapStateHeader = VolumeImpl<SwapState>

public extension SwapStateHeader {
    func proveAndUpdateState(allSwapActions: [SwapAction], allSwapClaimActions: [SwapClaimAction], fetcher: Fetcher) async throws -> SwapStateHeader {
        if allSwapActions.isEmpty && allSwapClaimActions.isEmpty { return self }
        var proofs = [[String]: SparseMerkleProof]()
        for swapAction in allSwapActions {
            if swapAction.amount == 0 { throw StateErrors.conflictingActions }
            let swapKey = SwapKey(swapAction: swapAction).description
            if proofs[[swapKey]] != nil { throw StateErrors.conflictingActions }
            proofs[[swapKey]] = .insertion
        }
        for swapClaimAction in allSwapClaimActions {
            let swapKey = SwapKey(swapClaimAction: swapClaimAction).description
            if proofs[[swapKey]] != nil { throw StateErrors.conflictingActions }
            proofs[[swapKey]] = .deletion
        }
        let proven = try await proof(paths: proofs, fetcher: fetcher)
        var transforms = [[String]: Transform]()
        for swapAction in allSwapActions {
            let swapKey = SwapKey(swapAction: swapAction).description
            transforms[[swapKey]] = .insert(String(swapAction.amount))
        }
        for swapClaimAction in allSwapClaimActions {
            let swapKey = SwapKey(swapClaimAction: swapClaimAction).description
            transforms[[swapKey]] = .delete
        }
        guard let transformResult = try proven.transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return transformResult
    }
}
