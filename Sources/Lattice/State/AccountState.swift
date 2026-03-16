import cashew

public typealias AccountState = MerkleDictionaryImpl<UInt64>
public typealias AccountStateHeader = HeaderImpl<AccountState>

public extension AccountStateHeader {
    func prove(allAccountActions: [AccountAction], fetcher: Fetcher) async throws -> AccountStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for action in allAccountActions {
            if proofs[[action.owner]] != nil { throw StateErrors.conflictingActions }
            if action.newBalance == 0 {
                proofs[[action.owner]] = .deletion
            }
            if action.oldBalance == 0 {
                proofs[[action.owner]] = .insertion
            }
            proofs[[action.owner]] = .mutation
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func updateState(allAccountActions: [AccountAction], fetcher: Fetcher) throws -> AccountStateHeader {
        var transforms = [[String]: Transform]()
        for action in allAccountActions {
            if action.newBalance == 0 {
                transforms[[action.owner]] = .delete
                continue
            }
            if action.oldBalance == 0 {
                transforms[[action.owner]] = .insert(String(action.newBalance))
                continue
            }
            transforms[[action.owner]] = .update(String(action.newBalance))
        }
        guard let transformResult = try transform(transforms: transforms) else { throw TransformErrors.transformFailed }
        return transformResult
    }
    
    func proveAndUpdateState(allAccountActions: [AccountAction], fetcher: Fetcher) async throws -> AccountStateHeader {
        let newHeader = try await prove(allAccountActions: allAccountActions, fetcher: fetcher)
        return try newHeader.updateState(allAccountActions: allAccountActions, fetcher: fetcher)
    }
}
