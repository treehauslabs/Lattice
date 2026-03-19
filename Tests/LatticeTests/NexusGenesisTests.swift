import XCTest
@testable import Lattice
import cashew
import UInt256

final class NexusGenesisTests: XCTestCase {

    private struct NoopFetcher: Fetcher {
        func fetch(rawCid: String) async throws -> Data {
            throw NSError(domain: "NoopFetcher", code: 1)
        }
    }

    private let fetcher = NoopFetcher()

    // MARK: - Expected Values (hardcoded from genesis ceremony)

    private let expectedOwnerAddress = "baguqeerawndzsjdmx4tkndm7evea6qsvrprpv4jvabrzhdzvijf4rivlq3hq"
    private let expectedPremineAmount: UInt64 = 3_689_348_814_741_700_608
    private let expectedBodyCID = "baguqeeratwwb6f6lr3ugi4jxhac57qcsx4c2odufndcudv6r462eet25kkna"
    private let expectedBlockHash = "baguqeerak3ha67kaj2huraqjlnlhl4uvk22x6gqvfpu5iqgeflnuvumfavxq"
    private let expectedFrontierCID = "baguqeeraqumkraivqlkulsczw6ouj6gnsqv3uxlisxf5gdmb5icr4dgzt3oq"

    // MARK: - ChainSpec Validation

    func testChainSpecIsValid() {
        XCTAssertTrue(NexusGenesis.spec.isValid)
    }

    func testChainSpecDirectory() {
        XCTAssertEqual(NexusGenesis.spec.directory, "Nexus")
    }

    func testChainSpecEconomics() {
        let spec = NexusGenesis.spec
        XCTAssertEqual(spec.initialReward, 1_048_576)
        XCTAssertEqual(spec.initialRewardExponent, 20)
        XCTAssertEqual(spec.halvingInterval, 17_592_186_044_416)
        XCTAssertEqual(spec.premine, 3_518_437_208_883)
        XCTAssertEqual(spec.premineAmount(), expectedPremineAmount)
    }

    func testPremineIsApproximatelyTenPercent() {
        let spec = NexusGenesis.spec
        let premineAmount = Double(spec.premineAmount())
        let firstPeriodSupply = Double(spec.initialReward) * Double(spec.halvingInterval)
        let totalSupply = firstPeriodSupply * 2.0
        let ratio = premineAmount / totalSupply
        XCTAssertGreaterThan(ratio, 0.09)
        XCTAssertLessThan(ratio, 0.11)
    }

    func testPremineDoesNotOverflowUInt64() {
        let spec = NexusGenesis.spec
        let (_, overflow) = spec.premine.multipliedReportingOverflow(by: spec.initialReward)
        XCTAssertFalse(overflow)
    }

    func testPremineIsLessThanHalvingInterval() {
        XCTAssertLessThan(NexusGenesis.spec.premine, NexusGenesis.spec.halvingInterval)
    }

    // MARK: - Owner Address

    func testOwnerAddressMatchesPublicKey() {
        let computed = HeaderImpl<PublicKey>(node: PublicKey(key: NexusGenesis.ownerPublicKeyHex)).rawCID
        XCTAssertEqual(computed, NexusGenesis.ownerAddress)
        XCTAssertEqual(computed, expectedOwnerAddress)
    }

    func testOwnerPublicKeyIsValidP256() {
        let pubKeyHex = NexusGenesis.ownerPublicKeyHex
        XCTAssertEqual(pubKeyHex.count, 128)
        XCTAssertTrue(pubKeyHex.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Pre-computed Signature

    func testSignatureIsValidForBodyCID() {
        let valid = CryptoUtils.verify(
            message: expectedBodyCID,
            signature: NexusGenesis.premineSignature,
            publicKeyHex: NexusGenesis.ownerPublicKeyHex
        )
        XCTAssertTrue(valid)
    }

    func testSignatureIsInvalidForWrongMessage() {
        let invalid = CryptoUtils.verify(
            message: "wrong_message",
            signature: NexusGenesis.premineSignature,
            publicKeyHex: NexusGenesis.ownerPublicKeyHex
        )
        XCTAssertFalse(invalid)
    }

    // MARK: - Transaction Body

    func testTransactionBodyCIDIsDeterministic() {
        let premineAmount = NexusGenesis.spec.premineAmount()
        let body = TransactionBody(
            accountActions: [AccountAction(owner: expectedOwnerAddress, oldBalance: 0, newBalance: premineAmount)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            peerActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [expectedOwnerAddress],
            fee: 0,
            nonce: 0
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        XCTAssertEqual(bodyHeader.rawCID, expectedBodyCID)
    }

    func testTransactionBodyHasNoFee() {
        let premineAmount = NexusGenesis.spec.premineAmount()
        let body = TransactionBody(
            accountActions: [AccountAction(owner: expectedOwnerAddress, oldBalance: 0, newBalance: premineAmount)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            peerActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [expectedOwnerAddress],
            fee: 0,
            nonce: 0
        )
        XCTAssertEqual(body.fee, 0)
        XCTAssertEqual(body.nonce, 0)
    }

    func testTransactionBodyHasSingleAccountAction() {
        let premineAmount = NexusGenesis.spec.premineAmount()
        let body = TransactionBody(
            accountActions: [AccountAction(owner: expectedOwnerAddress, oldBalance: 0, newBalance: premineAmount)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            peerActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [expectedOwnerAddress],
            fee: 0,
            nonce: 0
        )
        XCTAssertEqual(body.accountActions.count, 1)
        XCTAssertEqual(body.accountActions[0].owner, expectedOwnerAddress)
        XCTAssertEqual(body.accountActions[0].oldBalance, 0)
        XCTAssertEqual(body.accountActions[0].newBalance, premineAmount)
        XCTAssertTrue(body.actions.isEmpty)
        XCTAssertTrue(body.depositActions.isEmpty)
        XCTAssertTrue(body.genesisActions.isEmpty)
        XCTAssertTrue(body.withdrawalActions.isEmpty)
    }

    // MARK: - Genesis Block Construction

    func testGenesisBlockCreation() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertEqual(result.blockHash, expectedBlockHash)
    }

    func testGenesisBlockIndex() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertEqual(result.block.index, 0)
    }

    func testGenesisBlockTimestamp() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertEqual(result.block.timestamp, 0)
    }

    func testGenesisBlockHasNoPreviousBlock() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertNil(result.block.previousBlock)
    }

    func testGenesisBlockDifficulty() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertEqual(result.block.difficulty, UInt256.max)
        XCTAssertEqual(result.block.nextDifficulty, UInt256.max)
    }

    func testGenesisBlockHomesteadIsEmpty() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        let emptyState = LatticeStateHeader(node: LatticeState.emptyState())
        XCTAssertEqual(result.block.homestead.rawCID, emptyState.rawCID)
    }

    func testGenesisBlockFrontierCID() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertEqual(result.block.frontier.rawCID, expectedFrontierCID)
    }

    func testGenesisBlockFrontierDiffersFromHomestead() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertNotEqual(result.block.frontier.rawCID, result.block.homestead.rawCID)
    }

    func testGenesisBlockHashIsDeterministic() async throws {
        let result1 = try await NexusGenesis.create(fetcher: fetcher)
        let result2 = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertEqual(result1.blockHash, result2.blockHash)
    }

    // MARK: - Genesis Block Validation

    func testGenesisBlockPassesValidation() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        let valid = try await result.block.validateGenesis(fetcher: fetcher, directory: "Nexus")
        XCTAssertTrue(valid)
    }

    func testGenesisBlockFailsValidationWithWrongDirectory() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        let valid = try await result.block.validateGenesis(fetcher: fetcher, directory: "WrongChain")
        XCTAssertFalse(valid)
    }

    // MARK: - Balance Conservation

    func testPremineAmountMatchesSpecCalculation() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        let spec = result.block.spec.node!
        let premineAmount = spec.premineAmount()
        XCTAssertEqual(premineAmount, expectedPremineAmount)
    }

    func testBalanceChangesAreValidForGenesis() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        let spec = result.block.spec.node!
        let accountActions = [AccountAction(
            owner: expectedOwnerAddress,
            oldBalance: 0,
            newBalance: expectedPremineAmount
        )]
        let valid = try result.block.validateBalanceChangesForGenesis(
            spec: spec,
            allDepositActions: [],
            allAccountActions: accountActions,
            totalFees: 0
        )
        XCTAssertTrue(valid)
    }

    func testOverclaimIsRejected() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        let spec = result.block.spec.node!
        let accountActions = [AccountAction(
            owner: expectedOwnerAddress,
            oldBalance: 0,
            newBalance: expectedPremineAmount + 1
        )]
        let valid = try result.block.validateBalanceChangesForGenesis(
            spec: spec,
            allDepositActions: [],
            allAccountActions: accountActions,
            totalFees: 0
        )
        XCTAssertFalse(valid)
    }

    // MARK: - Chain State

    func testChainStateCreatedFromGenesis() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertNotNil(result.chainState)
    }

    // MARK: - Config

    func testConfigMatchesSpec() {
        XCTAssertEqual(NexusGenesis.config.timestamp, 0)
        XCTAssertEqual(NexusGenesis.config.difficulty, UInt256.max)
    }

    func testGenesisVerifiesViaGenesisCeremony() async throws {
        let result = try await NexusGenesis.create(fetcher: fetcher)
        let verified = GenesisCeremony.verify(block: result.block, config: NexusGenesis.config)
        XCTAssertTrue(verified)
    }
}
