import cashew
import CollectionConcurrencyKit
import JavaScriptCore

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

    public init(accountActions: [AccountAction], actions: [Action], depositActions: [DepositAction], genesisActions: [GenesisAction], peerActions: [PeerAction], receiptActions: [ReceiptAction], withdrawalActions: [WithdrawalAction], signers: [String], fee: UInt64, nonce: UInt64) {
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
    }
    
    func withdrawalsAreValid(directory: String, homestead: LatticeState, parentState: LatticeState, fetcher: Fetcher) async throws -> Bool {
        for withdrawal in withdrawalActions {
            if withdrawal.amountWithdrawn > withdrawal.amountDemanded { return false }
            if withdrawal.amountWithdrawn == 0 { return false }
        }
        async let proofOfDeposits = homestead.depositState.proveExistenceOfCorrespondingDeposit(withdrawalActions: withdrawalActions, fetcher: fetcher)
        async let proofOfReceipts = await parentState.receiptState.proveExistenceOfCorrespondingReceipt(directory: directory, withdrawalActions: withdrawalActions, fetcher: fetcher)
        let (_, _) = try await (proofOfDeposits, proofOfReceipts)
        return true
    }
    
    func genesisActionsAreValid(fetcher: Fetcher, parentSpec: ChainSpec? = nil) async throws -> Bool {
        return try await !genesisActions.concurrentMap { genesisAction in
            try await genesisAction.block.validateGenesis(fetcher: fetcher, directory: genesisAction.directory, parentSpec: parentSpec)
        }.contains(false)
    }
    
    func accountActionsAreValid() -> Bool {
        let accountActionsThatRemoveFunds = accountActions.filter { $0.newBalance < $0.oldBalance }
        let signerSet = Set(signers)
        for accountActionsThatRemoveFund in accountActionsThatRemoveFunds {
            if !signerSet.contains(accountActionsThatRemoveFund.owner) { return false }
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
        guard let context = JSContext() else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let transactionData = try? encoder.encode(self) else { return false }
        guard let transactionJSON = String(bytes: transactionData, encoding: .utf8) else { return false }
        context.evaluateScript(filter)
        guard let transactionFilter = context.objectForKeyedSubscript("transactionFilter") else { return false }
        guard let result = transactionFilter.call(withArguments: [transactionJSON]) else { return false }
        return result.isBoolean ? result.toBool() : false
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
        for filter in spec.transactionFilters {
            guard let context = JSContext() else { return false }
            context.evaluateScript(filter)
            guard let fn = context.objectForKeyedSubscript("transactionFilter") else { return false }
            for json in jsonStrings {
                guard let result = fn.call(withArguments: [json]) else { return false }
                if !result.isBoolean || !result.toBool() { return false }
            }
        }
        return true
    }

    static func batchVerifyActionFilters(bodies: [TransactionBody], spec: ChainSpec) -> Bool {
        if spec.actionFilters.isEmpty { return true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for filter in spec.actionFilters {
            guard let context = JSContext() else { return false }
            context.evaluateScript(filter)
            guard let fn = context.objectForKeyedSubscript("actionFilter") else { return false }
            for body in bodies {
                for action in body.actions {
                    guard let data = try? encoder.encode(action) else { return false }
                    guard let json = String(bytes: data, encoding: .utf8) else { return false }
                    guard let result = fn.call(withArguments: [json]) else { return false }
                    if !result.isBoolean || !result.toBool() { return false }
                }
            }
        }
        return true
    }
}
