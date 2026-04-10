import cashew

let TRANSACTION_BODY_PROPERTY = "body"
let TRANSACTION_PROPERTIES = Set([TRANSACTION_BODY_PROPERTY])

struct SignatureEntry: Codable {
    let key: String
    let value: String
}

public struct Transaction {
    public let signatures: [String: String]
    public let body: HeaderImpl<TransactionBody>

    public init(signatures: [String: String], body: HeaderImpl<TransactionBody>) {
        self.signatures = signatures
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case signatures, body
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let sortedSigs = signatures.sorted { $0.key < $1.key }
            .map { SignatureEntry(key: $0.key, value: $0.value) }
        try container.encode(sortedSigs, forKey: .signatures)
        try container.encode(body, forKey: .body)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([SignatureEntry].self, forKey: .signatures)
        signatures = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        body = try container.decode(HeaderImpl<TransactionBody>.self, forKey: .body)
    }

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
        if !bodyNode.swapActions.isEmpty { return false }
        if !bodyNode.swapClaimActions.isEmpty { return false }
        if !bodyNode.settleActions.isEmpty { return false }
        return true
    }

    func validateTransactionForNexus(directory: String, homestead: LatticeState, blockIndex: UInt64, fetcher: Fetcher) async throws -> Bool {
        if !signaturesAreValid() { return false }
        let resolvedBody = try await body.resolve(fetcher: fetcher)
        if !signaturesMatchSigners() { return false }
        guard let bodyNode = resolvedBody.node else { throw ValidationErrors.transactionNotResolved }
        if bodyNode.chainPath != [directory] { return false }
        if !bodyNode.accountActionsAreValid() { return false }
        if !bodyNode.swapActionsAreValid() { return false }
        if !bodyNode.settleActionsAreValid() { return false }
        if !bodyNode.swapClaimActionsAreValid() { return false }
        if try await !bodyNode.swapClaimsAreValidForNexus(directory: directory, homestead: homestead, blockIndex: blockIndex, fetcher: fetcher) { return false }
        return true
    }

    func validateTransaction(directory: String, homestead: LatticeState, parentState: LatticeState, blockIndex: UInt64, chainPath: [String], fetcher: Fetcher) async throws -> Bool {
        if !signaturesAreValid() { return false }
        let resolvedBody = try await body.resolve(fetcher: fetcher)
        if !signaturesMatchSigners() { return false }
        guard let bodyNode = resolvedBody.node else { throw ValidationErrors.transactionNotResolved }
        if bodyNode.chainPath != chainPath { return false }
        if !bodyNode.accountActionsAreValid() { return false }
        if !bodyNode.swapActionsAreValid() { return false }
        if !bodyNode.settleActionsAreValid() { return false }
        if !bodyNode.swapClaimActionsAreValid() { return false }
        if try await !bodyNode.swapClaimsAreValid(directory: directory, homestead: homestead, parentState: parentState, blockIndex: blockIndex, fetcher: fetcher) { return false }
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
