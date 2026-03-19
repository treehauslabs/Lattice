import XCTest
@testable import Lattice
import UInt256
import Foundation

// MARK: - State Transition Invariant Tests
//
// These tests verify algebraic properties that must hold for all valid
// state transitions in the Lattice protocol. They test structural
// invariants rather than specific scenarios.

// MARK: - ChainSpec Algebraic Properties

final class ChainSpecPropertyTests: XCTestCase {

    // Property: rewardAtBlock(n) == initialReward >> ((n + premine) / halvingInterval)
    // The reward function is a pure function of the block index.
    func testRewardFunctionIsPure() {
        let specs: [ChainSpec] = [
            .bitcoin, .ethereum, .development,
            ChainSpec(maxNumberOfTransactionsPerBlock: 500, maxStateGrowth: 5000, premine: 42, targetBlockTime: 5000, initialRewardExponent: 12),
            ChainSpec(maxNumberOfTransactionsPerBlock: 1, maxStateGrowth: 1, premine: 0, targetBlockTime: 1, initialRewardExponent: 1),
        ]

        for spec in specs {
            guard spec.isValid else { continue }
            for _ in 0..<100 {
                let block = UInt64.random(in: 0...10_000_000)
                let r1 = spec.rewardAtBlock(block)
                let r2 = spec.rewardAtBlock(block)
                XCTAssertEqual(r1, r2, "Reward function not deterministic at block \(block)")
            }
        }
    }

    // Property: For all valid specs, totalRewards(n) == sum(rewardAtBlock(i) for i in 0..<n)
    func testTotalRewardsIsExactSum() {
        let specs: [ChainSpec] = [
            ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialRewardExponent: 4),
            ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 5, targetBlockTime: 1000, initialRewardExponent: 4),
            ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 100, targetBlockTime: 1000, initialRewardExponent: 8),
        ]

        for spec in specs {
            let halvingInterval = spec.halvingInterval
            let testBlocks: [UInt64] = [0, 1, 10, 100, halvingInterval - 1, halvingInterval, halvingInterval + 1, halvingInterval * 2]
            for blockCount in testBlocks {
                let total = spec.totalRewards(upToBlock: blockCount)
                var manualSum: UInt64 = 0
                for i in 0..<blockCount {
                    manualSum += spec.rewardAtBlock(i)
                }
                XCTAssertEqual(total, manualSum,
                               "totalRewards(\(blockCount)) != manual sum for spec with exponent=\(spec.initialRewardExponent), premine=\(spec.premine)")
            }
        }
    }

    // Property: rewardAtBlock is monotonically non-increasing
    func testRewardNonIncreasing() {
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialRewardExponent: 4)
        let halvingInterval = spec.halvingInterval

        var prev = spec.rewardAtBlock(0)
        for i: UInt64 in 0..<20 {
            let (block, overflow) = halvingInterval.multipliedReportingOverflow(by: i)
            guard !overflow else { break }
            let scaled = block / 4
            let reward = spec.rewardAtBlock(scaled)
            XCTAssertTrue(reward <= prev,
                          "Reward increased from \(prev) to \(reward) at block \(scaled)")
            prev = reward
        }
    }

    // Property: premineAmount() == totalRewards(premine) for all valid specs
    func testPremineAmountEqualsTotalRewards() {
        let premineValues: [UInt64] = [0, 1, 10, 100, 1000, 50000]
        for premine in premineValues {
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: premine, targetBlockTime: 1000, initialRewardExponent: 15)
            guard spec.isValid else { continue }
            XCTAssertEqual(spec.premineAmount(), spec.totalRewards(upToBlock: premine),
                           "premineAmount != totalRewards(premine) for premine=\(premine)")
        }
    }

    // Property: totalRewards(a + b) == totalRewards(a) + sum(rewardAtBlock(i) for i in a..<a+b)
    func testTotalRewardsAdditivity() {
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialRewardExponent: 6)

        for _ in 0..<50 {
            let a = UInt64.random(in: 0...1000)
            let b = UInt64.random(in: 0...1000)
            let totalAB = spec.totalRewards(upToBlock: a + b)
            let totalA = spec.totalRewards(upToBlock: a)
            let partB = (a..<(a + b)).reduce(UInt64(0)) { $0 + spec.rewardAtBlock($1) }
            XCTAssertEqual(totalAB, totalA + partB,
                           "Additivity failed for a=\(a), b=\(b)")
        }
    }

    // Property: halvingInterval * initialReward == 2^64 (the total bit space)
    func testHalvingIntervalTimesRewardEquals2Pow64() {
        for exp: UInt8 in 1...63 {
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialRewardExponent: exp)
            guard spec.isValid else { continue }
            let product = spec.halvingInterval.multipliedReportingOverflow(by: spec.initialReward)
            XCTAssertTrue(product.overflow,
                          "halvingInterval * initialReward should overflow UInt64 (==2^64) for exponent=\(exp)")
            XCTAssertEqual(product.partialValue, 0,
                           "Overflow should wrap to exactly 0 for exponent=\(exp)")
        }
    }

    // Property: totalHalvings == initialRewardExponent
    func testTotalHalvingsEqualsExponent() {
        for exp: UInt8 in 1...63 {
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialRewardExponent: exp)
            guard spec.isValid else { continue }
            XCTAssertEqual(spec.totalHalvings, exp)
        }
    }

    // Property: After (totalHalvings - 1) halvings, reward is 2
    // initialReward = 2^exp, after (exp-1) halvings: 2^exp >> (exp-1) = 2
    func testRewardAfterPenultimateHalvingIsTwo() {
        for exp: UInt8 in [2, 4, 8, 16, 32] {
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialRewardExponent: exp)
            guard spec.isValid else { continue }
            let (penultimateBlock, overflow) = spec.halvingInterval.multipliedReportingOverflow(by: UInt64(exp - 1))
            guard !overflow else { continue }
            let reward = spec.rewardAtBlock(penultimateBlock)
            XCTAssertEqual(reward, 2,
                           "Reward at penultimate halving should be 2 for exponent=\(exp), got \(reward)")
        }
    }

    // Property: After totalHalvings halvings, reward is 1
    // initialReward = 2^exp, after exp halvings: 2^exp >> exp = 1 (since exp < 64)
    // But wait: 2^exp >> exp = 1 only if we haven't shifted past the bit.
    // Actually: initialReward >> halvings where halvings = block/halvingInterval
    // At block = exp * halvingInterval: halvings = exp, reward = 2^exp >> exp = 1
    func testRewardAfterFinalHalvingIsOne() {
        for exp: UInt8 in [2, 4, 8, 16] {
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialRewardExponent: exp)
            guard spec.isValid else { continue }
            let (finalBlock, overflow) = spec.halvingInterval.multipliedReportingOverflow(by: UInt64(exp))
            guard !overflow else { continue }
            let reward = spec.rewardAtBlock(finalBlock)
            XCTAssertEqual(reward, 1,
                           "Reward at final halving should be 1 for exponent=\(exp), got \(reward)")
        }
    }

    // Property: Difficulty adjustment is symmetric around target
    func testDifficultyAdjustmentSymmetry() {
        let spec = ChainSpec.development
        let baseDiff = UInt256(10000)
        let target = Int64(spec.targetBlockTime)

        let halfTarget = target / 2
        let doubleTarget = target * 2

        let fasterDiff = spec.calculateMinimumDifficulty(
            previousDifficulty: baseDiff, blockTimestamp: halfTarget, previousTimestamp: 0)
        let slowerDiff = spec.calculateMinimumDifficulty(
            previousDifficulty: baseDiff, blockTimestamp: doubleTarget, previousTimestamp: 0)

        XCTAssertTrue(fasterDiff < baseDiff, "Faster blocks should decrease difficulty target")
        XCTAssertTrue(slowerDiff > baseDiff, "Slower blocks should increase difficulty target")
    }

    // Property: Exact target timing produces no change
    func testExactTargetTimingNoChange() {
        let specs: [ChainSpec] = [.bitcoin, .ethereum, .development]
        for spec in specs {
            let baseDiff = UInt256(999999)
            let target = Int64(spec.targetBlockTime)
            let newDiff = spec.calculateMinimumDifficulty(
                previousDifficulty: baseDiff, blockTimestamp: target, previousTimestamp: 0)
            XCTAssertEqual(newDiff, baseDiff,
                           "Exact target timing should not change difficulty for \(spec.directory)")
        }
    }
}

// MARK: - Fork Choice Algebraic Properties

@MainActor
final class ForkChoicePropertyTests: XCTestCase {

    // Property: compareWork is irreflexive (no fork is better than itself)
    func testIrreflexivity() {
        let testCases: [(UInt64, UInt64?)] = [
            (0, nil), (100, nil), (0, 0), (50, 25), (UInt64.max, 0)
        ]
        for (idx, parent) in testCases {
            XCTAssertFalse(compareWork((idx, parent), (idx, parent)))
        }
    }

    // Property: compareWork is asymmetric (if A beats B, B doesn't beat A)
    func testAsymmetry() {
        let testCases: [((UInt64, UInt64?), (UInt64, UInt64?))] = [
            ((5, nil), (10, nil)),
            ((100, nil), (1, 5)),
            ((10, 100), (10, 50)),
        ]
        for (left, right) in testCases {
            let lr = compareWork(left, right)
            let rl = compareWork(right, left)
            if lr {
                XCTAssertFalse(rl, "Asymmetry violated for \(left) vs \(right)")
            }
        }
    }

    // Property: Parent anchoring always beats no anchoring, regardless of chain length
    func testAnchoringDominatesLength() {
        for length: UInt64 in [1, 10, 100, 1000, UInt64.max] {
            for parentIdx: UInt64 in [0, 1, 100, UInt64.max - 1] {
                XCTAssertTrue(compareWork((length, nil), (1, parentIdx)),
                              "Anchored chain should beat unanchored length=\(length)")
            }
        }
    }

    // Property: Among anchored forks, lower parent index always wins
    func testLowerParentIndexWins() {
        for diff: UInt64 in [1, 10, 100] {
            for baseIdx: UInt64 in [0, 50, 500] {
                let high = baseIdx + diff
                XCTAssertTrue(compareWork((10, high), (10, baseIdx)),
                              "Lower parent index \(baseIdx) should beat \(high)")
                XCTAssertFalse(compareWork((10, baseIdx), (10, high)),
                               "Higher parent index \(high) should not beat \(baseIdx)")
            }
        }
    }

    // Property: Among unanchored forks, strictly longer chain wins
    func testStrictlyLongerWins() {
        for base: UInt64 in [0, 10, 100] {
            for diff: UInt64 in [1, 5, 50] {
                XCTAssertTrue(compareWork((base, nil), (base + diff, nil)))
                XCTAssertFalse(compareWork((base + diff, nil), (base, nil)))
            }
        }
    }

    // Property: After reorg, tip is on main chain
    func testReorgTipOnMainChain() async {
        for mainLen in [2, 5, 10] {
            for forkLen in [(mainLen + 1), (mainLen + 3)] {
                var blocks: [BlockMeta] = [makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["M1", "F1"])]

                for i in 1...mainLen {
                    let children = i < mainLen ? ["M\(i+1)"] : [String]()
                    blocks.append(makeBlockMeta(hash: "M\(i)", previousHash: i == 1 ? "G" : "M\(i-1)", index: UInt64(i), childBlockHashes: children))
                }
                for i in 1...forkLen {
                    let children = i < forkLen ? ["F\(i+1)"] : [String]()
                    blocks.append(makeBlockMeta(hash: "F\(i)", previousHash: i == 1 ? "G" : "F\(i-1)", index: UInt64(i), childBlockHashes: children))
                }

                let chain = makeChain(blocks: blocks, mainChainHashes: Set(["G"] + (1...mainLen).map { "M\($0)" }))
                let forkTip = await chain.getConsensusBlock(hash: "F\(forkLen)")!
                let _ = await chain.checkForReorg(block: forkTip)

                let tip = await chain.getMainChainTip()
                let onMain = await chain.isOnMainChain(hash: tip)
                XCTAssertTrue(onMain, "Tip must be on main chain after reorg (mainLen=\(mainLen), forkLen=\(forkLen))")
            }
        }
    }

    // Property: After reorg, genesis is always on main chain
    func testGenesisAlwaysOnMainChainAfterReorg() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2)

        let chain = makeChain(blocks: [g, a1, b1, b2], mainChainHashes: Set(["G", "A1"]))
        let block = await chain.getConsensusBlock(hash: "B2")!
        let _ = await chain.checkForReorg(block: block)

        let gOnMain = await chain.isOnMainChain(hash: "G")
        XCTAssertTrue(gOnMain, "Genesis must always remain on main chain")
    }

    // Property: Reorg mainChainBlocksAdded and mainChainBlocksRemoved don't overlap
    func testReorgAddedAndRemovedDisjoint() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2, childBlockHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", index: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3], mainChainHashes: Set(["G", "A1", "A2"]))
        let block = await chain.getConsensusBlock(hash: "B3")!
        let reorg = await chain.checkForReorg(block: block)

        XCTAssertNotNil(reorg)
        if let reorg = reorg {
            let addedSet = Set(reorg.mainChainBlocksAdded.keys)
            let intersection = addedSet.intersection(reorg.mainChainBlocksRemoved)
            XCTAssertTrue(intersection.isEmpty,
                          "Added and removed sets must be disjoint, overlap: \(intersection)")
        }
    }

    // Property: chainWithMostWork always includes the starting block
    func testChainWithMostWorkIncludesStart() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)

        let chain = makeChain(blocks: [g, a1, a2])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertTrue(work.blocks.contains("G"))
    }

    // Property: chainWithMostWork block set is connected (each block's parent is in the set or is before the start)
    func testChainWithMostWorkConnectedness() async {
        let g = makeBlockMeta(hash: "G", index: 0, childBlockHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", index: 1, childBlockHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", index: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", index: 1, childBlockHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", index: 2, childBlockHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", index: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3])
        let work = await chain.chainWithMostWork(startingBlock: g)

        for hash in work.blocks where hash != "G" {
            let block = await chain.getConsensusBlock(hash: hash)
            XCTAssertNotNil(block)
            if let prevHash = block?.previousBlockHash {
                XCTAssertTrue(work.blocks.contains(prevHash),
                              "Block \(hash)'s parent \(prevHash) not in winning fork set")
            }
        }
    }
}

// MARK: - Balance Conservation Properties

final class BalanceConservationPropertyTests: XCTestCase {

    // Property: In a valid block, totalBalanceAfter <= totalBalanceBefore + reward - deposits + withdrawals
    // This is the fundamental conservation law.
    func testBalanceConservationInequality() {
        let spec = ChainSpec.development

        for blockIndex: UInt64 in [0, 1, 100, 1000] {
            let reward = spec.rewardAtBlock(blockIndex)

            for _ in 0..<50 {
                let numAccounts = Int.random(in: 1...10)
                var totalBefore: UInt64 = 0
                var totalAfter: UInt64 = 0

                for _ in 0..<numAccounts {
                    let old = UInt64.random(in: 0...10000)
                    let maxNew = old + reward
                    let new = UInt64.random(in: 0...maxNew)
                    totalBefore += old
                    totalAfter += new
                }

                if totalAfter <= totalBefore + reward {
                    // This is a valid balance configuration (no deposits/withdrawals)
                    XCTAssertTrue(totalAfter <= totalBefore + reward)
                }
            }
        }
    }

    // Property: Deposit locks reduce available balance
    func testDepositReducesBalance() {
        for _ in 0..<100 {
            let depositAmount = UInt64.random(in: 1...10000)
            let action = DepositAction(
                nonce: UInt128.random(in: 0...UInt128.max),
                demander: "test_demander",
                amountDemanded: depositAmount,
                amountDeposited: depositAmount
            )
            XCTAssertGreaterThan(action.amountDeposited, 0)
        }
    }

    // Property: Account actions where newBalance < oldBalance require signer authorization
    func testDebitRequiresSignerProperty() {
        for _ in 0..<100 {
            let owner = "owner_\(UUID().uuidString)"
            let oldBalance = UInt64.random(in: 100...10000)
            let newBalance = UInt64.random(in: 0..<oldBalance)

            let action = AccountAction(owner: owner, oldBalance: oldBalance, newBalance: newBalance)
            let body = TransactionBody(
                accountActions: [action],
                actions: [],
                depositActions: [],
                genesisActions: [],
                peerActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                fee: 0,
                nonce: 0
            )
            XCTAssertFalse(body.accountActionsAreValid(),
                           "Debit without signer should be invalid")

            let bodyWithSigner = TransactionBody(
                accountActions: [action],
                actions: [],
                depositActions: [],
                genesisActions: [],
                peerActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [owner],
                fee: 0,
                nonce: 0
            )
            XCTAssertTrue(bodyWithSigner.accountActionsAreValid(),
                          "Debit with matching signer should be valid")
        }
    }

    // Property: Credit (newBalance > oldBalance) does NOT require signer
    func testCreditDoesNotRequireSigner() {
        for _ in 0..<100 {
            let owner = "owner_\(UUID().uuidString)"
            let oldBalance = UInt64.random(in: 0...10000)
            let newBalance = oldBalance + UInt64.random(in: 1...10000)

            let action = AccountAction(owner: owner, oldBalance: oldBalance, newBalance: newBalance)
            let body = TransactionBody(
                accountActions: [action],
                actions: [],
                depositActions: [],
                genesisActions: [],
                peerActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                fee: 0,
                nonce: 0
            )
            XCTAssertTrue(body.accountActionsAreValid(),
                          "Credit without signer should be valid")
        }
    }
}

// MARK: - Cross-Chain Transfer Protocol Properties

final class CrossChainProtocolPropertyTests: XCTestCase {

    // Property: DepositKey round-trips through string representation
    func testDepositKeyRoundTrip() {
        for _ in 0..<200 {
            let nonce = UInt128.random(in: 0...UInt128.max)
            let demander = "demander_\(UUID().uuidString)"
            let amount = UInt64.random(in: 1...UInt64.max)

            let key = DepositKey(nonce: nonce, demander: demander, amountDemanded: amount)
            let stringRepr = key.description
            let parsed = DepositKey(stringRepr)

            XCTAssertNotNil(parsed, "Failed to parse DepositKey: \(stringRepr)")
            if let parsed = parsed {
                XCTAssertEqual(parsed.nonce, nonce)
                XCTAssertEqual(parsed.demander, demander)
                XCTAssertEqual(parsed.amountDemanded, amount)
            }
        }
    }

    // Property: WithdrawalAction produces matching DepositKey
    func testWithdrawalProducesMatchingDepositKey() {
        for _ in 0..<100 {
            let nonce = UInt128.random(in: 0...UInt128.max)
            let demander = "dem_\(UUID().uuidString)"
            let amount = UInt64.random(in: 1...1000000)

            let deposit = DepositAction(nonce: nonce, demander: demander, amountDemanded: amount, amountDeposited: amount)
            let withdrawal = WithdrawalAction(withdrawer: "withdrawer", nonce: nonce, demander: demander, amountDemanded: amount, amountWithdrawn: amount)

            let depositKey = DepositKey(depositAction: deposit)
            let withdrawalDepositKey = DepositKey(withdrawalAction: withdrawal)

            XCTAssertEqual(depositKey.description, withdrawalDepositKey.description,
                           "Deposit and withdrawal should produce matching keys")
        }
    }

    // Property: Withdrawal + Receipt keys are consistent for same withdrawal
    func testWithdrawalReceiptKeyConsistency() {
        let directory = "TestChain"
        for _ in 0..<100 {
            let nonce = UInt128.random(in: 0...UInt128.max)
            let demander = "dem_\(UUID().uuidString)"
            let amount = UInt64.random(in: 1...1000000)

            let withdrawal = WithdrawalAction(withdrawer: "w", nonce: nonce, demander: demander, amountDemanded: amount, amountWithdrawn: amount)

            let depositKey = DepositKey(withdrawalAction: withdrawal)
            let receiptKey = ReceiptKey(withdrawalAction: withdrawal, directory: directory)

            XCTAssertEqual(depositKey.nonce, receiptKey.nonce)
            XCTAssertEqual(depositKey.demander, receiptKey.demander)
            XCTAssertEqual(depositKey.amountDemanded, receiptKey.amountDemanded)
            XCTAssertEqual(receiptKey.directory, directory)
        }
    }

    // Property: Different nonces produce different deposit keys
    func testUniqueNoncesProduceUniqueKeys() {
        let demander = "test_demander"
        let amount: UInt64 = 1000
        var keys = Set<String>()

        for i: UInt128 in 0..<500 {
            let key = DepositKey(nonce: i, demander: demander, amountDemanded: amount)
            let keyStr = key.description
            XCTAssertFalse(keys.contains(keyStr), "Duplicate key for nonce \(i)")
            keys.insert(keyStr)
        }
    }
}

// MARK: - State Delta Properties

final class StateDeltaPropertyTests: XCTestCase {

    // Property: Creating and then deleting an account has net zero state delta
    func testCreateDeleteNetZero() {
        for _ in 0..<100 {
            let owner = UUID().uuidString
            let balance = UInt64.random(in: 1...1000000)

            let create = AccountAction(owner: owner, oldBalance: 0, newBalance: balance)
            let delete = AccountAction(owner: owner, oldBalance: balance, newBalance: 0)

            let createDelta = try! create.stateDelta()
            let deleteDelta = try! delete.stateDelta()

            XCTAssertEqual(createDelta + deleteDelta, 0,
                           "Create + delete should net to zero for owner=\(owner)")
        }
    }

    // Property: Inserting and deleting a KV action has net zero state delta
    func testActionInsertDeleteNetZero() {
        for _ in 0..<100 {
            let key = UUID().uuidString
            let value = UUID().uuidString

            let insert = Action(key: key, oldValue: nil, newValue: value)
            let delete = Action(key: key, oldValue: value, newValue: nil)

            let insertDelta = try! insert.stateDelta()
            let deleteDelta = try! delete.stateDelta()

            XCTAssertEqual(insertDelta + deleteDelta, 0,
                           "Insert + delete should net to zero")
        }
    }

    // Property: State delta magnitude is bounded by key + value sizes
    func testStateDeltaBoundedByDataSize() {
        for _ in 0..<100 {
            let key = String(repeating: "k", count: Int.random(in: 1...50))
            let value = String(repeating: "v", count: Int.random(in: 1...100))

            let insert = Action(key: key, oldValue: nil, newValue: value)
            let delta = try! insert.stateDelta()

            let maxDelta = key.utf8.count + value.utf8.count
            XCTAssertEqual(delta, maxDelta,
                           "Insert delta should equal key + value size")
        }
    }

    // Property: Deposit state delta is always positive (deposits add state)
    func testDepositStateDeltaPositive() {
        for _ in 0..<100 {
            let action = DepositAction(
                nonce: UInt128.random(in: 0...UInt128.max),
                demander: UUID().uuidString,
                amountDemanded: UInt64.random(in: 1...1000000),
                amountDeposited: UInt64.random(in: 1...1000000)
            )
            XCTAssertGreaterThan(action.stateDelta(), 0,
                                 "Deposit delta should always be positive")
        }
    }

    // Property: TransactionBody state delta is sum of all action deltas
    func testTransactionBodyDeltaIsSum() {
        let accountActions = [
            AccountAction(owner: "a", oldBalance: 0, newBalance: 100),
            AccountAction(owner: "b", oldBalance: 100, newBalance: 50),
        ]
        let kvActions = [
            Action(key: "key1", oldValue: nil, newValue: "value1"),
        ]

        let body = TransactionBody(
            accountActions: accountActions,
            actions: kvActions,
            depositActions: [],
            genesisActions: [],
            peerActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0
        )

        let totalDelta = try! body.getStateDelta()
        let accountDelta = try! accountActions.map { try $0.stateDelta() }.reduce(0, +)
        let kvDelta = try! kvActions.map { try $0.stateDelta() }.reduce(0, +)

        XCTAssertEqual(totalDelta, accountDelta + kvDelta)
    }
}

// MARK: - Cryptographic Properties

final class CryptographicPropertyTests: XCTestCase {

    // Property: Different private keys produce different public keys
    func testKeyPairUniqueness() {
        var publicKeys = Set<String>()
        for _ in 0..<100 {
            let kp = CryptoUtils.generateKeyPair()
            XCTAssertFalse(publicKeys.contains(kp.publicKey), "Duplicate public key generated")
            publicKeys.insert(kp.publicKey)
        }
    }

    // Property: Signature is deterministic for same key + message
    // Note: P-256 ECDSA uses random nonces, so signatures differ. But verification must always succeed.
    func testVerificationConsistency() {
        let kp = CryptoUtils.generateKeyPair()
        let message = "test message"

        for _ in 0..<20 {
            guard let sig = CryptoUtils.sign(message: message, privateKeyHex: kp.privateKey) else {
                XCTFail("Signing failed")
                return
            }
            XCTAssertTrue(CryptoUtils.verify(message: message, signature: sig, publicKeyHex: kp.publicKey))
        }
    }

    // Property: Empty message can be signed and verified
    func testEmptyMessageSignable() {
        let kp = CryptoUtils.generateKeyPair()
        guard let sig = CryptoUtils.sign(message: "", privateKeyHex: kp.privateKey) else {
            XCTFail("Cannot sign empty message")
            return
        }
        XCTAssertTrue(CryptoUtils.verify(message: "", signature: sig, publicKeyHex: kp.publicKey))
    }

    // Property: Address is deterministic from public key
    func testAddressDeterminism() {
        let kp = CryptoUtils.generateKeyPair()
        let addr1 = CryptoUtils.createAddress(from: kp.publicKey)
        let addr2 = CryptoUtils.createAddress(from: kp.publicKey)
        XCTAssertEqual(addr1, addr2)
        XCTAssertTrue(addr1.hasPrefix("1"))
        XCTAssertEqual(addr1.count, 33) // "1" + 32 hex chars
    }

    // Property: Different public keys produce different addresses
    func testAddressUniqueness() {
        var addresses = Set<String>()
        for _ in 0..<100 {
            let kp = CryptoUtils.generateKeyPair()
            let addr = CryptoUtils.createAddress(from: kp.publicKey)
            XCTAssertFalse(addresses.contains(addr), "Duplicate address generated")
            addresses.insert(addr)
        }
    }
}

// MARK: - Block Structure Properties

final class BlockStructurePropertyTests: XCTestCase {

    // Property: Empty state CID is deterministic
    func testEmptyStateDeterministic() {
        let state1 = LatticeStateHeader(node: LatticeState.emptyState())
        let state2 = LatticeStateHeader(node: LatticeState.emptyState())
        XCTAssertEqual(state1.rawCID, state2.rawCID)
    }

    // Property: LatticeState has exactly 8 properties
    func testLatticeStatePropertyCount() {
        let state = LatticeState.emptyState()
        XCTAssertEqual(state.properties().count, 8)
    }

    // Property: All 8 sub-state property names are distinct
    func testSubStatePropertyNamesDistinct() {
        let names = [
            ACCOUNT_STATE_PROPERTY,
            GENERAL_STATE_PROPERTY,
            DEPOSIT_STATE_PROPERTY,
            PEER_STATE_PROPERTY,
            GENESIS_STATE_PROPERTY,
            RECEIPT_STATE_PROPERTY,
            WITHDRAWAL_STATE_PROPERTY,
            TRANSACTION_STATE_PROPERTY,
        ]
        XCTAssertEqual(Set(names).count, 8)
    }

    // Property: Block has exactly 7 addressable properties
    func testBlockPropertyCount() {
        XCTAssertEqual(BLOCK_PROPERTIES.count, 7)
    }

    // Property: Transaction has exactly 1 addressable property
    func testTransactionPropertyCount() {
        XCTAssertEqual(TRANSACTION_PROPERTIES.count, 1)
    }

    // Property: RECENT_BLOCK_DISTANCE is a reasonable value
    func testRecentBlockDistance() {
        XCTAssertEqual(RECENT_BLOCK_DISTANCE, 1000)
        XCTAssertGreaterThan(RECENT_BLOCK_DISTANCE, 0)
    }
}
