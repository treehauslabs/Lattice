import cashew
import Foundation
import UInt256

public struct ChainSpec: Scalar {
    public let directory: String
    public let maxNumberOfTransactionsPerBlock: UInt64
    public let maxStateGrowth: Int
    public let maxBlockSize: Int
    public let premine: UInt64
    public let targetBlockTime: UInt64
    public let initialReward: UInt64
    public let halvingInterval: UInt64
    public static let maxDifficultyChange: UInt8 = 2
    // Ceiling on difficulty value (higher = easier). Requires ~65,536 hash
    // attempts minimum, preventing abandoned chains from being trivially mined.
    public static let maximumDifficulty: UInt256 = UInt256.max >> 16
    public let difficultyAdjustmentWindow: UInt64
    public let transactionFilters: [String]
    public let actionFilters: [String]

    public init(
        directory: String = "Nexus",
        maxNumberOfTransactionsPerBlock: UInt64,
        maxStateGrowth: Int,
        maxBlockSize: Int = 1_000_000,
        premine: UInt64,
        targetBlockTime: UInt64,
        initialReward: UInt64,
        halvingInterval: UInt64,
        difficultyAdjustmentWindow: UInt64 = 10,
        transactionFilters: [String] = [],
        actionFilters: [String] = []
    ) {
        self.directory = directory
        self.maxNumberOfTransactionsPerBlock = maxNumberOfTransactionsPerBlock
        self.maxStateGrowth = maxStateGrowth
        self.maxBlockSize = maxBlockSize
        self.premine = premine
        self.targetBlockTime = targetBlockTime
        self.initialReward = initialReward
        self.halvingInterval = halvingInterval
        self.difficultyAdjustmentWindow = difficultyAdjustmentWindow
        self.transactionFilters = transactionFilters
        self.actionFilters = actionFilters
    }
}

// MARK: - Reward Calculations
public extension ChainSpec {

    func rewardAtBlock(_ blockIndex: UInt64) -> UInt64 {
        let offsetBlockIndex = blockIndex + premine
        let halvings = offsetBlockIndex / halvingInterval
        guard halvings < 64 else { return 0 }
        return initialReward >> halvings
    }

    func totalRewards(upToBlock blockCount: UInt64) -> UInt64 {
        guard blockCount > 0 else { return 0 }

        var total: UInt64 = 0
        var blocksProcessed: UInt64 = 0

        while blocksProcessed < blockCount {
            let offsetBlock = blocksProcessed + premine
            let currentHalving = offsetBlock / halvingInterval
            guard currentHalving < 64 else { break }
            let currentReward = initialReward >> currentHalving

            guard currentReward > 0 else { break }

            // How many blocks remain in this halving period?
            let nextHalvingAt = (currentHalving + 1) * halvingInterval - premine
            let blocksUntilNextHalving = nextHalvingAt - blocksProcessed
            let blocksInThisPeriod = min(blocksUntilNextHalving, blockCount - blocksProcessed)

            let (periodRewards, overflow) = currentReward.multipliedReportingOverflow(by: blocksInThisPeriod)
            if overflow { return UInt64.max }
            let (newTotal, addOverflow) = total.addingReportingOverflow(periodRewards)
            if addOverflow { return UInt64.max }
            total = newTotal

            blocksProcessed += blocksInThisPeriod
        }

        return total
    }

    func premineAmount() -> UInt64 {
        guard premine > 0 else { return 0 }

        var total: UInt64 = 0
        var blocksProcessed: UInt64 = 0

        while blocksProcessed < premine {
            let currentHalving = blocksProcessed / halvingInterval
            guard currentHalving < 64 else { break }
            let currentReward = initialReward >> currentHalving
            guard currentReward > 0 else { break }

            let nextHalvingAt = (currentHalving + 1) * halvingInterval
            let blocksInThisPeriod = min(nextHalvingAt - blocksProcessed, premine - blocksProcessed)

            let (periodRewards, overflow) = currentReward.multipliedReportingOverflow(by: blocksInThisPeriod)
            if overflow { return UInt64.max }
            let (newTotal, addOverflow) = total.addingReportingOverflow(periodRewards)
            if addOverflow { return UInt64.max }
            total = newTotal

            blocksProcessed += blocksInThisPeriod
        }

        return total
    }

    var totalHalvings: UInt64 {
        guard initialReward > 0 else { return 0 }
        return UInt64(UInt64.bitWidth - initialReward.leadingZeroBitCount)
    }

    var isValid: Bool {
        return maxNumberOfTransactionsPerBlock > 0 &&
               maxStateGrowth > 0 &&
               maxBlockSize > 0 &&
               targetBlockTime > 0 &&
               initialReward > 0 &&
               halvingInterval > 0 &&
               ChainSpec.maxDifficultyChange > 0 &&
               difficultyAdjustmentWindow > 0 &&
               premine < halvingInterval
    }
}

// MARK: - Difficulty Calculations
public extension ChainSpec {

    func calculatePairDifficulty(previousDifficulty: UInt256, actualTime: Int64) -> UInt256 {
        let targetTime = Int64(targetBlockTime)
        let adjusted: UInt256
        if actualTime <= 0 {
            adjusted = previousDifficulty / UInt256(ChainSpec.maxDifficultyChange)
        } else if actualTime < targetTime {
            let adjustmentFactor = min(Int64(ChainSpec.maxDifficultyChange), targetTime / max(actualTime, 1))
            adjusted = previousDifficulty / UInt256(adjustmentFactor)
        } else if actualTime > targetTime {
            let adjustmentFactor = min(Int64(ChainSpec.maxDifficultyChange), actualTime / targetTime)
            adjusted = previousDifficulty * UInt256(adjustmentFactor)
        } else {
            adjusted = previousDifficulty
        }
        return min(adjusted, ChainSpec.maximumDifficulty)
    }

    func calculateMinimumDifficulty(previousDifficulty: UInt256, blockTimestamp: Int64, previousTimestamp: Int64) -> UInt256 {
        return calculatePairDifficulty(previousDifficulty: previousDifficulty, actualTime: blockTimestamp - previousTimestamp)
    }

    func calculateWindowedDifficulty(previousDifficulty: UInt256, ancestorTimestamps: [Int64]) -> UInt256 {
        guard ancestorTimestamps.count >= 2 else {
            return previousDifficulty
        }
        let sorted = ancestorTimestamps.sorted(by: >)
        let newest = sorted.first!
        let oldest = sorted.last!
        let totalTime = newest - oldest
        let blockCount = Int64(sorted.count - 1)
        guard blockCount > 0 && totalTime > 0 else { return previousDifficulty }
        let averageTime = totalTime / blockCount
        return calculatePairDifficulty(previousDifficulty: previousDifficulty, actualTime: averageTime)
    }

    func validateDifficulty(_ newDifficulty: UInt256, minimumDifficulty: UInt256) -> Bool {
        return newDifficulty <= minimumDifficulty
    }

    func validateBlockHash(_ blockHashHex: String, difficulty: UInt256) -> Bool {
        guard let blockHashValue = UInt256(blockHashHex, radix: 16) else {
            return false
        }
        return blockHashValue < difficulty
    }

    func validateTransactionCount(_ transactionCount: UInt64) -> Bool {
        return transactionCount <= maxNumberOfTransactionsPerBlock
    }

    func validateStateGrowth(_ stateGrowth: UInt64) -> Bool {
        return stateGrowth <= maxStateGrowth
    }

    func rewardRange(startBlock: UInt64, count: UInt64) -> [UInt64] {
        guard count > 0 else { return [] }

        var rewards: [UInt64] = []
        rewards.reserveCapacity(Int(count))

        for i in 0..<count {
            rewards.append(rewardAtBlock(startBlock + i))
        }

        return rewards
    }
}

// MARK: - Presets
public extension ChainSpec {

    static let bitcoin: ChainSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 3000,
        maxStateGrowth: 1_000_000,
        maxBlockSize: 4_000_000,
        premine: 0,
        targetBlockTime: 600_000,
        initialReward: 5_000_000_000,
        halvingInterval: 210_000,
        difficultyAdjustmentWindow: 2016
    )

    static let ethereum: ChainSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 1000,
        maxStateGrowth: 24_000_000,
        maxBlockSize: 30_000_000,
        premine: 72_000_000,
        targetBlockTime: 12_000,
        initialReward: 2_000_000_000_000_000_000,
        halvingInterval: 100_000_000,
        difficultyAdjustmentWindow: 20
    )

    static let development: ChainSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 1000,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000,
        difficultyAdjustmentWindow: 5
    )
}
