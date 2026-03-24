import cashew
import Foundation

let ACCOUNT_STATE_PROPERTY = "accountState"
let GENERAL_STATE_PROPERTY = "generalState"
let SWAP_STATE_PROPERTY = "swapState"
let PEER_STATE_PROPERTY = "peerState"
let GENESIS_STATE_PROPERTY = "genesisState"
let SETTLE_STATE_PROPERTY = "settleState"
let TRANSACTION_STATE_PROPERTY = "transactionState"

let LATTICE_STATE_PROPERTIES: Set<String> = Set([
    ACCOUNT_STATE_PROPERTY,
    GENERAL_STATE_PROPERTY,
    SWAP_STATE_PROPERTY,
    PEER_STATE_PROPERTY,
    GENESIS_STATE_PROPERTY,
    SETTLE_STATE_PROPERTY,
    TRANSACTION_STATE_PROPERTY
])

public struct LatticeState: Node {
    public let accountState: AccountStateHeader
    public let generalState: GeneralStateHeader
    public let swapState: SwapStateHeader
    public let peerState: PeerStateHeader
    public let genesisState: GenesisStateHeader
    public let settleState: SettleStateHeader
    public let transactionState: TransactionStateHeader

    static let empty = Self(accountState: AccountStateHeader(node: AccountState()), generalState: GeneralStateHeader(node: GeneralState()), swapState: SwapStateHeader(node: SwapState()), peerState: PeerStateHeader(node: PeerState()), genesisState: GenesisStateHeader(node: GenesisState()), settleState: SettleStateHeader(node: SettleState()), transactionState: TransactionStateHeader(node: TransactionState()))
    static let emptyHeader = LatticeStateHeader(node: empty)

    static func emptyState() -> Self { empty }

    public func get(property: PathSegment) -> (any cashew.Header)? {
        switch property {
            case ACCOUNT_STATE_PROPERTY: return accountState
            case GENERAL_STATE_PROPERTY: return generalState
            case SWAP_STATE_PROPERTY: return swapState
            case PEER_STATE_PROPERTY: return peerState
            case GENESIS_STATE_PROPERTY: return genesisState
            case SETTLE_STATE_PROPERTY: return settleState
            case TRANSACTION_STATE_PROPERTY: return transactionState
            default: return nil
        }
    }

    public func properties() -> Set<PathSegment> {
        return LATTICE_STATE_PROPERTIES
    }

    public func set(properties: [PathSegment : any cashew.Header]) -> LatticeState {
        return Self(accountState: properties[ACCOUNT_STATE_PROPERTY] as! AccountStateHeader, generalState: properties[GENERAL_STATE_PROPERTY] as! GeneralStateHeader, swapState: properties[SWAP_STATE_PROPERTY] as! SwapStateHeader, peerState: properties[PEER_STATE_PROPERTY] as! PeerStateHeader, genesisState: properties[GENESIS_STATE_PROPERTY] as! GenesisStateHeader, settleState: properties[SETTLE_STATE_PROPERTY] as! SettleStateHeader, transactionState: properties[TRANSACTION_STATE_PROPERTY] as! TransactionStateHeader)
    }

    public func proveAndUpdateState(allAccountActions: [AccountAction], allActions: [Action], allSwapActions: [SwapAction], allSwapClaimActions: [SwapClaimAction], allGenesisActions: [GenesisAction], allPeerActions: [PeerAction], allSettleActions: [SettleAction], transactionBodies: [TransactionBody], fetcher: Fetcher) async throws -> LatticeState {
        async let newAccountState = accountState.proveAndUpdateState(allAccountActions: allAccountActions, fetcher: fetcher)
        async let newGeneralState = generalState.proveAndUpdateState(allActions: allActions, fetcher: fetcher)
        async let newSwapState = swapState.proveAndUpdateState(allSwapActions: allSwapActions, allSwapClaimActions: allSwapClaimActions, fetcher: fetcher)
        async let newGenesisState = genesisState.proveAndUpdateState(allGenesisActions: allGenesisActions, fetcher: fetcher)
        async let newPeerState = peerState.proveAndUpdateState(allPeerActions: allPeerActions, fetcher: fetcher)
        async let newSettleState = settleState.proveAndUpdateState(allSettleActions: allSettleActions, fetcher: fetcher)
        async let newTransactionState = transactionState.proveAndUpdateState(allTransactions: transactionBodies, fetcher: fetcher)
        let (finalAccountState, finalGeneralState, finalSwapState, finalGenesisState, finalPeerState, finalSettleState, finalTransactionState) = await (try newAccountState, try newGeneralState, try newSwapState, try newGenesisState, try newPeerState, try newSettleState, try newTransactionState)
        return Self(accountState: finalAccountState, generalState: finalGeneralState, swapState: finalSwapState, peerState: finalPeerState, genesisState: finalGenesisState, settleState: finalSettleState, transactionState: finalTransactionState)
    }
}

public typealias LatticeStateHeader = HeaderImpl<LatticeState>
