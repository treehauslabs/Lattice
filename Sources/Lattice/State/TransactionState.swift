import cashew

public typealias TransactionState = MerkleDictionaryImpl<UInt64>
public typealias TransactionStateHeader = HeaderImpl<TransactionState>

public extension TransactionStateHeader {
    func prove(allTransactions: [TransactionBody], fetcher: Fetcher) async throws -> TransactionStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for transaction in allTransactions {
            if proofs[[transaction.nonce.description]] != nil { throw StateErrors.conflictingActions }
            proofs[[transaction.nonce.description]] = .insertion
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func updateState(allTransactions: [TransactionBody], fetcher: Fetcher) throws -> TransactionStateHeader {
        var transforms = [[String]: Transform]()
        for transaction in allTransactions {
            transforms[[transaction.nonce.description]] = .insert(HeaderImpl<TransactionBody>(node: transaction).rawCID)
        }
        guard let transformResult = try transform(transforms: transforms) else { throw TransformErrors.transformFailed }
        return transformResult
    }
    
    func proveAndUpdateState(allTransactions: [TransactionBody], fetcher: Fetcher) async throws -> TransactionStateHeader {
        let newHeader = try await prove(allTransactions: allTransactions, fetcher: fetcher)
        return try newHeader.updateState(allTransactions: allTransactions, fetcher: fetcher)
    }
}
