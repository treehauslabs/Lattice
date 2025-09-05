import UInt256
import cashew
import CID

public struct AccountAction {
    let owner: HeaderImpl<PublicKey>
    let oldBalance: UInt64
    let newBalance: UInt64
    
    init(owner: HeaderImpl<PublicKey>, oldBalance: UInt64, newBalance: UInt64) {
        self.owner = owner
        self.oldBalance = oldBalance
        self.newBalance = newBalance
    }
    
    public func verify() -> Bool {
        if oldBalance == newBalance { return false }
        return true
    }
    
    public func stateDelta() -> Int? {
        guard let ownerKeyHeaderCount = owner.rawCID.data(using: .utf8)?.count else { return nil }
        guard let ownerKeyCount = owner.node?.key.count else { return nil }
        if newBalance == 0 {
            return 0 - ownerKeyCount - ownerKeyHeaderCount - 8
        }
        if oldBalance == 0 {
            return ownerKeyCount + ownerKeyHeaderCount + 8
        }
        return 0
    }
    
    public func totalSize() -> Int? {
        guard let ownerKeySize = owner.node?.key.toData()?.count else { return nil }
        guard let dataSize = toData()?.count else { return nil }
        return ownerKeySize + dataSize
    }
}

extension AccountAction: Node {
    public func get(property: PathSegment) -> (any cashew.Address)? {
        switch property {
            case "owner": return owner
            default: return nil
        }
    }
    
    public func properties() -> Set<PathSegment> {
        return Set(["owner"])
    }
    
    public func set(properties: [PathSegment : any cashew.Address]) -> AccountAction {
        return Self(owner: properties["owner"] as! HeaderImpl<PublicKey>, oldBalance: oldBalance, newBalance: newBalance)
    }
}
