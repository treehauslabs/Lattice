import cashew

public typealias GenesisState = MerkleDictionaryImpl<Block>
public typealias GenesisStateHeader = HeaderImpl<GenesisState>

public extension GenesisStateHeader {
    func prove(allGenesisActions: [GenesisAction], fetcher: Fetcher) async throws -> GenesisStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for genesisAction in allGenesisActions {
            if proofs[[genesisAction.directory]] != nil { throw StateErrors.conflictingActions }
            proofs[[genesisAction.directory]] = .insertion
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func updateState(allGenesisActions: [GenesisAction], fetcher: Fetcher) throws -> GenesisStateHeader {
        var transforms = [[String]: Transform]()
        for genesisAction in allGenesisActions {
            transforms[[genesisAction.directory]] = .insert(String(genesisAction.block))
        }
        guard let transformResult = try transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return transformResult
    }
    
    func proveAndUpdateState(allGenesisActions: [GenesisAction], fetcher: Fetcher) async throws -> GenesisStateHeader {
        let newHeader = try await prove(allGenesisActions: allGenesisActions, fetcher: fetcher)
        return try newHeader.updateState(allGenesisActions: allGenesisActions, fetcher: fetcher)
    }
}
