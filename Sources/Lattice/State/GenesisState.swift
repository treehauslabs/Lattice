import cashew

public typealias GenesisState = VolumeMerkleDictionaryImpl<Block>
public typealias GenesisStateHeader = VolumeImpl<GenesisState>

public extension GenesisStateHeader {
    func proveAndUpdateState(allGenesisActions: [GenesisAction], fetcher: Fetcher) async throws -> GenesisStateHeader {
        if allGenesisActions.isEmpty { return self }

        var proofs = [[String]: SparseMerkleProof]()
        var transforms = [[String]: Transform]()
        for genesisAction in allGenesisActions {
            if proofs[[genesisAction.directory]] != nil { throw StateErrors.conflictingActions }
            proofs[[genesisAction.directory]] = .insertion
            transforms[[genesisAction.directory]] = .insert(String(genesisAction.block))
        }

        let proven = try await proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("genesis state transform returned nil")
        }
        return result
    }
}
