import cashew

public typealias TransactionState = MerkleDictionaryImpl<String>
public typealias TransactionStateHeader = VolumeImpl<TransactionState>

public extension TransactionStateHeader {
    func proveAndUpdateState(allTransactions: [TransactionBody], fetcher: Fetcher) async throws -> TransactionStateHeader {
        if allTransactions.isEmpty { return self }

        // Group transactions by signer prefix
        var groupOrder: [String] = []
        var groups: [String: [TransactionBody]] = [:]
        for tx in allTransactions {
            let prefix = TransactionStateHeader.signerPrefix(tx)
            if groups[prefix] == nil { groupOrder.append(prefix) }
            groups[prefix, default: []].append(tx)
        }

        // Sort each group by nonce and verify contiguous
        for prefix in groupOrder {
            groups[prefix]!.sort { $0.nonce < $1.nonce }
            let sorted = groups[prefix]!
            for i in 1..<sorted.count {
                if sorted[i].nonce != sorted[i - 1].nonce + 1 {
                    throw StateErrors.nonceGap
                }
            }
        }

        // Resolve current latest nonces via targeted resolution
        var resolvePaths = [[String]: ResolutionStrategy]()
        for prefix in groupOrder {
            resolvePaths[[TransactionStateHeader.nonceTrackingKey(prefix)]] = .targeted
        }
        let resolved = try await resolve(paths: resolvePaths, fetcher: fetcher)

        // Validate sequential nonces and build proofs + transforms
        var proofs = [[String]: SparseMerkleProof]()
        var transforms = [[String]: Transform]()

        for prefix in groupOrder {
            let sorted = groups[prefix]!
            let nonceKey = TransactionStateHeader.nonceTrackingKey(prefix)
            let currentNonce: UInt64? = resolved.node.flatMap { node in
                guard let val: String = try? node.get(key: nonceKey) else { return nil }
                return UInt64(val)
            }

            // First nonce must be exactly currentNonce + 1 (or 0 if no prior nonce)
            let expectedFirst: UInt64 = (currentNonce ?? 0) + (currentNonce != nil ? 1 : 0)
            guard sorted.first!.nonce == expectedFirst else {
                throw StateErrors.nonceGap
            }

            // Individual tx entry proofs (insertion — key must not exist)
            for tx in sorted {
                let txKey = TransactionStateHeader.transactionKey(tx)
                if proofs[[txKey]] != nil { throw StateErrors.conflictingActions }
                proofs[[txKey]] = .insertion
                transforms[[txKey]] = .insert(HeaderImpl<TransactionBody>(node: tx).rawCID)
            }

            // Nonce tracking key: insert if new, mutate if existing
            let newNonce = sorted.last!.nonce
            if currentNonce != nil {
                proofs[[nonceKey]] = .mutation
                transforms[[nonceKey]] = .update(String(newNonce))
            } else {
                proofs[[nonceKey]] = .insertion
                transforms[[nonceKey]] = .insert(String(newNonce))
            }
        }

        let proven = try await resolved.proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("transaction state transform returned nil")
        }
        return result
    }

    static func transactionKey(_ transaction: TransactionBody) -> String {
        let prefix = signerPrefix(transaction)
        return prefix + "/" + transaction.nonce.description
    }

    static func signerPrefix(_ transaction: TransactionBody) -> String {
        transaction.signers.sorted().joined(separator: ":")
    }

    static func nonceTrackingKey(_ prefix: String) -> String {
        "_nonce_" + prefix
    }
}
