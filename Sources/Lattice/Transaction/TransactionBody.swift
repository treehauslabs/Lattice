import cashew
import CollectionConcurrencyKit
import JavaScriptCore

public struct TransactionBody: Scalar {
    let accountActions: [AccountAction]
    let actions: [Action]
    let depositActions: [DepositAction]
    let genesisActions: [GenesisAction]
    let peerActions: [PeerAction]
    let receiptActions: [ReceiptAction]
    let withdrawalActions: [WithdrawalAction]
    let signers: [String]
    let fee: UInt64
    let nonce: UInt64
    
    // withdrawalActions should be fully resolved
    func withdrawalsAreValid(directory: String, homestead: LatticeState, parentState: LatticeState, fetcher: Fetcher) async throws -> Bool {
        async let proofOfDeposits = homestead.depositState.proveExistenceOfCorrespondingDeposit(withdrawalActions: withdrawalActions, fetcher: fetcher)
        async let proofOfReceipts = await parentState.receiptState.proveExistenceOfCorrespondingReceipt(directory: directory, withdrawalActions: withdrawalActions, fetcher: fetcher)
        let (_, _) = try await (proofOfDeposits, proofOfReceipts)
        return true
    }
    
    func genesisActionsAreValid(fetcher: Fetcher) async throws -> Bool {
        return try await !genesisActions.concurrentMap { genesisAction in
            try await genesisAction.block.validateGenesis(fetcher: fetcher, directory: genesisAction.directory)
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
        guard let transactionData = try? JSONEncoder().encode(self) else { return false }
        guard let transactionJSON = String(bytes: transactionData, encoding: .utf8) else { return false }
        context.evaluateScript(filter)
        guard let transactionFilter = context.objectForKeyedSubscript("transactionFilter") else { return false }
        guard let result = transactionFilter.call(withArguments: [transactionJSON]) else { return false }
        return result.isBoolean ? result.toBool() : false
    }
}
