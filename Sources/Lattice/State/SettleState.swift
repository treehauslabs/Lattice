import cashew

public struct SettleKey: LosslessStringConvertible {
    public let directory: String
    public let swapKey: String

    public init(directory: String, swapKey: String) {
        self.directory = directory
        self.swapKey = swapKey
    }

    public init(directory: String, swapAction: SwapAction) {
        self.directory = directory
        self.swapKey = SwapKey(swapAction: swapAction).description
    }

    public init(directory: String, swapClaimAction: SwapClaimAction) {
        self.directory = directory
        self.swapKey = SwapKey(swapClaimAction: swapClaimAction).description
    }

    public init?(_ description: String) {
        guard let firstSlash = description.firstIndex(of: ":") else { return nil }
        directory = String(description[description.startIndex..<firstSlash])
        swapKey = String(description[description.index(after: firstSlash)...])
        guard SwapKey(swapKey) != nil else { return nil }
    }

    public var description: String {
        return "\(directory):\(swapKey)"
    }
}

public typealias SettleState = MerkleDictionaryImpl<UInt64>
public typealias SettleStateHeader = HeaderImpl<SettleState>

public extension SettleStateHeader {
    func proveExistenceOfSettlement(directory: String, swapClaimActions: [SwapClaimAction], fetcher: Fetcher) async throws -> SettleStateHeader {
        let claims = swapClaimActions.filter { !$0.isRefund }
        if claims.isEmpty { return self }
        var proofs = [[String]: SparseMerkleProof]()
        for swapClaimAction in claims {
            let settleKey = SettleKey(directory: directory, swapClaimAction: swapClaimAction).description
            proofs[[settleKey]] = .mutation
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }

    func proveAndUpdateState(allSettleActions: [SettleAction], fetcher: Fetcher) async throws -> SettleStateHeader {
        if allSettleActions.isEmpty { return self }
        var proofs = [[String]: SparseMerkleProof]()
        for settleAction in allSettleActions {
            let settleKeyA = SettleKey(directory: settleAction.directoryA, swapKey: settleAction.swapKeyA).description
            let settleKeyB = SettleKey(directory: settleAction.directoryB, swapKey: settleAction.swapKeyB).description
            if proofs[[settleKeyA]] != nil { throw StateErrors.conflictingActions }
            if proofs[[settleKeyB]] != nil { throw StateErrors.conflictingActions }
            proofs[[settleKeyA]] = .insertion
            proofs[[settleKeyB]] = .insertion
        }
        let proven = try await proof(paths: proofs, fetcher: fetcher)
        var transforms = [[String]: Transform]()
        for settleAction in allSettleActions {
            let settleKeyA = SettleKey(directory: settleAction.directoryA, swapKey: settleAction.swapKeyA).description
            let settleKeyB = SettleKey(directory: settleAction.directoryB, swapKey: settleAction.swapKeyB).description
            transforms[[settleKeyA]] = .insert(String(settleAction.nonce))
            transforms[[settleKeyB]] = .insert(String(settleAction.nonce))
        }
        guard let transformResult = try proven.transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return transformResult
    }
}
