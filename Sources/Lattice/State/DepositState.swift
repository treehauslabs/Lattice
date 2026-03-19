import cashew

public struct DepositKey: LosslessStringConvertible {
    let nonce: UInt128
    // cryptographic hash of recipient public key
    let demander: String
    // Total amount to send
    let amountDemanded: UInt64
    
    public init(depositAction: DepositAction) {
        nonce = depositAction.nonce
        demander = depositAction.demander
        amountDemanded = depositAction.amountDemanded
    }
    
    public init(nonce: UInt128, demander: String, amountDemanded: UInt64) {
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
    }
    
    public init?(_ description: String) {
        let split = description.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        guard split.count >= 3 else { return nil }
        let demander = String(split[0])
        guard let amountDemanded = UInt64(String(split[1])) else { return nil }
        guard let nonce = UInt128(String(split[2])) else { return nil }
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
    }
    
    public var description: String {
        return "\(demander)/\(amountDemanded.description)/\(nonce.description)"
    }
}

public typealias DepositState = MerkleDictionaryImpl<UInt64>
public typealias DepositStateHeader = HeaderImpl<DepositState>

public extension DepositStateHeader {
    func proveExistenceOfCorrespondingDeposit(withdrawalActions: [WithdrawalAction], fetcher: Fetcher)  async throws -> DepositStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for withdrawalAction in withdrawalActions {
            let depositKey = DepositKey(withdrawalAction: withdrawalAction).description
            proofs[[depositKey]] = .mutation
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func prove(allDepositActions: [DepositAction], fetcher: Fetcher) async throws -> DepositStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for depositAction in allDepositActions {
            if depositAction.amountDeposited != depositAction.amountDemanded { throw StateErrors.conflictingActions }
            if depositAction.amountDeposited == 0 { throw StateErrors.conflictingActions }
            let depositKey = DepositKey(depositAction: depositAction).description
            if proofs[[depositKey]] != nil { throw StateErrors.conflictingActions }
            proofs[[depositKey]] = .insertion
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func updateState(allDepositActions: [DepositAction], fetcher: Fetcher) throws -> DepositStateHeader {
        var transforms = [[String]: Transform]()
        for depositAction in allDepositActions {
            let depositKey = DepositKey(depositAction: depositAction).description
            transforms[[depositKey]] = .insert(String(depositAction.amountDeposited))
        }
        guard let transformResult = try transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return transformResult
    }
    
    func proveAndUpdateState(allDepositActions: [DepositAction], fetcher: Fetcher) async throws -> DepositStateHeader {
        let newHeader = try await prove(allDepositActions: allDepositActions, fetcher: fetcher)
        return try newHeader.updateState(allDepositActions: allDepositActions, fetcher: fetcher)
    }
}
