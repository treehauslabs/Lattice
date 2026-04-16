import cashew

public struct ReceiptKey: LosslessStringConvertible {
    public let directory: String
    public let nonce: UInt128
    public let demander: String
    public let amountDemanded: UInt64

    public init(receiptAction: ReceiptAction) {
        directory = receiptAction.directory
        nonce = receiptAction.nonce
        demander = receiptAction.demander
        amountDemanded = receiptAction.amountDemanded
    }

    public init(withdrawalAction: WithdrawalAction, directory: String) {
        self.directory = directory
        nonce = withdrawalAction.nonce
        demander = withdrawalAction.demander
        amountDemanded = withdrawalAction.amountDemanded
    }

    public init?(_ description: String) {
        let split = description.split(separator: "/", maxSplits: 4, omittingEmptySubsequences: true)
        guard split.count >= 4 else { return nil }
        let directory = String(split[0])
        let demander = String(split[1])
        guard let amountDemanded = UInt64(String(split[2])) else { return nil }
        guard let nonce = UInt128(String(split[3])) else { return nil }
        self.directory = directory
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
    }

    public var description: String {
        return "\(directory)/\(demander)/\(amountDemanded.description)/\(nonce.description)"
    }
}

public typealias ReceiptState = MerkleDictionaryImpl<HeaderImpl<PublicKey>>
public typealias ReceiptStateHeader = VolumeImpl<ReceiptState>

public extension ReceiptStateHeader {
    func proveExistenceAndVerifyWithdrawers(directory: String, withdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> ReceiptStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for withdrawalAction in withdrawalActions {
            let receiptKey = ReceiptKey(withdrawalAction: withdrawalAction, directory: directory).description
            proofs[[receiptKey]] = .mutation
        }
        let proven = try await proof(paths: proofs, fetcher: fetcher)
        guard let node = proven.node else { throw StateErrors.conflictingActions }
        for wa in withdrawalActions {
            let key = ReceiptKey(withdrawalAction: wa, directory: directory).description
            guard let stored: HeaderImpl<PublicKey> = try? node.get(key: key) else {
                throw StateErrors.conflictingActions
            }
            if stored.rawCID != wa.withdrawer { throw StateErrors.conflictingActions }
        }
        return proven
    }

    func proveAndDeleteCompletedReceipts(childWithdrawals: [String: [WithdrawalAction]], fetcher: Fetcher) async throws -> ReceiptStateHeader {
        if childWithdrawals.isEmpty { return self }
        var seenKeys = Set<String>()
        var proofs = [[String]: SparseMerkleProof]()
        var transforms = [[String]: Transform]()
        for (directory, actions) in childWithdrawals {
            for wa in actions {
                let key = ReceiptKey(withdrawalAction: wa, directory: directory).description
                if !seenKeys.insert(key).inserted { throw StateErrors.conflictingActions }
                proofs[[key]] = .deletion
                transforms[[key]] = .delete
            }
        }
        if proofs.isEmpty { return self }
        let proven = try await proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("receipt deletion transform returned nil")
        }
        return result
    }

    func proveAndUpdateState(allReceiptActions: [ReceiptAction], fetcher: Fetcher) async throws -> ReceiptStateHeader {
        if allReceiptActions.isEmpty { return self }
        var proofs = [[String]: SparseMerkleProof]()
        for receiptAction in allReceiptActions {
            let receiptKey = ReceiptKey(receiptAction: receiptAction).description
            if proofs[[receiptKey]] != nil { throw StateErrors.conflictingActions }
            proofs[[receiptKey]] = .insertion
        }
        let proven = try await proof(paths: proofs, fetcher: fetcher)
        var transforms = [[String]: Transform]()
        for receiptAction in allReceiptActions {
            let receiptKey = ReceiptKey(receiptAction: receiptAction).description
            transforms[[receiptKey]] = .insert(receiptAction.withdrawer)
        }
        guard let transformResult = try proven.transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return transformResult
    }
}
