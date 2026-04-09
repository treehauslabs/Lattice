import cashew

public typealias AccountState = MerkleDictionaryImpl<UInt64>
public typealias AccountStateHeader = VolumeImpl<AccountState>

public extension AccountStateHeader {
    /// Aggregate deltas per owner, resolve current balances, apply net changes.
    /// Multiple actions on the same owner are summed — no conflictingActions.
    func proveAndUpdateState(allAccountActions: [AccountAction], fetcher: Fetcher) async throws -> AccountStateHeader {
        if allAccountActions.isEmpty { return self }

        // Aggregate deltas per owner (preserve insertion order)
        var ownerOrder: [String] = []
        var netDeltas: [String: Int64] = [:]
        for action in allAccountActions {
            if netDeltas[action.owner] == nil {
                ownerOrder.append(action.owner)
            }
            netDeltas[action.owner, default: 0] += action.delta
        }

        // Remove zero-net-delta owners (no state change needed)
        ownerOrder.removeAll { netDeltas[$0] == 0 }
        for key in netDeltas.keys where netDeltas[key] == 0 {
            netDeltas.removeValue(forKey: key)
        }
        if netDeltas.isEmpty { return self }

        // Resolve targeted paths to read current balances
        var resolvePaths = [[String]: ResolutionStrategy]()
        for owner in ownerOrder {
            resolvePaths[[owner]] = .targeted
        }
        let resolved = try await resolve(paths: resolvePaths, fetcher: fetcher)

        // Compute new balances and determine proof types
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
            // current == 0 && newBalance == 0 → no-op (net debit of zero on non-existent account)
        }

        if proofs.isEmpty { return resolved }

        let proven = try await resolved.proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("account state transform returned nil")
        }
        return result
    }
}
