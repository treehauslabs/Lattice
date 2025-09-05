import cashew

public let RECEIPT_PROPERTIES = Set(["withdrawer", "demander"])

public struct ReceiptAction {
    let withdrawer: HeaderImpl<PublicKey>
    let nonce: UInt128
    // cryptographic hash of demander public key
    let demander: HeaderImpl<PublicKey>
    // Total amount to send
    let amountDemanded: UInt64
    let directory: String
    
    init(withdrawer: HeaderImpl<PublicKey>, nonce: UInt128, demander: HeaderImpl<PublicKey>, amountDemanded: UInt64, directory: String) {
        self.withdrawer = withdrawer
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.directory = directory
    }
    
    func stateDelta() -> Int? {
        guard let withdrawerKeyHeaderCount = withdrawer.rawCID.data(using: .utf8)?.count else { return nil }
        guard let withdrawerKeyCount = withdrawer.node?.key.data(using: .utf8)?.count else { return nil }
        guard let demanderKeyHeaderCount = demander.rawCID.data(using: .utf8)?.count else { return nil }
        guard let demanderKeyCount = demander.node?.key.data(using: .utf8)?.count else { return nil }
        guard let directoryCount = directory.data(using: .utf8)?.count else { return nil }
        return withdrawerKeyHeaderCount + withdrawerKeyCount + demanderKeyHeaderCount + demanderKeyCount + directoryCount + 24
    }
    
    public func totalSize() -> Int? {
        guard let withdrawerKeySize = withdrawer.node?.key.toData()?.count else { return nil }
        guard let demanderKeySize = demander.node?.key.toData()?.count else { return nil }
        guard let dataSize = toData()?.count else { return nil }
        return withdrawerKeySize + demanderKeySize + dataSize
    }
}

extension ReceiptAction: Node {
    public func get(property: PathSegment) -> (any cashew.Address)? {
        switch property {
            case "withdrawer": return withdrawer
            case "demander": return demander
            default: return nil
        }
    }
    
    public func properties() -> Set<PathSegment> {
        return RECEIPT_PROPERTIES
    }
    
    public func set(properties: [PathSegment : any cashew.Address]) -> ReceiptAction {
        return Self(withdrawer: properties["withdrawer"] as! HeaderImpl<PublicKey>, nonce: nonce, demander: properties["demander"] as! HeaderImpl<PublicKey>, amountDemanded: amountDemanded, directory: directory)
    }
}
