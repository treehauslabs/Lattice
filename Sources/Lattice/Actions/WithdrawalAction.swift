import cashew

public let WITHDRAWAL_PROPERTIES = Set(["withdrawer", "demander"])

public struct WithdrawalAction {
    let withdrawer: HeaderImpl<PublicKey>
    let nonce: UInt128
    // cryptographic hash of demander public key
    let demander: HeaderImpl<PublicKey>
    let amountDemanded: UInt64
    let amountWithdrawn: UInt64
    
    init(withdrawer: HeaderImpl<PublicKey>, nonce: UInt128, demander: HeaderImpl<PublicKey>, amountDemanded: UInt64, amountWithdrawn: UInt64) {
        self.withdrawer = withdrawer
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.amountWithdrawn = amountWithdrawn
    }
    
    func stateDelta() -> Int? {
        guard let withdrawerKeyHeaderCount = withdrawer.rawCID.data(using: .utf8)?.count else { return nil }
        guard let withdrawerKeyCount = withdrawer.node?.key.data(using: .utf8)?.count else { return nil }
        guard let demanderKeyHeaderCount = demander.rawCID.data(using: .utf8)?.count else { return nil }
        guard let demanderKeyCount = demander.node?.key.data(using: .utf8)?.count else { return nil }
        return withdrawerKeyHeaderCount + withdrawerKeyCount + demanderKeyHeaderCount + demanderKeyCount + 32
    }
    
    public func totalSize() -> Int? {
        guard let withdrawerKeySize = withdrawer.node?.key.toData()?.count else { return nil }
        guard let demanderKeySize = demander.node?.key.toData()?.count else { return nil }
        guard let dataSize = toData()?.count else { return nil }
        return withdrawerKeySize + demanderKeySize + dataSize
    }    
}

extension WithdrawalAction: Node {
    public func get(property: PathSegment) -> (any cashew.Address)? {
        switch property {
            case "withdrawer": return withdrawer
            case "demander": return demander
            default: return nil
        }
    }
    
    public func properties() -> Set<PathSegment> {
        return WITHDRAWAL_PROPERTIES
    }
    
    public func set(properties: [PathSegment : any cashew.Address]) -> WithdrawalAction {
        return Self(withdrawer: properties["withdrawer"] as! HeaderImpl<PublicKey>, nonce: nonce, demander: properties["demander"] as! HeaderImpl<PublicKey>, amountDemanded: amountDemanded, amountWithdrawn: amountWithdrawn)
    }
}
