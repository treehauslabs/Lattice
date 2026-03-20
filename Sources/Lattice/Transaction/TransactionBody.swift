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
        let accountStateDelta = try accountActions.map { try $0.stateDelta() }.reduce(0, +)
        let actionStateDelta = try actions.map { try $0.stateDelta() }.reduce(0, +)
        let depositStateDelta = depositActions.map { $0.stateDelta() }.reduce(0, +)
        let genesisStateDelta = try genesisActions.map { try $0.stateDelta() }.reduce(0, +)
        let peerStateDelta = try peerActions.map { try $0.stateDelta() }.reduce(0, +)
        let receiptStateDelta = try receiptActions.map { try $0.stateDelta() }.reduce(0, +)
        let withdrawalStateDelta = try withdrawalActions.map { try $0.stateDelta() }.reduce(0, +)
        return accountStateDelta + actionStateDelta + depositStateDelta + genesisStateDelta + peerStateDelta + receiptStateDelta + withdrawalStateDelta
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
}
