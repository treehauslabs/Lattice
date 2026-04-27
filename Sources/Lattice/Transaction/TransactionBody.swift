import cashew
import CollectionConcurrencyKit
import Foundation
import JXKit

public struct TransactionBody: Scalar {
    public let accountActions: [AccountAction]
    public let actions: [Action]
    public let depositActions: [DepositAction]
    public let genesisActions: [GenesisAction]
    public let peerActions: [PeerAction]
    public let receiptActions: [ReceiptAction]
    public let withdrawalActions: [WithdrawalAction]
    public let signers: [String]
    public let fee: UInt64
    public let nonce: UInt64
    public let chainPath: [String]

    public init(accountActions: [AccountAction], actions: [Action], depositActions: [DepositAction], genesisActions: [GenesisAction], peerActions: [PeerAction], receiptActions: [ReceiptAction], withdrawalActions: [WithdrawalAction], signers: [String], fee: UInt64, nonce: UInt64, chainPath: [String] = []) {
        self.accountActions = accountActions
        self.actions = actions
        self.depositActions = depositActions
        self.genesisActions = genesisActions
        self.peerActions = peerActions
        self.receiptActions = receiptActions
        self.withdrawalActions = withdrawalActions
        self.signers = signers
        self.fee = fee
        self.nonce = nonce
        self.chainPath = chainPath
    }

    func depositActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for depositAction in depositActions {
            if depositAction.amountDeposited == 0 { return false }
            if depositAction.amountDemanded == 0 { return false }
            if !signerSet.contains(depositAction.demander) { return false }
        }
        return true
    }

    func receiptActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for receipt in receiptActions {
            if receipt.amountDemanded == 0 { return false }
            if !signerSet.contains(receipt.withdrawer) { return false }
        }
        return true
    }

    func withdrawalActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for withdrawalAction in withdrawalActions {
            if withdrawalAction.amountWithdrawn == 0 { return false }
            if withdrawalAction.amountDemanded == 0 { return false }
            if !signerSet.contains(withdrawalAction.withdrawer) { return false }
        }
        return true
    }

    func withdrawalsAreValid(directory: String, homestead: LatticeState, parentState: LatticeState, fetcher: Fetcher) async throws -> Bool {
        if withdrawalActions.isEmpty { return true }
        async let proofOfDeposits = homestead.depositState.proveExistenceOfCorrespondingDeposit(withdrawalActions: withdrawalActions, fetcher: fetcher)
        async let proofOfReceipts = parentState.receiptState.proveExistenceAndVerifyWithdrawers(directory: directory, withdrawalActions: withdrawalActions, fetcher: fetcher)
        let (_, _) = try await (proofOfDeposits, proofOfReceipts)
        return true
    }

    func genesisActionsAreValid(fetcher: Fetcher, parentSpec: ChainSpec? = nil) async throws -> Bool {
        return try await !genesisActions.concurrentMap { genesisAction in
            try await genesisAction.block.validateGenesis(fetcher: fetcher, directory: genesisAction.directory, parentSpec: parentSpec).0
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
        for a in depositActions { delta += a.stateDelta() }
        for a in genesisActions { delta += try a.stateDelta() }
        for a in peerActions { delta += a.stateDelta() }
        for a in receiptActions { delta += a.stateDelta() }
        for a in withdrawalActions { delta += a.stateDelta() }
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
