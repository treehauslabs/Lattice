import cashew

let TRANSACTION_BODY_PROPERTY = "body"
let TRANSACTION_PROPERTIES = Set([TRANSACTION_BODY_PROPERTY])

public struct Transaction {
    public let signatures: [String: String]
    public let body: HeaderImpl<TransactionBody>
    
    func signaturesAreValid() -> Bool {
        if signatures.isEmpty { return false }
        for (publicKeyHex, signature) in signatures {
            if !CryptoUtils.verify(message: body.rawCID, signature: signature, publicKeyHex: publicKeyHex) {
                return false
            }
        }
        return true
    }
    
    func signaturesMatchSigners() -> Bool {
        guard let bodyNode = body.node else { return false }
        let signatureHashes = Set(signatures.keys.map { HeaderImpl<PublicKey>(node: PublicKey(key: $0)).rawCID })
        for signer in bodyNode.signers {
            if !signatureHashes.contains(signer) { return false }
        }
        return true
    }
    
    func validateTransactionForGenesis(fetcher: Fetcher) async throws -> Bool {
        if !signaturesAreValid() { return false }
        let resolvedBody = try await body.resolve(fetcher: fetcher)
        if !signaturesMatchSigners() { return false }
        guard let bodyNode = resolvedBody.node else { throw ValidationErrors.transactionNotResolved }
        if !bodyNode.accountActionsAreValid() { return false }
        if !bodyNode.withdrawalActions.isEmpty { return false }
        return true
    }
    
    func validateTransactionForNexus(fetcher: Fetcher) async throws -> Bool {
        if !signaturesAreValid() { return false }
        let resolvedBody = try await body.resolve(fetcher: fetcher)
        if !signaturesMatchSigners() { return false }
        guard let bodyNode = resolvedBody.node else { throw ValidationErrors.transactionNotResolved }
        if !bodyNode.accountActionsAreValid() { return false }
        if !bodyNode.depositActions.isEmpty { return false }
        if !bodyNode.withdrawalActions.isEmpty { return false }
        return true
    }
    
    func validateTransaction(directory: String, homestead: LatticeState, parentState: LatticeState, fetcher: Fetcher) async throws -> Bool {
        if !signaturesAreValid() { return false }
        let resolvedBody = try await body.resolve(fetcher: fetcher)
        if !signaturesMatchSigners() { return false }
        guard let bodyNode = resolvedBody.node else { throw ValidationErrors.transactionNotResolved }
        if !bodyNode.accountActionsAreValid() { return false }
        if try await !bodyNode.withdrawalsAreValid(directory: directory, homestead: homestead, parentState: parentState, fetcher: fetcher) { return false }
        return true
    }
}

extension Transaction: Node {
    public func get(property: PathSegment) -> (any cashew.Header)? {
        if property == TRANSACTION_BODY_PROPERTY { return body }
        return nil
    }
    
    public func properties() -> Set<PathSegment> {
        return TRANSACTION_PROPERTIES
    }
    
    public func set(properties: [PathSegment : any cashew.Header]) -> Transaction {
        return Self(signatures: signatures, body: properties[TRANSACTION_BODY_PROPERTY] as! HeaderImpl<TransactionBody>)
    }
}
