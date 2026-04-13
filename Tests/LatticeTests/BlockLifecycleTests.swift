import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

private func makeFetcher() -> StorableFetcher {
    StorableFetcher()
}

private func lifecycleSpec(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(
        directory: dir,
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 1000,
        targetBlockTime: 1_000,
        initialReward: 1024, halvingInterval: 10_000,
        difficultyAdjustmentWindow: 5
    )
}

private func noPremine(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(
        directory: dir,
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024, halvingInterval: 10_000,
        difficultyAdjustmentWindow: 5
    )
}

private func signTransaction(
    body: TransactionBody,
    keypair: (privateKey: String, publicKey: String)
) -> Transaction {
    let bodyHeader = HeaderImpl<TransactionBody>(node: body)
    let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: keypair.privateKey)!
    return Transaction(signatures: [keypair.publicKey: sig], body: bodyHeader)
}

private func addr(_ publicKey: String) -> String {
    HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

private func now() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

// MARK: - Block Minting Tests

@MainActor
final class BlockMintingTests: XCTestCase {

    func testMintGenesisWithPremine() async throws {
        let fetcher = makeFetcher()
        let kp = CryptoUtils.generateKeyPair()
        let owner = addr(kp.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()

        let body = TransactionBody(
            accountActions: [AccountAction(owner: owner, delta: Int64(premineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [], signers: [owner], fee: 0, nonce: 0
        )
        let tx = signTransaction(body: body, keypair: kp)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, transactions: [tx], timestamp: now() - 10_000,
            difficulty: UInt256(1000), fetcher: fetcher
        )

        XCTAssertEqual(genesis.index, 0)
        XCTAssertNil(genesis.previousBlock)
        let emptyState = LatticeStateHeader(node: LatticeState.emptyState())
        XCTAssertEqual(genesis.homestead.rawCID, emptyState.rawCID)
        XCTAssertNotEqual(genesis.frontier.rawCID, genesis.homestead.rawCID)

        let valid = try await genesis.validateGenesis(fetcher: fetcher, directory: "Nexus")
        XCTAssertTrue(valid)
    }

    func testMintBlockOnTopOfGenesis() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: noPremine(), timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        XCTAssertEqual(block1.index, 1)
        XCTAssertNotNil(block1.previousBlock)
        XCTAssertEqual(block1.homestead.rawCID, genesis.frontier.rawCID)
    }

    func testMintChainOfBlocks() async throws {
        let fetcher = makeFetcher()
        let t = now()
        var prev = try await BlockBuilder.buildGenesis(
            spec: noPremine(), timestamp: t - 100_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        for i in 1...10 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t - 100_000 + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            XCTAssertEqual(block.index, UInt64(i))
            XCTAssertEqual(block.homestead.rawCID, prev.frontier.rawCID)
            prev = block
        }
    }

    func testMintBlockWithTransferTransaction() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let sender = CryptoUtils.generateKeyPair()
        let receiver = CryptoUtils.generateKeyPair()
        let senderAddr = addr(sender.publicKey)
        let receiverAddr = addr(receiver.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: senderAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [], signers: [senderAddr], fee: 0, nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, transactions: [signTransaction(body: premineBody, keypair: sender)],
            timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let reward = spec.rewardAtBlock(0)
        let transferAmount: UInt64 = 500
        let transferBody = TransactionBody(
            accountActions: [
                AccountAction(owner: senderAddr, delta: Int64(premineAmount - transferAmount) - Int64(premineAmount)),
                AccountAction(owner: receiverAddr, delta: Int64(transferAmount + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [senderAddr], fee: 0, nonce: 1
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [signTransaction(body: transferBody, keypair: sender)],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        XCTAssertEqual(block1.index, 1)
        XCTAssertNotEqual(block1.frontier.rawCID, block1.homestead.rawCID)
        let valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
    }

    func testMintBlockRewardAccountingIsCorrect() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let spec = noPremine()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let reward = spec.rewardAtBlock(0)
        let rewardBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [signTransaction(body: rewardBody, keypair: miner)],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
    }

    func testMintBlockOverclaimRewardFails() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let spec = noPremine()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let reward = spec.rewardAtBlock(0)
        let overclaimBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward + 1))],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [signTransaction(body: overclaimBody, keypair: miner)],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid)
    }

    func testMineBlockFindValidNonce() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: noPremine(), timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 0, fetcher: fetcher
        )

        let mined = BlockBuilder.mine(block: block1, targetDifficulty: UInt256.max, maxAttempts: 100)
        XCTAssertNotNil(mined)
    }

    func testMintAndSubmitToChainState() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: noPremine(), timestamp: t - 100_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        var prev = genesis
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t - 100_000 + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: block), block: block
            )
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend main chain")
            prev = block
        }

        let height = await chain.getHighestBlockIndex()
        XCTAssertEqual(height, 5)
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, VolumeImpl<Block>(node: prev).rawCID)
    }

    func testMintMultipleBlocksWithTransfers() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)
        let bobAddr = addr(bob.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()
        let reward = spec.initialReward

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [], signers: [aliceAddr], fee: 0, nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, transactions: [signTransaction(body: premineBody, keypair: alice)],
            timestamp: t - 30_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let transfer1Body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premineAmount - 100) - Int64(premineAmount)),
                AccountAction(owner: bobAddr, delta: Int64(100 + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [signTransaction(body: transfer1Body, keypair: alice)],
            timestamp: t - 20_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let block1Valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(block1Valid)

        let aliceBalance1 = premineAmount - 100
        let bobBalance1: UInt64 = 100 + reward
        let transfer2Body = TransactionBody(
            accountActions: [
                AccountAction(owner: bobAddr, delta: Int64(bobBalance1 - 50) - Int64(bobBalance1)),
                AccountAction(owner: aliceAddr, delta: Int64(aliceBalance1 + 50 + reward) - Int64(aliceBalance1))
            ],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [signTransaction(body: transfer2Body, keypair: bob)],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let block2Valid = try await block2.validateNexus(fetcher: fetcher)
        XCTAssertTrue(block2Valid)
        XCTAssertEqual(block2.index, 2)
    }
}

// MARK: - Cross-Chain Tests

@MainActor
final class CrossChainTests: XCTestCase {

    func testSwapOnChildChain() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let depositor = CryptoUtils.generateKeyPair()
        let depositorAddr = addr(depositor.publicKey)
        let childSpec = lifecycleSpec("Child")
        let premineAmount = childSpec.premineAmount()
        let reward = childSpec.initialReward

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: depositorAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [], signers: [depositorAddr], fee: 0, nonce: 0
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, transactions: [signTransaction(body: premineBody, keypair: depositor)],
            timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let swapAmount: UInt64 = 500
        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: depositorAddr, delta: Int64(premineAmount - swapAmount + reward) - Int64(premineAmount))
            ],
            actions: [],
            depositActions: [
                DepositAction(nonce: 1, demander: depositorAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)
            ],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [depositorAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [signTransaction(body: swapBody, keypair: depositor)],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        XCTAssertEqual(childBlock1.index, 1)
        XCTAssertNotEqual(childBlock1.frontier.rawCID, childBlock1.homestead.rawCID)
    }

    func testSettleOnNexusChain() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let demander = CryptoUtils.generateKeyPair()
        let demanderAddr = addr(demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = addr(withdrawer.publicKey)

        let nexusSpec = noPremine("Nexus")
        let reward = nexusSpec.rewardAtBlock(0)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let settleBody = TransactionBody(
            accountActions: [
                AccountAction(owner: demanderAddr, delta: Int64(reward))
            ],
            actions: [],
            depositActions: [],
            genesisActions: [], peerActions: [],
            receiptActions: [
                ReceiptAction(
                    withdrawer: withdrawerAddr,
                    nonce: 1,
                    demander: demanderAddr,
                    amountDemanded: 500,
                    directory: "ChildA"
                )
            ],
            withdrawalActions: [],
            signers: [demanderAddr, withdrawerAddr], fee: 0, nonce: 0
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: settleBody)
        let sigA = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: demander.privateKey)!
        let sigB = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: withdrawer.privateKey)!
        let settleTx = Transaction(signatures: [demander.publicKey: sigA, withdrawer.publicKey: sigB], body: bodyHeader)

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [settleTx],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        XCTAssertEqual(nexusBlock1.index, 1)
        let valid = try await nexusBlock1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
    }

    func testNexusRejectsDepositActions() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusSpec = noPremine("Nexus")
        let reward = nexusSpec.rewardAtBlock(1)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let fundBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [signTransaction(body: fundBody, keypair: kp)],
            timestamp: t - 15_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward - 100 + nexusSpec.rewardAtBlock(2)) - Int64(reward))],
            actions: [],
            depositActions: [DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 100, amountDeposited: 100)],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [signTransaction(body: swapBody, keypair: kp)],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        // Nexus validation ignores deposit/withdrawal actions, so frontier state
        // will mismatch because buildBlock includes deposits but validateNexus does not
        let valid = try await block2.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "Nexus should reject blocks containing deposit actions")
    }

    func testWithdrawalOnNexusIsIgnored() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusSpec = noPremine("Nexus")
        let reward = nexusSpec.rewardAtBlock(0)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Nexus must reject transactions containing withdrawal actions
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [],
            depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: 100, amountWithdrawn: 100)
            ],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let tx = signTransaction(body: body, keypair: kp)

        let block = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "Nexus must reject transactions with withdrawal actions")
    }

    func testChildChainGenesisViaGenesisAction() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusSpec = noPremine("Nexus")
        let childSpec = noPremine("Child")

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let reward = nexusSpec.rewardAtBlock(0)
        let genesisActionBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [],
            depositActions: [],
            genesisActions: [GenesisAction(directory: "Child", block: childGenesis)],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let tx = signTransaction(body: genesisActionBody, keypair: kp)

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let valid = try await nexusBlock1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
        XCTAssertEqual(nexusBlock1.index, 1)
    }

    func testMultiChainParentAnchoring() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let nexusSpec = noPremine("Nexus")
        let childSpec = noPremine("Child")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t - 100_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t - 100_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)

        var nexusPrev = nexusGenesis
        for i in 1...3 {
            let block = try await BlockBuilder.buildBlock(
                previous: nexusPrev, timestamp: t - 100_000 + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await nexusChain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: block), block: block
            )
            nexusPrev = block
        }

        let nexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 3)

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, parentChainBlock: nexusPrev,
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let nexusHeader = VolumeImpl<Block>(node: nexusPrev)
        let childResult = await childChain.submitBlock(
            parentBlockHeaderAndIndex: (nexusHeader.rawCID, nexusHeight),
            blockHeader: VolumeImpl<Block>(node: childBlock1), block: childBlock1
        )
        XCTAssertTrue(childResult.extendsMainChain)

        let childMeta = await childChain.getConsensusBlock(
            hash: VolumeImpl<Block>(node: childBlock1).rawCID
        )
        XCTAssertNotNil(childMeta?.parentIndex)
        XCTAssertEqual(childMeta?.parentIndex, nexusHeight)
    }

    func testSwapAndSettleFullFlow() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let depositor = CryptoUtils.generateKeyPair()
        let depositorAddr = addr(depositor.publicKey)

        let nexusSpec = noPremine("Nexus")
        let childSpec = lifecycleSpec("Child")
        let childPremineAmount = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let nexusReward = nexusSpec.rewardAtBlock(0)
        let swapAmount: UInt64 = 500

        let childPremineBody = TransactionBody(
            accountActions: [AccountAction(owner: depositorAddr, delta: Int64(childPremineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [], signers: [depositorAddr], fee: 0, nonce: 0
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, transactions: [signTransaction(body: childPremineBody, keypair: depositor)],
            timestamp: t - 30_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t - 30_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let childSwap = DepositAction(nonce: 1, demander: depositorAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)

        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: depositorAddr, delta: Int64(childPremineAmount - swapAmount + childReward) - Int64(childPremineAmount))
            ],
            actions: [],
            depositActions: [childSwap],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [depositorAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [signTransaction(body: swapBody, keypair: depositor)],
            timestamp: t - 20_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        XCTAssertEqual(childBlock1.index, 1)

        let settleBody = TransactionBody(
            accountActions: [
                AccountAction(owner: depositorAddr, delta: Int64(nexusReward))
            ],
            actions: [],
            depositActions: [],
            genesisActions: [], peerActions: [],
            receiptActions: [
                ReceiptAction(
                    withdrawer: depositorAddr,
                    nonce: 1,
                    demander: depositorAddr,
                    amountDemanded: swapAmount,
                    directory: "Child"
                )
            ],
            withdrawalActions: [],
            signers: [depositorAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [signTransaction(body: settleBody, keypair: depositor)],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let nexusValid = try await nexusBlock1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(nexusValid)
    }

    func testUnsignedFundRemovalFails() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)
        let bobAddr = addr(bob.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [], signers: [aliceAddr], fee: 0, nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, transactions: [signTransaction(body: premineBody, keypair: alice)],
            timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let reward = spec.rewardAtBlock(0)
        let stolenBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(premineAmount)),
                AccountAction(owner: bobAddr, delta: Int64(premineAmount + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        let stolenTx = signTransaction(body: stolenBody, keypair: bob)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [stolenTx],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid)
    }
}

// MARK: - Full Block Lifecycle Tests

@MainActor
final class BlockLifecycleTests: XCTestCase {

    func testGenesisToMiningToSubmissionToReorg() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let spec = noPremine()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t - 100_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        var mainPrev = genesis
        for i in 1...3 {
            let block = try await BlockBuilder.buildBlock(
                previous: mainPrev, timestamp: t - 100_000 + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: block), block: block
            )
            mainPrev = block
        }

        let mainTip = await chain.getMainChainTip()
        XCTAssertEqual(mainTip, VolumeImpl<Block>(node: mainPrev).rawCID)

        var forkPrev = genesis
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: forkPrev, timestamp: t - 100_000 + Int64(i) * 500,
                difficulty: UInt256(1000), nonce: UInt64(i + 100), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: block), block: block
            )
            forkPrev = block
        }

        let newTip = await chain.getMainChainTip()
        let forkTipHash = VolumeImpl<Block>(node: forkPrev).rawCID
        XCTAssertEqual(newTip, forkTipHash, "Longer fork should become main chain")
    }

    func testFullLifecycleWithPremineTransferAndBlocks() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)
        let bobAddr = addr(bob.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()
        let reward = spec.initialReward

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [], signers: [aliceAddr], fee: 0, nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, transactions: [signTransaction(body: premineBody, keypair: alice)],
            timestamp: t - 30_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let chain = ChainState.fromGenesis(block: genesis)

        let transferBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premineAmount - 1000) - Int64(premineAmount)),
                AccountAction(owner: bobAddr, delta: Int64(1000 + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [signTransaction(body: transferBody, keypair: alice)],
            timestamp: t - 20_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let block1Valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(block1Valid)

        let mined = BlockBuilder.mine(block: block1, targetDifficulty: UInt256.max, maxAttempts: 10)
        XCTAssertNotNil(mined)

        let result = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: VolumeImpl<Block>(node: mined!), block: mined!
        )
        XCTAssertTrue(result.extendsMainChain)

        let height = await chain.getHighestBlockIndex()
        XCTAssertEqual(height, 1)
    }

    func testStateChainingSanity() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let spec = noPremine()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t - 30_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let emptyState = LatticeStateHeader(node: LatticeState.emptyState())
        XCTAssertEqual(genesis.homestead.rawCID, emptyState.rawCID)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t - 20_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        XCTAssertEqual(block1.homestead.rawCID, genesis.frontier.rawCID)

        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        XCTAssertEqual(block2.homestead.rawCID, block1.frontier.rawCID)
        XCTAssertEqual(block2.spec.rawCID, block1.spec.rawCID)
        XCTAssertEqual(block2.index, block1.index + 1)
    }

    func testTimestampMustBeStrictlyIncreasing() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let spec = noPremine()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let sameTimestamp = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t - 20_000,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await sameTimestamp.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid)
    }

    func testFeeAccountingInBlocks() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let miner = CryptoUtils.generateKeyPair()
        let payer = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let payerAddr = addr(payer.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()
        let reward = spec.rewardAtBlock(0)
        let fee: UInt64 = 50

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: payerAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [], signers: [payerAddr], fee: 0, nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, transactions: [signTransaction(body: premineBody, keypair: payer)],
            timestamp: t - 20_000, difficulty: UInt256(1000), fetcher: fetcher
        )

        let feeBody = TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddr, delta: Int64(premineAmount - fee) - Int64(premineAmount)),
                AccountAction(owner: minerAddr, delta: Int64(reward + fee))
            ],
            actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddr], fee: fee, nonce: 1
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [signTransaction(body: feeBody, keypair: payer)],
            timestamp: t - 10_000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let valid = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
    }
}
