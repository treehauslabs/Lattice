import UInt256
import cashew

public let DEPOSIT_ACTION_PROPERTIES = Set(["demander"])

public struct DepositAction {
    // "id" of demand
    let nonce: UInt128
    // cryptographic hash of recipient public key
    let demander: HeaderImpl<PublicKey>
    // Total amount to send
    let amountDemanded: UInt64
    // Total amount deposited
    let amountDeposited: UInt64
    
    init(nonce: UInt128, demander: HeaderImpl<PublicKey>, amountDemanded: UInt64, amountDeposited: UInt64) {
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.amountDeposited = amountDeposited
    }
    
    func stateDelta() -> Int? {
        guard let demanderKeyHeaderCount = demander.rawCID.data(using: .utf8)?.count else { return nil }
        guard let demanderKeyCount = demander.node?.key.count else { return nil }
        return 32 + demanderKeyHeaderCount + demanderKeyCount
    }
    
    public func totalSize() -> Int? {
        guard let demanderKeySize = demander.node?.key.toData()?.count else { return nil }
        guard let dataSize = toData()?.count else { return nil }
        return demanderKeySize + dataSize
    }
}

extension DepositAction: Node {
    public func get(property: PathSegment) -> (any cashew.Address)? {
        switch property {
            case "demander": return demander
            default: return nil
        }
    }
    
    public func properties() -> Set<PathSegment> {
        return DEPOSIT_ACTION_PROPERTIES
    }
    
    public func set(properties: [PathSegment : any cashew.Address]) -> DepositAction {
        return Self(nonce: nonce, demander: properties["demander"] as! HeaderImpl<PublicKey>, amountDemanded: amountDemanded, amountDeposited: amountDeposited)
    }
}
