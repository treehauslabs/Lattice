import cashew
import Foundation

public struct PeerValue: Scalar {
    public let IpAddress: String
    public let refreshed: Int64
    public let fullNode: Bool

    public init(IpAddress: String, refreshed: Int64, fullNode: Bool) {
        self.IpAddress = IpAddress
        self.refreshed = refreshed
        self.fullNode = fullNode
    }
    
    init(peerAction: PeerAction) {
        IpAddress = peerAction.IpAddress
        refreshed = peerAction.refreshed
        fullNode = peerAction.fullNode
    }
    
    public var description: String {
        guard let data = try? JSONEncoder().encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

public typealias PeerState = MerkleDictionaryImpl<PeerValue>
public typealias PeerStateHeader = VolumeImpl<PeerState>

public extension PeerStateHeader {
    func proveAndUpdateState(allPeerActions: [PeerAction], fetcher: Fetcher) async throws -> PeerStateHeader {
        if allPeerActions.isEmpty { return self }

        var proofs = [[String]: SparseMerkleProof]()
        var transforms = [[String]: Transform]()
        for action in allPeerActions {
            if proofs[[action.owner]] != nil { throw StateErrors.conflictingActions }
            switch action.type {
            case .delete:
                proofs[[action.owner]] = .deletion
                transforms[[action.owner]] = .delete
            case .insert:
                proofs[[action.owner]] = .insertion
                transforms[[action.owner]] = .insert(PeerValue(peerAction: action).description)
            case .update:
                proofs[[action.owner]] = .mutation
                transforms[[action.owner]] = .update(PeerValue(peerAction: action).description)
            }
        }

        let proven = try await proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("peer state transform returned nil")
        }
        return result
    }
}
