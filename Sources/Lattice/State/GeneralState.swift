import cashew

public typealias GeneralState = MerkleDictionaryImpl<String>
public typealias GeneralStateHeader = VolumeImpl<GeneralState>

public extension GeneralStateHeader {
    func prove(allActions: [Action], fetcher: Fetcher) async throws -> GeneralStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for action in allActions {
            if proofs[[action.key]] != nil { throw StateErrors.conflictingActions }
            if action.newValue == nil {
                proofs[[action.key]] = .deletion
            } else if action.oldValue == nil {
                proofs[[action.key]] = .insertion
            } else {
                proofs[[action.key]] = .mutation
            }
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func updateState(allActions: [Action], fetcher: Fetcher) throws -> GeneralStateHeader {
        if let dictNode = node {
            for action in allActions {
                if action.oldValue == nil {
                    let existing = try? dictNode.get(key: action.key)
                    if existing != nil { throw StateErrors.conflictingActions }
                } else {
                    guard let actual = try? dictNode.get(key: action.key) else {
                        throw StateErrors.conflictingActions
                    }
                    guard actual == action.oldValue else {
                        throw StateErrors.conflictingActions
                    }
                }
            }
        }
        var transforms = [[String]: Transform]()
        for action in allActions {
            if action.newValue == nil {
                transforms[[action.key]] = .delete
                continue
            }
            if action.oldValue == nil {
                transforms[[action.key]] = .insert(action.newValue!)
                continue
            }
            transforms[[action.key]] = .update(action.newValue!)
        }
        guard let transformResult = try transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return transformResult
    }
    
    func proveAndUpdateState(allActions: [Action], fetcher: Fetcher) async throws -> GeneralStateHeader {
        let newHeader = try await prove(allActions: allActions, fetcher: fetcher)
        return try newHeader.updateState(allActions: allActions, fetcher: fetcher)
    }
}

