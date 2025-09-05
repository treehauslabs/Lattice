import cashew

let ACCOUNT_ACTIONS_PROPERTY = "account_actions"
let ACTIONS_PROPERTY = "actions"
let DEPOSIT_ACTIONS_PROPERTY = "deposit_actions"
let GENESIS_ACTIONS_PROPERTY = "genesis_actions"
let PEER_ACTIONS_PROPERTY = "peer_actions"
let RECEIPT_ACTIONS_PROPERTY = "receipt_actions"
let WITHDRAWAL_ACTIONS_PROPERTY = "withdrawal_actions"
let PRIMARY_SIGNER_PROPERTY = "primary_signer"
let OTHER_SIGNERS_PROPERTY = "other_signers"

let TRANSACTION_BODY_PROPERTIES = Set([ACCOUNT_ACTIONS_PROPERTY, ACTIONS_PROPERTY, DEPOSIT_ACTIONS_PROPERTY, GENESIS_ACTIONS_PROPERTY, PEER_ACTIONS_PROPERTY, RECEIPT_ACTIONS_PROPERTY, WITHDRAWAL_ACTIONS_PROPERTY, PRIMARY_SIGNER_PROPERTY, OTHER_SIGNERS_PROPERTY])

public struct TransactionBody {
    let accountActions: HeaderImpl<MerkleDictionaryImpl<AccountAction>>
    let actions: HeaderImpl<MerkleDictionaryImpl<Action>>
    let depositActions: HeaderImpl<MerkleDictionaryImpl<DepositAction>>
    let genesisActions: HeaderImpl<MerkleDictionaryImpl<GenesisAction>>
    let peerActions: HeaderImpl<MerkleDictionaryImpl<PeerAction>>
    let receiptActions: HeaderImpl<MerkleDictionaryImpl<ReceiptAction>>
    let withdrawalActions: HeaderImpl<MerkleDictionaryImpl<WithdrawalAction>>
    let primarySigner: HeaderImpl<PublicKey>
    let otherSigners: HeaderImpl<MerkleDictionaryImpl<HeaderImpl<PublicKey>>>
    let fee: UInt64
    let nonce: UInt64
    
    // withdrawalActions should be fully resolved
    func withdrawalsAreValid(directory: String, homestead: LatticeState, parentState: LatticeState, fetcher: Fetcher) async throws -> Bool {
        guard let withdrawalActionsKeyPairs = try withdrawalActions.node?.allKeysAndValues() else { throw ValidationErrors.transactionNotResolved }
        let withdrawalActions = Array(withdrawalActionsKeyPairs.values)
        async let proofOfDeposits = homestead.depositState.proveExistenceOfCorrespondingDeposit(withdrawalActions: withdrawalActions, fetcher: fetcher)
        async let proofOfReceipts = await parentState.receiptState.proveExistenceOfCorrespondingReceipt(directory: directory, withdrawalActions: withdrawalActions, fetcher: fetcher)
        let (_, _) = try await (proofOfDeposits, proofOfReceipts)
        return true
    }
}

extension TransactionBody: Node {
    public func get(property: PathSegment) -> (any cashew.Address)? {
        switch property
        {
            case ACCOUNT_ACTIONS_PROPERTY: return accountActions
            case ACTIONS_PROPERTY: return actions
            case DEPOSIT_ACTIONS_PROPERTY: return depositActions
            case GENESIS_ACTIONS_PROPERTY: return genesisActions
            case PEER_ACTIONS_PROPERTY: return peerActions
            case RECEIPT_ACTIONS_PROPERTY: return receiptActions
            case WITHDRAWAL_ACTIONS_PROPERTY: return withdrawalActions
            case PRIMARY_SIGNER_PROPERTY: return primarySigner
            case OTHER_SIGNERS_PROPERTY: return otherSigners
            default: return nil
        }
    }
    
    public func properties() -> Set<PathSegment> {
        return TRANSACTION_BODY_PROPERTIES
    }
    
    public func set(properties: [PathSegment : any cashew.Address]) -> TransactionBody {
        return Self(accountActions: properties[ACCOUNT_ACTIONS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<AccountAction>>, actions: properties[ACTIONS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<Action>>, depositActions: properties[DEPOSIT_ACTIONS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<DepositAction>>, genesisActions: properties[GENESIS_ACTIONS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<GenesisAction>>, peerActions: properties[PEER_ACTIONS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<PeerAction>>, receiptActions: properties[RECEIPT_ACTIONS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<ReceiptAction>>, withdrawalActions: properties[WITHDRAWAL_ACTIONS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<WithdrawalAction>>, primarySigner: properties[PRIMARY_SIGNER_PROPERTY] as! HeaderImpl<PublicKey>, otherSigners: properties[OTHER_SIGNERS_PROPERTY] as! HeaderImpl<MerkleDictionaryImpl<HeaderImpl<PublicKey>>>, fee: fee, nonce: nonce)
    }
}
