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
            } else if action.oldBalance == 0 {
                proofs[[action.owner]] = .insertion
            } else {
                proofs[[action.owner]] = .mutation
            }
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func updateState(allAccountActions: [AccountAction], fetcher: Fetcher) throws -> AccountStateHeader {
        if let dictNode = node {
            for action in allAccountActions {
                if action.oldBalance == 0 {
                    let existing = try? dictNode.get(key: action.owner)
                    if existing != nil { throw StateErrors.conflictingActions }
                } else {
                    guard let actual = try? dictNode.get(key: action.owner) else {
                        throw StateErrors.conflictingActions
                    }
                    guard String(describing: actual) == String(action.oldBalance) else {
                        throw StateErrors.conflictingActions
                    }
                }
            }
        }
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
        guard let transformResult = try transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return transformResult
    }
    
    func proveAndUpdateState(allAccountActions: [AccountAction], fetcher: Fetcher) async throws -> AccountStateHeader {
        let newHeader = try await prove(allAccountActions: allAccountActions, fetcher: fetcher)
        return try newHeader.updateState(allAccountActions: allAccountActions, fetcher: fetcher)
    }
}
