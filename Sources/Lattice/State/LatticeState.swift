import cashew
import Foundation

let ACCOUNT_STATE_PROPERTY = "accountState"
let GENERAL_STATE_PROPERTY = "generalState"
let DEPOSIT_STATE_PROPERTY = "depositState"
let PEER_STATE_PROPERTY = "peerState"
let GENESIS_STATE_PROPERTY = "genesisState"
let RECEIPT_STATE_PROPERTY = "receiptState"
let TRANSACTION_STATE_PROPERTY = "transactionState"

let LATTICE_STATE_PROPERTIES: Set<String> = Set([
    ACCOUNT_STATE_PROPERTY,
    GENERAL_STATE_PROPERTY,
    DEPOSIT_STATE_PROPERTY,
    PEER_STATE_PROPERTY,
    GENESIS_STATE_PROPERTY,
    RECEIPT_STATE_PROPERTY,
    TRANSACTION_STATE_PROPERTY
])

public struct LatticeState: Node {
    public let accountState: AccountStateHeader
    public let generalState: GeneralStateHeader
    public let depositState: DepositStateHeader
    public let peerState: PeerStateHeader
    public let genesisState: GenesisStateHeader
    public let receiptState: ReceiptStateHeader
    public let transactionState: TransactionStateHeader

    static let empty = Self(accountState: AccountStateHeader(node: AccountState()), generalState: GeneralStateHeader(node: GeneralState()), depositState: DepositStateHeader(node: DepositState()), peerState: PeerStateHeader(node: PeerState()), genesisState: GenesisStateHeader(node: GenesisState()), receiptState: ReceiptStateHeader(node: ReceiptState()), transactionState: TransactionStateHeader(node: TransactionState()))
    static let emptyHeader = LatticeStateHeader(node: empty)

    static func emptyState() -> Self { empty }

    public func get(property: PathSegment) -> (any cashew.Header)? {
        switch property {
            case ACCOUNT_STATE_PROPERTY: return accountState
            case GENERAL_STATE_PROPERTY: return generalState
            case DEPOSIT_STATE_PROPERTY: return depositState
            case PEER_STATE_PROPERTY: return peerState
            case GENESIS_STATE_PROPERTY: return genesisState
            case RECEIPT_STATE_PROPERTY: return receiptState
            case TRANSACTION_STATE_PROPERTY: return transactionState
            default: return nil
        }
    }

    public func properties() -> Set<PathSegment> {
        return LATTICE_STATE_PROPERTIES
    }

    public func set(properties: [PathSegment : any cashew.Header]) -> LatticeState {
        return Self(
            accountState: properties[ACCOUNT_STATE_PROPERTY] as? AccountStateHeader ?? accountState,
            generalState: properties[GENERAL_STATE_PROPERTY] as? GeneralStateHeader ?? generalState,
            depositState: properties[DEPOSIT_STATE_PROPERTY] as? DepositStateHeader ?? depositState,
            peerState: properties[PEER_STATE_PROPERTY] as? PeerStateHeader ?? peerState,
            genesisState: properties[GENESIS_STATE_PROPERTY] as? GenesisStateHeader ?? genesisState,
            receiptState: properties[RECEIPT_STATE_PROPERTY] as? ReceiptStateHeader ?? receiptState,
            transactionState: properties[TRANSACTION_STATE_PROPERTY] as? TransactionStateHeader ?? transactionState
        )
    }

    public func proveAndUpdateState(allAccountActions: [AccountAction], allActions: [Action], allDepositActions: [DepositAction], allGenesisActions: [GenesisAction], allPeerActions: [PeerAction], allReceiptActions: [ReceiptAction], allWithdrawalActions: [WithdrawalAction], transactionBodies: [TransactionBody], fetcher: Fetcher) async throws -> LatticeState {
        // Receipt actions generate implicit account transfers: debit withdrawer, credit demander
        var mergedAccountActions = allAccountActions
        for receipt in allReceiptActions {
            guard receipt.amountDemanded > 0 && receipt.amountDemanded <= UInt64(Int64.max) else {
                throw StateErrors.balanceOverflow
            }
            mergedAccountActions.append(AccountAction(owner: receipt.withdrawer, delta: -Int64(receipt.amountDemanded)))
            mergedAccountActions.append(AccountAction(owner: receipt.demander, delta: Int64(receipt.amountDemanded)))
        }
        async let newAccountState = accountState.proveAndUpdateState(allAccountActions: mergedAccountActions, fetcher: fetcher)
        async let newGeneralState = generalState.proveAndUpdateState(allActions: allActions, fetcher: fetcher)
        async let newGenesisState = genesisState.proveAndUpdateState(allGenesisActions: allGenesisActions, fetcher: fetcher)
        async let newPeerState = peerState.proveAndUpdateState(allPeerActions: allPeerActions, fetcher: fetcher)
        async let newReceiptState = receiptState.proveAndUpdateState(allReceiptActions: allReceiptActions, fetcher: fetcher)
        async let newTransactionState = transactionState.proveAndUpdateState(allTransactions: transactionBodies, fetcher: fetcher)
        let afterWithdrawals = try await depositState.proveAndDeleteForWithdrawals(allWithdrawalActions: allWithdrawalActions, fetcher: fetcher)
        async let newDepositState = afterWithdrawals.proveAndUpdateState(allDepositActions: allDepositActions, fetcher: fetcher)
        let (finalAccountState, finalGeneralState, finalDepositState, finalGenesisState, finalPeerState, finalReceiptState, finalTransactionState) = await (try newAccountState, try newGeneralState, try newDepositState, try newGenesisState, try newPeerState, try newReceiptState, try newTransactionState)
        return Self(accountState: finalAccountState, generalState: finalGeneralState, depositState: finalDepositState, peerState: finalPeerState, genesisState: finalGenesisState, receiptState: finalReceiptState, transactionState: finalTransactionState)
    }
}

public typealias LatticeStateHeader = VolumeImpl<LatticeState>
