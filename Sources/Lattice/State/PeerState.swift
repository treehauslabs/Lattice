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
public typealias PeerStateHeader = HeaderImpl<PeerState>

public extension PeerStateHeader {
    func prove(allPeerActions: [PeerAction], fetcher: Fetcher) async throws -> PeerStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for action in allPeerActions {
            if proofs[[action.owner]] != nil { throw StateErrors.conflictingActions }
            switch action.type {
            case .delete: proofs[[action.owner]] = .deletion
            case .insert: proofs[[action.owner]] = .insertion
            case .update: proofs[[action.owner]] = .mutation
            }
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }
    
    func updateState(allPeerActions: [PeerAction], fetcher: Fetcher) throws -> PeerStateHeader {
        var transforms = [[String]: Transform]()
        for action in allPeerActions {
            switch action.type {
            case .delete: transforms[[action.owner]] = .delete
            case .insert: transforms[[action.owner]] = .insert(PeerValue(peerAction: action).description)
            case .update: transforms[[action.owner]] = .update(PeerValue(peerAction: action).description)
            }
        }
        guard let transformResult = try transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return transformResult
    }
    
    func proveAndUpdateState(allPeerActions: [PeerAction], fetcher: Fetcher) async throws -> PeerStateHeader {
        let newHeader = try await prove(allPeerActions: allPeerActions, fetcher: fetcher)
        return try newHeader.updateState(allPeerActions: allPeerActions, fetcher: fetcher)
    }
}
