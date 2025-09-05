import cashew

public struct PeerAction {
    let owner: HeaderImpl<PublicKey>
    let IpAddress: String
    let refreshed: Int64
    let fullNode: Bool
    let type: PeerActionType
    
    func stateDelta() -> Int? {
        guard let ownerKeyHeaderCount = owner.rawCID.data(using: .utf8)?.count else { return nil }
        guard let ownerKeyCount = owner.node?.key.data(using: .utf8)?.count else { return nil }
        guard let ipAddressCount = IpAddress.data(using: .utf8)?.count else { return nil }
        return ownerKeyHeaderCount + ownerKeyCount + ipAddressCount + 13
    }
    
    public func totalSize() -> Int? {
        guard let ownerKeySize = owner.node?.key.toData()?.count else { return nil }
        guard let dataSize = toData()?.count else { return nil }
        return ownerKeySize + dataSize
    }
}

public enum PeerActionType: Int, Codable, Sendable {
    case insert = 0, update, delete
}

extension PeerAction: Node {
    public func set(properties: [PathSegment : any cashew.Address]) -> PeerAction {
        return Self(owner: properties["owner"] as! HeaderImpl<PublicKey>, IpAddress: IpAddress, refreshed: refreshed, fullNode: fullNode, type: type)
    }
    
    public func get(property: PathSegment) -> (any cashew.Address)? {
        switch property {
            case "owner": return owner
            default: return nil
        }
    }
    
    public func properties() -> Set<PathSegment> {
        return Set(["owner"])
    }
}
