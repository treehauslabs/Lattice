import cashew

public struct ReceiptKey: LosslessStringConvertible {
    let directory: String
    let nonce: UInt128
    // cryptographic hash of recipient public key
    let demander: String
    // Total amount to send
    let amountDemanded: UInt64
    
    init(receiptAction: ReceiptAction) {
        directory = receiptAction.directory
        nonce = receiptAction.nonce
        demander = receiptAction.demander
        amountDemanded = receiptAction.amountDemanded
    }
    
    public init?(_ description: String) {
        let split = description.split(separator: "/", maxSplits: 4, omittingEmptySubsequences: true)
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
        return "\(directory)/\(demander)/\(amountDemanded.description)\(nonce.description)"
    }
}

public typealias ReceiptState = MerkleDictionaryImpl<HeaderImpl<PublicKey>>
public typealias ReceiptStateHeader = HeaderImpl<ReceiptState>

public extension ReceiptStateHeader {
    func proveExistenceOfCorrespondingReceipt(directory: String, withdrawalActions: [WithdrawalAction], fetcher: Fetcher)  async throws -> ReceiptStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for withdrawalAction in withdrawalActions {
            let receiptKey = ReceiptKey(withdrawalAction: withdrawalAction, directory: directory).description
            proofs[[receiptKey]] = .mutation
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func prove(allReceiptActions: [ReceiptAction], fetcher: Fetcher) async throws -> ReceiptStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for receiptAction in allReceiptActions {
            let receiptKey = ReceiptKey(receiptAction: receiptAction).description
            if proofs[[receiptKey]] != nil { throw StateErrors.conflictingActions }
            proofs[[receiptKey]] = .insertion
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func updateState(allReceiptActions: [ReceiptAction], fetcher: Fetcher) throws -> ReceiptStateHeader {
        var transforms = [[String]: Transform]()
        for receiptAction in allReceiptActions {
            let receiptKey = ReceiptKey(receiptAction: receiptAction).description
            transforms[[receiptKey]] = .insert(receiptAction.withdrawer)
        }
        guard let transformResult = try transform(transforms: transforms) else { throw TransformErrors.transformFailed }
        return transformResult
    }
    
    func proveAndUpdateState(allReceiptActions: [ReceiptAction], fetcher: Fetcher) async throws -> ReceiptStateHeader {
        let newHeader = try await prove(allReceiptActions: allReceiptActions, fetcher: fetcher)
        return try newHeader.updateState(allReceiptActions: allReceiptActions, fetcher: fetcher)
    }
}
