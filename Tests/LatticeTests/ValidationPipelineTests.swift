import XCTest
@testable import Lattice
import UInt256
import cashew

struct NoopFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "NoopFetcher", code: 1)
    }
}

let testFetcher = NoopFetcher()

func testSpec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000
    )
}

func genesisBlock(
    spec: ChainSpec? = nil,
    timestamp: Int64 = 1_000_000,
    difficulty: UInt256 = UInt256(1000),
    nonce: UInt64 = 0
) async throws -> Block {
    try await BlockBuilder.buildGenesis(
        spec: spec ?? testSpec(),
        timestamp: timestamp,
        difficulty: difficulty,
        nonce: nonce,
        fetcher: testFetcher
    )
}

func nextBlock(
    previous: Block,
    timestamp: Int64,
    difficulty: UInt256? = nil,
    nonce: UInt64 = 0
) async throws -> Block {
    try await BlockBuilder.buildBlock(
        previous: previous,
        timestamp: timestamp,
        difficulty: difficulty,
        nonce: nonce,
        fetcher: testFetcher
    )
}

func signedTransaction(
    body: TransactionBody,
    privateKeyHex: String,
    publicKeyHex: String
) -> Transaction {
    let bodyHeader = HeaderImpl<TransactionBody>(node: body)
    let signature = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: privateKeyHex) ?? ""
    return Transaction(
        signatures: [publicKeyHex: signature],
        body: bodyHeader
    )
}

// MARK: - Block Builder Pipeline Tests

@MainActor
final class BlockBuilderTests: XCTestCase {

    func testBuildGenesisProducesValidBlock() async throws {
        let genesis = try await genesisBlock()
        XCTAssertNil(genesis.previousBlock)
        XCTAssertEqual(genesis.index, 0)
        XCTAssertEqual(genesis.homestead.rawCID,
            LatticeStateHeader(node: LatticeState.emptyState()).rawCID)
        XCTAssertEqual(genesis.homestead.rawCID, genesis.frontier.rawCID,
            "Genesis with no transactions should have homestead == frontier")
    }

    func testBuildBlockChainsFrontierToHomestead() async throws {
        let genesis = try await genesisBlock()
        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000)
        XCTAssertEqual(block1.homestead.rawCID, genesis.frontier.rawCID)
        XCTAssertEqual(block1.index, 1)
        XCTAssertNotNil(block1.previousBlock)
        XCTAssertEqual(block1.previousBlock?.rawCID, HeaderImpl<Block>(node: genesis).rawCID)
    }

    func testBuildBlockPreservesSpec() async throws {
        let genesis = try await genesisBlock()
        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000)
        let block2 = try await nextBlock(previous: block1, timestamp: 3_000_000)
        XCTAssertEqual(genesis.spec.rawCID, block1.spec.rawCID)
        XCTAssertEqual(block1.spec.rawCID, block2.spec.rawCID)
    }

    func testBuildBlockWithDifferentNonceProducesDifferentCID() async throws {
        let genesis = try await genesisBlock()
        let block1a = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block1b = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 2)
        XCTAssertNotEqual(
            HeaderImpl<Block>(node: block1a).rawCID,
            HeaderImpl<Block>(node: block1b).rawCID
        )
    }

    func testBuildBlockDifficultyHashChangesWithNonce() async throws {
        let genesis = try await genesisBlock()
        let block1a = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block1b = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 2)
        XCTAssertNotEqual(block1a.getDifficultyHash(), block1b.getDifficultyHash())
    }

    func testMineFindsValidNonce() async throws {
        let genesis = try await genesisBlock()
        let template = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 0)
        let target = UInt256.max
        let mined = BlockBuilder.mine(block: template, targetDifficulty: target, maxAttempts: 100)
        XCTAssertNotNil(mined)
        let hash = mined!.getDifficultyHash()
        XCTAssertTrue(target >= hash)
    }

    func testMineReturnsNilWhenImpossible() async throws {
        let genesis = try await genesisBlock()
        let template = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 0)
        let mined = BlockBuilder.mine(block: template, targetDifficulty: UInt256(0), maxAttempts: 100)
        XCTAssertNil(mined)
    }
}

// MARK: - Full Submission Pipeline via BlockBuilder

@MainActor
final class BlockBuilderSubmissionTests: XCTestCase {

    func testBuiltBlocksFormValidChain() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        var prev = genesis
        var ts: Int64 = 2_000_000
        for i in 1...10 {
            let block = try await nextBlock(previous: prev, timestamp: ts, nonce: UInt64(i))
            let header = HeaderImpl<Block>(node: block)
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: header,
                block: block
            )
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend")
            prev = block
            ts += 1_000
        }

        let highest = await chain.getHighestBlockIndex()
        XCTAssertEqual(highest, 10)
    }

    func testBuiltForkTriggersReorg() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        var mainPrev = genesis
        var ts: Int64 = 2_000_000
        for i in 1...3 {
            let block = try await nextBlock(previous: mainPrev, timestamp: ts, nonce: UInt64(i))
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block),
                block: block
            )
            mainPrev = block
            ts += 1_000
        }

        let tipBefore = await chain.getMainChainTip()
        let heightBefore = await chain.getHighestBlockIndex()
        XCTAssertEqual(heightBefore, 3)

        var forkPrev = genesis
        ts = 2_000_000
        var sawReorg = false
        for i in 1...5 {
            let block = try await nextBlock(previous: forkPrev, timestamp: ts, nonce: UInt64(100 + i))
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block),
                block: block
            )
            if result.reorganization != nil { sawReorg = true }
            forkPrev = block
            ts += 1_000
        }

        XCTAssertTrue(sawReorg, "Longer fork should trigger reorg")
        let tipAfter = await chain.getMainChainTip()
        XCTAssertNotEqual(tipBefore, tipAfter)
        let heightAfter = await chain.getHighestBlockIndex()
        XCTAssertEqual(heightAfter, 5)
    }
}

// MARK: - Signature Verification Tests

@MainActor
final class SignatureVerificationTests: XCTestCase {

    func testValidSignatureVerifies() {
        let keyPair = CryptoUtils.generateKeyPair()
        let message = "test_message_cid"
        let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair.privateKey)
        XCTAssertNotNil(signature)
        let valid = CryptoUtils.verify(message: message, signature: signature!, publicKeyHex: keyPair.publicKey)
        XCTAssertTrue(valid)
    }

    func testInvalidSignatureRejected() {
        let keyPair = CryptoUtils.generateKeyPair()
        let message = "test_message_cid"
        let valid = CryptoUtils.verify(message: message, signature: "deadbeef", publicKeyHex: keyPair.publicKey)
        XCTAssertFalse(valid)
    }

    func testWrongKeyRejected() {
        let keyPair1 = CryptoUtils.generateKeyPair()
        let keyPair2 = CryptoUtils.generateKeyPair()
        let message = "test_message_cid"
        let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair1.privateKey)!
        let valid = CryptoUtils.verify(message: message, signature: signature, publicKeyHex: keyPair2.publicKey)
        XCTAssertFalse(valid)
    }

    func testTamperedMessageRejected() {
        let keyPair = CryptoUtils.generateKeyPair()
        let signature = CryptoUtils.sign(message: "original", privateKeyHex: keyPair.privateKey)!
        let valid = CryptoUtils.verify(message: "tampered", signature: signature, publicKeyHex: keyPair.publicKey)
        XCTAssertFalse(valid)
    }

    func testTransactionSignatureMatching() {
        let keyPair = CryptoUtils.generateKeyPair()
        let publicKeyCID = HeaderImpl<PublicKey>(node: PublicKey(key: keyPair.publicKey)).rawCID

        let body = TransactionBody(
            accountActions: [],
            actions: [],
            swapActions: [],
            swapClaimActions: [],
            genesisActions: [],
            peerActions: [],
            settleActions: [],
            signers: [publicKeyCID],
            fee: 0,
            nonce: 1
        )
        let tx = signedTransaction(body: body, privateKeyHex: keyPair.privateKey, publicKeyHex: keyPair.publicKey)
        XCTAssertTrue(tx.signaturesAreValid())
        XCTAssertTrue(tx.signaturesMatchSigners())
    }

    func testTransactionWrongSignerRejected() {
        let keyPair1 = CryptoUtils.generateKeyPair()
        let keyPair2 = CryptoUtils.generateKeyPair()
        let wrongSignerCID = HeaderImpl<PublicKey>(node: PublicKey(key: keyPair2.publicKey)).rawCID

        let body = TransactionBody(
            accountActions: [],
            actions: [],
            swapActions: [],
            swapClaimActions: [],
            genesisActions: [],
            peerActions: [],
            settleActions: [],
            signers: [wrongSignerCID],
            fee: 0,
            nonce: 1
        )
        let tx = signedTransaction(body: body, privateKeyHex: keyPair1.privateKey, publicKeyHex: keyPair1.publicKey)
        XCTAssertTrue(tx.signaturesAreValid(), "Signature itself is valid")
        XCTAssertFalse(tx.signaturesMatchSigners(), "But signer doesn't match")
    }
}

// MARK: - Transaction Nonce Scoping Tests

@MainActor
final class TransactionNonceScopingTests: XCTestCase {

    func testSameNonceDifferentSignersProduceDifferentKeys() {
        let body1 = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: ["alice"], fee: 0, nonce: 42
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: ["bob"], fee: 0, nonce: 42
        )

        let key1 = TransactionStateHeader.transactionKey(body1)
        let key2 = TransactionStateHeader.transactionKey(body2)
        XCTAssertNotEqual(key1, key2, "Different signers with same nonce should produce different keys")
    }

    func testSameSignerSameNonceProducesSameKey() {
        let body1 = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: ["alice"], fee: 0, nonce: 42
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: ["alice"], fee: 0, nonce: 42
        )

        let key1 = TransactionStateHeader.transactionKey(body1)
        let key2 = TransactionStateHeader.transactionKey(body2)
        XCTAssertEqual(key1, key2, "Same signer same nonce should collide (replay protection)")
    }

    func testMultipleSignersOrderIndependent() {
        let body1 = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: ["alice", "bob"], fee: 0, nonce: 1
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: ["bob", "alice"], fee: 0, nonce: 1
        )

        let key1 = TransactionStateHeader.transactionKey(body1)
        let key2 = TransactionStateHeader.transactionKey(body2)
        XCTAssertEqual(key1, key2, "Signer order should not affect key")
    }
}

// MARK: - Balance Validation Tests

@MainActor
final class BalanceValidationTests: XCTestCase {

    func testEmptyBlockBuildsCorrectState() async throws {
        let genesis = try await genesisBlock()
        XCTAssertEqual(genesis.homestead.rawCID, genesis.frontier.rawCID,
            "Empty genesis should not change state")

        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000)
        XCTAssertEqual(block1.homestead.rawCID, block1.frontier.rawCID,
            "Empty block should not change state")
    }

    func testChainOfEmptyBlocksMaintainsStateInvariant() async throws {
        let genesis = try await genesisBlock()
        var prev = genesis
        var ts: Int64 = 2_000_000
        for _ in 1...5 {
            let block = try await nextBlock(previous: prev, timestamp: ts)
            XCTAssertEqual(block.homestead.rawCID, prev.frontier.rawCID,
                "homestead must equal previous frontier")
            XCTAssertEqual(block.homestead.rawCID, block.frontier.rawCID,
                "Empty block should not change state")
            prev = block
            ts += 1_000
        }
    }
}

// MARK: - Key Parsing Safety Tests

@MainActor
final class KeyParsingSafetyTests: XCTestCase {

    func testSwapKeyRoundTrip() {
        let original = SwapKey(swapAction: SwapAction(nonce: 42, sender: "sender1", recipient: "abc123", amount: 1000, timelock: 1000))
        let serialized = original.description
        let parsed = SwapKey(serialized)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.nonce, 42)
        XCTAssertEqual(parsed?.sender, "sender1")
        XCTAssertEqual(parsed?.recipient, "abc123")
        XCTAssertEqual(parsed?.amount, 1000)
        XCTAssertEqual(parsed?.timelock, 1000)
    }

    func testSwapKeyMalformedReturnsNil() {
        XCTAssertNil(SwapKey(""))
        XCTAssertNil(SwapKey("onlyone"))
        XCTAssertNil(SwapKey("two/parts"))
        XCTAssertNil(SwapKey("sender/recipient/notanumber/1000/42"))
    }

    func testSettleKeyRoundTrip() {
        let swapAction = SwapAction(nonce: 99, sender: "s1", recipient: "d1", amount: 500, timelock: 1000)
        let original = SettleKey(directory: "chain1", swapAction: swapAction)
        let serialized = original.description
        let parsed = SettleKey(serialized)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.directory, "chain1")
        XCTAssertEqual(parsed?.swapKey, SwapKey(swapAction: swapAction).description)
    }

    func testSettleKeyMalformedReturnsNil() {
        XCTAssertNil(SettleKey(""))
        XCTAssertNil(SettleKey("nodirectory"))
        XCTAssertNil(SettleKey("dir:bad"))
        XCTAssertNil(SettleKey("dir:a/b"))
    }
}

// MARK: - Address and Hashing Tests

@MainActor
final class CryptoUtilsTests: XCTestCase {

    func testDoubleSha256IsDeterministic() {
        let hash1 = CryptoUtils.doubleSha256("hello")
        let hash2 = CryptoUtils.doubleSha256("hello")
        XCTAssertEqual(hash1, hash2)
    }

    func testDoubleSha256DiffersFromSingleSha256() {
        let single = CryptoUtils.sha256("hello")
        let double = CryptoUtils.doubleSha256("hello")
        XCTAssertNotEqual(single, double)
    }

    func testCreateAddressIsDeterministic() {
        let keyPair = CryptoUtils.generateKeyPair()
        let addr1 = CryptoUtils.createAddress(from: keyPair.publicKey)
        let addr2 = CryptoUtils.createAddress(from: keyPair.publicKey)
        XCTAssertEqual(addr1, addr2)
    }

    func testCreateAddressStartsWithOne() {
        let keyPair = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: keyPair.publicKey)
        XCTAssertTrue(addr.hasPrefix("1"))
    }

    func testDifferentKeysDifferentAddresses() {
        let kp1 = CryptoUtils.generateKeyPair()
        let kp2 = CryptoUtils.generateKeyPair()
        let addr1 = CryptoUtils.createAddress(from: kp1.publicKey)
        let addr2 = CryptoUtils.createAddress(from: kp2.publicKey)
        XCTAssertNotEqual(addr1, addr2)
    }

    func testKeyPairGeneration() {
        let kp = CryptoUtils.generateKeyPair()
        XCTAssertFalse(kp.privateKey.isEmpty)
        XCTAssertFalse(kp.publicKey.isEmpty)
        XCTAssertNotEqual(kp.privateKey, kp.publicKey)
    }
}

// MARK: - Missing Block Tracking Tests

@MainActor
final class MissingBlockTrackingTests: XCTestCase {

    func testNoMissingBlocksInitially() async {
        let (chain, _) = makeLinearChain(length: 3)
        let missing = await chain.getMissingBlockHashes()
        XCTAssertTrue(missing.isEmpty)
    }

    func testMissingParentIsTracked() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block2 = try await nextBlock(previous: block1, timestamp: 3_000_000, nonce: 2)

        let result = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: block2),
            block: block2
        )
        XCTAssertTrue(result.needsChildBlock, "Block with missing parent should flag needsChildBlock")

        let missing = await chain.getMissingBlockHashes()
        let block1Hash = HeaderImpl<Block>(node: block1).rawCID
        XCTAssertTrue(missing.contains(block1Hash), "Missing parent should be tracked")
    }

    func testMissingBlockResolvedWhenParentArrives() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block2 = try await nextBlock(previous: block1, timestamp: 3_000_000, nonce: 2)

        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: block2),
            block: block2
        )

        let missingBefore = await chain.getMissingBlockHashes()
        XCTAssertFalse(missingBefore.isEmpty)

        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: block1),
            block: block1
        )

        let missingAfter = await chain.getMissingBlockHashes()
        let block1Hash = HeaderImpl<Block>(node: block1).rawCID
        XCTAssertFalse(missingAfter.contains(block1Hash), "Should be resolved after parent arrives")
    }
}

// MARK: - JavaScript Filter Tests

@MainActor
final class JavaScriptFilterTests: XCTestCase {

    func testTransactionFilterAccepts() {
        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [], fee: 100, nonce: 1
        )
        let filter = "function transactionFilter(txJSON) { return true; }"
        XCTAssertTrue(body.verifyFilter(filter))
    }

    func testTransactionFilterRejects() {
        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [], fee: 100, nonce: 1
        )
        let filter = "function transactionFilter(txJSON) { return false; }"
        XCTAssertFalse(body.verifyFilter(filter))
    }

    func testTransactionFilterCanInspectFee() {
        let lowFee = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [], fee: 5, nonce: 1
        )
        let highFee = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [], fee: 100, nonce: 1
        )
        let filter = "function transactionFilter(txJSON) { var tx = JSON.parse(txJSON); return tx.fee >= 50; }"
        XCTAssertFalse(lowFee.verifyFilter(filter))
        XCTAssertTrue(highFee.verifyFilter(filter))
    }

    func testActionFilterAccepts() {
        let action = Action(key: "test/key", oldValue: nil, newValue: "hello")
        let filter = "function actionFilter(aJSON) { return true; }"
        XCTAssertTrue(action.verifyFilter(filter))
    }

    func testActionFilterRejects() {
        let action = Action(key: "test/key", oldValue: nil, newValue: "hello")
        let filter = "function actionFilter(aJSON) { return false; }"
        XCTAssertFalse(action.verifyFilter(filter))
    }

    func testActionFilterCanInspectKey() {
        let goodAction = Action(key: "app/v1/data", oldValue: nil, newValue: "value")
        let badAction = Action(key: "forbidden/data", oldValue: nil, newValue: "value")
        let filter = "function actionFilter(aJSON) { var a = JSON.parse(aJSON); return a.key.indexOf('app/') === 0; }"
        XCTAssertTrue(goodAction.verifyFilter(filter))
        XCTAssertFalse(badAction.verifyFilter(filter))
    }

    func testInvalidFilterReturnsFalse() {
        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [], fee: 0, nonce: 1
        )
        XCTAssertFalse(body.verifyFilter("this is not valid javascript that defines transactionFilter"))
    }

    func testFilterWithChainSpec() {
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            transactionFilters: ["function transactionFilter(txJSON) { var tx = JSON.parse(txJSON); return tx.fee >= 10; }"]
        )
        let lowFeeBody = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [], fee: 5, nonce: 1
        )
        let highFeeBody = TransactionBody(
            accountActions: [], actions: [], swapActions: [],
            swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [], fee: 50, nonce: 1
        )
        XCTAssertFalse(lowFeeBody.verifyFilters(spec: spec))
        XCTAssertTrue(highFeeBody.verifyFilters(spec: spec))
    }
}
