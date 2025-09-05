import cashew

public struct WithdrawalValue: Scalar {
    let withdrawer: HeaderImpl<PublicKey>
    let amountWithdrawn: UInt64
    
    init(withdrawer: HeaderImpl<PublicKey>, amountWithdrawn: UInt64) {
        self.withdrawer = withdrawer
        self.amountWithdrawn = amountWithdrawn
    }
}

public extension DepositKey {
    init(withdrawalAction: WithdrawalAction) {
        nonce = withdrawalAction.nonce
        demander = withdrawalAction.demander
        amountDemanded = withdrawalAction.amountDemanded
    }
}

public extension ReceiptKey {
    init(withdrawalAction: WithdrawalAction, directory: String) {
        self.directory = directory
        nonce = withdrawalAction.nonce
        demander = withdrawalAction.demander
        amountDemanded = withdrawalAction.amountDemanded
    }
}

public typealias WithdrawalState = MerkleDictionaryImpl<WithdrawalValue>
public typealias WithdrawalStateHeader = HeaderImpl<WithdrawalState>

public extension WithdrawalStateHeader {
    func prove(allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> WithdrawalStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for withdrawalAction in allWithdrawalActions {
            let depositKey = DepositKey(withdrawalAction: withdrawalAction).description
            if proofs[[depositKey]] != nil { throw StateErrors.conflictingActions }
            proofs[[depositKey]] = .insertion
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func updateState(allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) throws -> WithdrawalStateHeader {
        var transforms = [[String]: Transform]()
        for withdrawalAction in allWithdrawalActions {
            let depositKey = DepositKey(withdrawalAction: withdrawalAction).description
            transforms[[depositKey]] = .insert(String(WithdrawalValue(withdrawer: withdrawalAction.withdrawer, amountWithdrawn: withdrawalAction.amountWithdrawn)))
        }
        guard let transformResult = try transform(transforms: transforms) else { throw TransformErrors.transformFailed }
        return transformResult
    }
    
    func proveAndUpdateState(allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> WithdrawalStateHeader {
        let newHeader = try await prove(allWithdrawalActions: allWithdrawalActions, fetcher: fetcher)
        return try newHeader.updateState(allWithdrawalActions: allWithdrawalActions, fetcher: fetcher)
    }
}
