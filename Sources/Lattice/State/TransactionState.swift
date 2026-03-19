import cashew

public typealias TransactionState = MerkleDictionaryImpl<String>
public typealias TransactionStateHeader = HeaderImpl<TransactionState>

public extension TransactionStateHeader {
    func prove(allTransactions: [TransactionBody], fetcher: Fetcher) async throws -> TransactionStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for transaction in allTransactions {
            let key = TransactionStateHeader.transactionKey(transaction)
            if proofs[[key]] != nil { throw StateErrors.conflictingActions }
            proofs[[key]] = .insertion
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }

    func updateState(allTransactions: [TransactionBody], fetcher: Fetcher) throws -> TransactionStateHeader {
        var transforms = [[String]: Transform]()
        for transaction in allTransactions {
            let key = TransactionStateHeader.transactionKey(transaction)
            transforms[[key]] = .insert(HeaderImpl<TransactionBody>(node: transaction).rawCID)
        }
        guard let transformResult = try transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return transformResult
    }

    func proveAndUpdateState(allTransactions: [TransactionBody], fetcher: Fetcher) async throws -> TransactionStateHeader {
        let newHeader = try await prove(allTransactions: allTransactions, fetcher: fetcher)
        return try newHeader.updateState(allTransactions: allTransactions, fetcher: fetcher)
    }

    static func transactionKey(_ transaction: TransactionBody) -> String {
        let signerPrefix = transaction.signers.sorted().joined(separator: ":")
        return signerPrefix + "/" + transaction.nonce.description
    }
}
