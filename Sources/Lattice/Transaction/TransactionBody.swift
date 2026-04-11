import cashew
import CollectionConcurrencyKit
import Foundation
import JXKit

public struct TransactionBody: Scalar {
    public let accountActions: [AccountAction]
    public let actions: [Action]
    public let swapActions: [SwapAction]
    public let swapClaimActions: [SwapClaimAction]
    public let genesisActions: [GenesisAction]
    public let peerActions: [PeerAction]
    public let settleActions: [SettleAction]
    public let signers: [String]
    public let fee: UInt64
    public let nonce: UInt64
    public let chainPath: [String]
    public let matchedOrders: [MatchedOrder]
    public let claimedOrders: [MatchedOrder]

    enum CodingKeys: String, CodingKey {
        case accountActions, actions, swapActions, swapClaimActions
        case genesisActions, peerActions, settleActions
        case signers, fee, nonce, chainPath, matchedOrders, claimedOrders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountActions = try container.decode([AccountAction].self, forKey: .accountActions)
        actions = try container.decode([Action].self, forKey: .actions)
        swapActions = try container.decode([SwapAction].self, forKey: .swapActions)
        swapClaimActions = try container.decode([SwapClaimAction].self, forKey: .swapClaimActions)
        genesisActions = try container.decode([GenesisAction].self, forKey: .genesisActions)
        peerActions = try container.decode([PeerAction].self, forKey: .peerActions)
        settleActions = try container.decode([SettleAction].self, forKey: .settleActions)
        signers = try container.decode([String].self, forKey: .signers)
        fee = try container.decode(UInt64.self, forKey: .fee)
        nonce = try container.decode(UInt64.self, forKey: .nonce)
        chainPath = try container.decodeIfPresent([String].self, forKey: .chainPath) ?? []
        matchedOrders = try container.decodeIfPresent([MatchedOrder].self, forKey: .matchedOrders) ?? []
        claimedOrders = try container.decodeIfPresent([MatchedOrder].self, forKey: .claimedOrders) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountActions, forKey: .accountActions)
        try container.encode(actions, forKey: .actions)
        try container.encode(swapActions, forKey: .swapActions)
        try container.encode(swapClaimActions, forKey: .swapClaimActions)
        try container.encode(genesisActions, forKey: .genesisActions)
        try container.encode(peerActions, forKey: .peerActions)
        try container.encode(settleActions, forKey: .settleActions)
        try container.encode(signers, forKey: .signers)
        try container.encode(fee, forKey: .fee)
        try container.encode(nonce, forKey: .nonce)
        if !chainPath.isEmpty {
            try container.encode(chainPath, forKey: .chainPath)
        }
        if !matchedOrders.isEmpty {
            try container.encode(matchedOrders, forKey: .matchedOrders)
        }
        if !claimedOrders.isEmpty {
            try container.encode(claimedOrders, forKey: .claimedOrders)
        }
    }

    public init(accountActions: [AccountAction], actions: [Action], swapActions: [SwapAction], swapClaimActions: [SwapClaimAction], genesisActions: [GenesisAction], peerActions: [PeerAction], settleActions: [SettleAction], signers: [String], fee: UInt64, nonce: UInt64, chainPath: [String] = [], matchedOrders: [MatchedOrder] = [], claimedOrders: [MatchedOrder] = []) {
        self.accountActions = accountActions
        self.actions = actions
        self.swapActions = swapActions
        self.swapClaimActions = swapClaimActions
        self.genesisActions = genesisActions
        self.peerActions = peerActions
        self.settleActions = settleActions
        self.signers = signers
        self.fee = fee
        self.nonce = nonce
        self.chainPath = chainPath
        self.matchedOrders = matchedOrders
        self.claimedOrders = claimedOrders
    }

    func matchedOrdersAreValid() -> Bool {
        var totalFills: [UInt128: UInt64] = [:]
        // Uniform clearing price: all matches in the same directed pair must have the same rate
        // Rate is fillAmountB/fillAmountA — compare via cross-multiplication
        var pairRates: [String: (UInt64, UInt64)] = [:] // pair -> (fillA, fillB) of first match
        for match in matchedOrders {
            if !match.ordersAreCompatible() { return false }
            let pairKey = "\(match.orderA.order.sourceChain)>\(match.orderA.order.destChain)"
            if let (refA, refB) = pairRates[pairKey] {
                // fillB/fillA must equal refB/refA => fillB * refA == refB * fillA
                let lhs = UInt128(match.fillAmountB) &* UInt128(refA)
                let rhs = UInt128(refB) &* UInt128(match.fillAmountA)
                if lhs != rhs { return false }
            } else {
                pairRates[pairKey] = (match.fillAmountA, match.fillAmountB)
            }
            let (newA, ovA) = (totalFills[match.orderA.order.nonce] ?? 0).addingReportingOverflow(match.fillAmountA)
            if ovA || newA > match.orderA.order.sourceAmount { return false }
            totalFills[match.orderA.order.nonce] = newA
            let (newB, ovB) = (totalFills[match.orderB.order.nonce] ?? 0).addingReportingOverflow(match.fillAmountB)
            if ovB || newB > match.orderB.order.sourceAmount { return false }
            totalFills[match.orderB.order.nonce] = newB
        }
        var claimFills: [UInt128: UInt64] = [:]
        for match in claimedOrders {
            if !match.ordersAreCompatible() { return false }
            let (newA, ovA) = (claimFills[match.orderA.order.nonce] ?? 0).addingReportingOverflow(match.fillAmountA)
            if ovA || newA > match.orderA.order.sourceAmount { return false }
            claimFills[match.orderA.order.nonce] = newA
            let (newB, ovB) = (claimFills[match.orderB.order.nonce] ?? 0).addingReportingOverflow(match.fillAmountB)
            if ovB || newB > match.orderB.order.sourceAmount { return false }
            claimFills[match.orderB.order.nonce] = newB
        }
        return true
    }

    // MARK: - Order-Derived Actions

    func derivedSwapActions(forChain directory: String) -> [SwapAction] {
        var result: [SwapAction] = []
        for match in matchedOrders {
            if match.orderA.order.sourceChain == directory {
                result.append(match.swapActionA())
            }
            if match.orderB.order.sourceChain == directory {
                result.append(match.swapActionB())
            }
        }
        return result
    }

    func derivedSettleActions() -> [SettleAction] {
        matchedOrders.map { $0.settleAction() }
    }

    func derivedSwapClaimActions(forChain directory: String) -> [SwapClaimAction] {
        var result: [SwapClaimAction] = []
        for match in claimedOrders {
            if match.orderA.order.sourceChain == directory {
                result.append(match.claimForB())
            }
            if match.orderB.order.sourceChain == directory {
                result.append(match.claimForA())
            }
        }
        return result
    }

    func derivedAccountActions(forChain directory: String) -> [AccountAction] {
        var result: [AccountAction] = []
        for match in matchedOrders {
            if match.orderA.order.sourceChain == directory {
                result.append(AccountAction(owner: match.orderA.order.maker, delta: -Int64(match.fillAmountA + match.feeA)))
            }
            if match.orderB.order.sourceChain == directory {
                result.append(AccountAction(owner: match.orderB.order.maker, delta: -Int64(match.fillAmountB + match.feeB)))
            }
        }
        for match in claimedOrders {
            if match.orderA.order.sourceChain == directory {
                result.append(AccountAction(owner: match.orderB.order.maker, delta: Int64(match.fillAmountA)))
            }
            if match.orderB.order.sourceChain == directory {
                result.append(AccountAction(owner: match.orderA.order.maker, delta: Int64(match.fillAmountB)))
            }
        }
        return result
    }

    func derivedOrderFees(forChain directory: String) -> UInt64 {
        var total: UInt64 = 0
        for match in matchedOrders {
            if match.orderA.order.sourceChain == directory { total += match.feeA / 2 }
            if match.orderB.order.sourceChain == directory { total += match.feeB / 2 }
        }
        for match in claimedOrders {
            if match.orderA.order.sourceChain == directory { total += match.feeA - match.feeA / 2 }
            if match.orderB.order.sourceChain == directory { total += match.feeB - match.feeB / 2 }
        }
        return total
    }

    func swapActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for swapAction in swapActions {
            if swapAction.amount == 0 { return false }
            if !signerSet.contains(swapAction.sender) { return false }
        }
        return true
    }

    func settleActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for settleAction in settleActions {
            if !signerSet.contains(settleAction.senderA) { return false }
            if !signerSet.contains(settleAction.senderB) { return false }
            guard let parsedKeyA = SwapKey(settleAction.swapKeyA) else { return false }
            guard let parsedKeyB = SwapKey(settleAction.swapKeyB) else { return false }
            if parsedKeyA.sender != settleAction.senderA { return false }
            if parsedKeyB.sender != settleAction.senderB { return false }
            if parsedKeyA.recipient != settleAction.senderB { return false }
            if parsedKeyB.recipient != settleAction.senderA { return false }
        }
        return true
    }

    func swapClaimActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for swapClaimAction in swapClaimActions {
            if swapClaimAction.amount == 0 { return false }
            if swapClaimAction.isRefund {
                if !signerSet.contains(swapClaimAction.sender) { return false }
            } else {
                if !signerSet.contains(swapClaimAction.recipient) { return false }
            }
        }
        return true
    }

    func validateSwapClaims(directory: String, settleState: SettleStateHeader, blockIndex: UInt64, fetcher: Fetcher) async throws -> Bool {
        let allClaims = swapClaimActions + derivedSwapClaimActions(forChain: directory)
        if allClaims.isEmpty { return true }
        for claim in allClaims {
            if claim.isRefund {
                if blockIndex <= claim.timelock { return false }
            }
        }
        let nonRefundClaims = allClaims.filter { !$0.isRefund }
        if !nonRefundClaims.isEmpty {
            let _ = try await settleState.proveExistenceOfSettlement(directory: directory, swapClaimActions: nonRefundClaims, fetcher: fetcher)
        }
        return true
    }

    func genesisActionsAreValid(fetcher: Fetcher, parentSpec: ChainSpec? = nil) async throws -> Bool {
        return try await !genesisActions.concurrentMap { genesisAction in
            try await genesisAction.block.validateGenesis(fetcher: fetcher, directory: genesisAction.directory, parentSpec: parentSpec)
        }.contains(false)
    }

    func accountActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for action in accountActions where action.isDebit {
            if !signerSet.contains(action.owner) { return false }
        }
        return true
    }

    func getStateDelta() throws -> Int {
        var delta = 0
        for a in accountActions { delta += a.stateDelta() }
        for a in actions { delta += a.stateDelta() }
        for a in swapActions { delta += a.stateDelta() }
        for a in swapClaimActions { delta += a.stateDelta() }
        for a in genesisActions { delta += try a.stateDelta() }
        for a in peerActions { delta += a.stateDelta() }
        for a in settleActions { delta += a.stateDelta() }
        return delta
    }

    func verifyActionFilters(spec: ChainSpec) -> Bool {
        return actions.allSatisfy { $0.verifyFilters(spec: spec) }
    }

    func verifyFilters(spec: ChainSpec) -> Bool {
        return spec.transactionFilters.allSatisfy { verifyFilter($0) }
    }

    func verifyFilter(_ filter: String) -> Bool {
        do {
            let context = JXContext()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let transactionData = try? encoder.encode(self) else { return false }
            guard let transactionJSON = String(bytes: transactionData, encoding: .utf8) else { return false }
            try context.eval(filter)
            let fn = try context.global["transactionFilter"]
            let result = try fn.call(withArguments: [context.string(transactionJSON)])
            return try result.isBoolean ? result.bool : false
        } catch {
            return false
        }
    }

    static func batchVerifyFilters(bodies: [TransactionBody], spec: ChainSpec) -> Bool {
        if spec.transactionFilters.isEmpty { return true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonStrings = bodies.compactMap { body -> String? in
            guard let data = try? encoder.encode(body) else { return nil }
            return String(bytes: data, encoding: .utf8)
        }
        if jsonStrings.count != bodies.count { return false }
        do {
            for filter in spec.transactionFilters {
                let context = JXContext()
                try context.eval(filter)
                let fn = try context.global["transactionFilter"]
                for json in jsonStrings {
                    let result = try fn.call(withArguments: [context.string(json)])
                    if try !result.isBoolean || !result.bool { return false }
                }
            }
        } catch {
            return false
        }
        return true
    }

    static func batchVerifyActionFilters(bodies: [TransactionBody], spec: ChainSpec) -> Bool {
        if spec.actionFilters.isEmpty { return true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            for filter in spec.actionFilters {
                let context = JXContext()
                try context.eval(filter)
                let fn = try context.global["actionFilter"]
                for body in bodies {
                    for action in body.actions {
                        guard let data = try? encoder.encode(action) else { return false }
                        guard let json = String(bytes: data, encoding: .utf8) else { return false }
                        let result = try fn.call(withArguments: [context.string(json)])
                        if try !result.isBoolean || !result.bool { return false }
                    }
                }
            }
        } catch {
            return false
        }
        return true
    }
}
