import cashew

let TRANSACTION_BODY_PROPERTY = "body"
let TRANSACTION_PROPERTIES = Set([TRANSACTION_BODY_PROPERTY])

public struct Transaction {
    // Public Key Hex -> Signature
    let signatures: [String: String]
    let body: HeaderImpl<TransactionBody>
    
    func signaturesAreValid() -> Bool {
        for (publicKeyHex, signature) in signatures {
            if !CryptoUtils.verify(message: body.rawCID, signature: signature, publicKeyHex: publicKeyHex) {
                return false
            }
        }
        return true
    }
}

extension Transaction: Node {
    public func get(property: PathSegment) -> (any cashew.Address)? {
        if property == TRANSACTION_BODY_PROPERTY { return body }
        return nil
    }
    
    public func properties() -> Set<PathSegment> {
        return TRANSACTION_PROPERTIES
    }
    
    public func set(properties: [PathSegment : any cashew.Address]) -> Transaction {
        return Self(signatures: signatures, body: properties[TRANSACTION_BODY_PROPERTY] as! HeaderImpl<TransactionBody>)
    }
}
