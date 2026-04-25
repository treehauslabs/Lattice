import cashew

public typealias AccountState = VolumeMerkleDictionaryImpl<UInt64>
public typealias AccountStateHeader = VolumeImpl<AccountState>

public extension AccountStateHeader {
    /// Aggregate deltas per owner, resolve current balances, apply net changes.
    /// Also advances per-signer nonce tracking via `_nonce_<prefix>` keys in
    /// the same trie (Ethereum-style per-account nonce).
    func proveAndUpdateState(
        allAccountActions: [AccountAction],
        transactionBodies: [TransactionBody] = [],
        fetcher: Fetcher
    ) async throws -> (AccountStateHeader, StateDiff) {
        // Aggregate deltas per owner (preserve insertion order)
        var ownerOrder: [String] = []
        var netDeltas: [String: Int64] = [:]
        for action in allAccountActions {
            if netDeltas[action.owner] == nil {
                ownerOrder.append(action.owner)
            }
            let (sum, overflow) = netDeltas[action.owner, default: 0].addingReportingOverflow(action.delta)
            guard !overflow else { throw StateErrors.balanceOverflow }
            netDeltas[action.owner] = sum
        }
        ownerOrder.removeAll { netDeltas[$0] == 0 }
        for key in netDeltas.keys where netDeltas[key] == 0 {
            netDeltas.removeValue(forKey: key)
        }

        // Group transactions by signer prefix, validate contiguous within batch
        var signerOrder: [String] = []
        var groups: [String: [TransactionBody]] = [:]
        for tx in transactionBodies {
            let prefix = Self.signerPrefix(tx)
            if groups[prefix] == nil { signerOrder.append(prefix) }
            groups[prefix, default: []].append(tx)
        }
        for prefix in signerOrder {
            groups[prefix]!.sort { $0.nonce < $1.nonce }
            let sorted = groups[prefix]!
            for i in 1..<sorted.count {
                if sorted[i].nonce != sorted[i - 1].nonce + 1 {
                    throw StateErrors.nonceGap
                }
            }
        }

        if netDeltas.isEmpty && signerOrder.isEmpty { return (self, .empty) }

        // Resolve targeted paths to read current balances + current nonces
        var resolvePaths = [[String]: ResolutionStrategy]()
        for owner in ownerOrder {
            resolvePaths[[owner]] = .targeted
        }
        for prefix in signerOrder {
            resolvePaths[[Self.nonceTrackingKey(prefix)]] = .targeted
        }
        let resolved = try await resolve(paths: resolvePaths, fetcher: fetcher)

        var proofs = [[String]: SparseMerkleProof]()
        var transforms = [[String]: Transform]()

        for owner in ownerOrder {
            let delta = netDeltas[owner]!
            let current: UInt64 = resolved.node.flatMap({ try? $0.get(key: owner) }) ?? 0

            let newBalance: UInt64
            if delta < 0 {
                let debit = UInt64(-delta)
                guard current >= debit else { throw StateErrors.insufficientBalance }
                newBalance = current - debit
            } else {
                let (result, overflow) = current.addingReportingOverflow(UInt64(delta))
                guard !overflow else { throw StateErrors.balanceOverflow }
                newBalance = result
            }

            if current == 0 && newBalance > 0 {
                proofs[[owner]] = .insertion
                transforms[[owner]] = .insert(String(newBalance))
            } else if current > 0 && newBalance == 0 {
                proofs[[owner]] = .deletion
                transforms[[owner]] = .delete
            } else if current > 0 && newBalance > 0 {
                proofs[[owner]] = .mutation
                transforms[[owner]] = .update(String(newBalance))
            }
            // current == 0 && newBalance == 0 → no-op
        }

        for prefix in signerOrder {
            let sorted = groups[prefix]!
            let nonceKey = Self.nonceTrackingKey(prefix)
            let currentNonce: UInt64? = resolved.node.flatMap { try? $0.get(key: nonceKey) }
            let expectedFirst: UInt64 = (currentNonce ?? 0) + (currentNonce != nil ? 1 : 0)
            guard sorted.first!.nonce == expectedFirst else {
                throw StateErrors.nonceGap
            }
            let newNonce = sorted.last!.nonce
            if currentNonce != nil {
                proofs[[nonceKey]] = .mutation
                transforms[[nonceKey]] = .update(String(newNonce))
            } else {
                proofs[[nonceKey]] = .insertion
                transforms[[nonceKey]] = .insert(String(newNonce))
            }
        }

        if proofs.isEmpty { return (resolved, .empty) }

        let proven = try await resolved.proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("account state transform returned nil")
        }
        return (result, diffCIDs(old: proven, new: result))
    }

    static func signerPrefix(_ transaction: TransactionBody) -> String {
        transaction.signers.sorted().joined(separator: ":")
    }

    static func nonceTrackingKey(_ prefix: String) -> String {
        "_nonce_" + prefix
    }
}
