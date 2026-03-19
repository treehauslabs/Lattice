import cashew
import Foundation
import UInt256

// Defines the definition and economic model of a blockchain - how rewards are distributed, when they decrease, and what the total supply will be over time.
public struct ChainSpec: Scalar {
    public let directory: String
    // Maximum number of transactions allowed per block
    public let maxNumberOfTransactionsPerBlock: UInt64
    // Maximum number of bytes actions can add to the world state per block
    public let maxStateGrowth: Int
    // Maximum serialized block size in bytes (prevents memory exhaustion)
    public let maxBlockSize: Int
    // Number of blocks mined by creators before public mining begins (must be < 2^63). Controls initial token disribution.
    public let premine: UInt64
    // Target time interval between blocks in milliseconds. Similar to Bitcoin's 10-minute target.
    public let targetBlockTime: UInt64
    // Starting reward as power of 2 (2^exponent). Determines initial block rewards.
    public let initialRewardExponent: UInt8
    // Maximum difficulty change factor (e.g., 4 means max 4x increase/decrease)
    public static let maxDifficultyChange: UInt8 = 2
    // Number of blocks over which difficulty is averaged. Higher = more stable.
    public let difficultyAdjustmentWindow: UInt64
    // List of validation rules for transactions in JavaScript.
    public let transactionFilters: [String]
    public let actionFilters: [String]

    // Cached values for optimization
    private var _halvingInterval: UInt64?

    public init(
        directory: String = "Nexus",
        maxNumberOfTransactionsPerBlock: UInt64,
        maxStateGrowth: Int,
        maxBlockSize: Int = 1_000_000,
        premine: UInt64,
        targetBlockTime: UInt64,
        initialRewardExponent: UInt8,
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
        self.initialRewardExponent = initialRewardExponent
        self.difficultyAdjustmentWindow = difficultyAdjustmentWindow
        self.transactionFilters = transactionFilters
        self.actionFilters = actionFilters
    }
}

// MARK: - Efficient Reward Calculations
public extension ChainSpec {
    
    /// Returns the bit width available for calculations (64-bit system)
    var totalExponent: UInt8 {
        return 64
    }
    
    /// Calculates halving exponent using bit operations - O(1)
    var halvingExponent: UInt8 {
        return totalExponent - initialRewardExponent
    }
    
    /// Cached halving interval calculation using bit shifting - O(1)
    /// First halving occurs at 2^halvingExponent blocks
    var halvingInterval: UInt64 {
        if let cached = _halvingInterval {
            return cached
        }
        let interval = UInt64(1) << halvingExponent
        return interval
    }
    
    /// Initial block reward using bit shifting - O(1)
    var initialReward: UInt64 {
        return UInt64(1) << initialRewardExponent
    }
    
    /// Calculates reward at specific block using bit operations - O(1)
    /// Block 0 is first public mining block; premine creates offset in halving schedule
    func rewardAtBlock(_ blockIndex: UInt64) -> UInt64 {
        // Add premine offset to account for blocks "mined" by creators before public mining
        let offsetBlockIndex = blockIndex + premine
        let halvings = offsetBlockIndex / halvingInterval
        let reward = initialReward >> halvings  // Right shift = divide by 2^n
        return reward
    }
    
    /// Optimized total rewards calculation using geometric series - O(log n)
    func totalRewards(upToBlock blockCount: UInt64) -> UInt64 {
        guard blockCount > 0 else { return 0 }
        
        var total: UInt64 = 0
        var currentReward = initialReward
        var blocksProcessed: UInt64 = 0
        let interval = halvingInterval
        
        // Iterate through halving periods
        while blocksProcessed < blockCount && currentReward > 0 {
            let blocksInThisPeriod = min(interval, blockCount - blocksProcessed)
            
            // Add rewards for this period
            let periodRewards = currentReward * blocksInThisPeriod
            total += periodRewards
            
            blocksProcessed += blocksInThisPeriod
            currentReward >>= 1  // Halve the reward using bit shift
        }
        
        return total
    }
    
    /// Calculates premine amount - total rewards for blocks 0 to (premine-1) mined by creators
    func premineAmount() -> UInt64 {
        return premine * initialReward
    }
    
    /// Calculates total number of possible halvings
    var totalHalvings: UInt8 {
        return initialRewardExponent  // Reward becomes 0 after this many halvings
    }
    
    /// Maximum possible supply (always UInt64.max for all chains)
    var maxSupply: UInt64 {
        return UInt64.max
    }
    
    /// Calculates exact minimum required difficulty based on block timing
    /// Lower difficulty value means harder to mine (smaller target)
    /// Single-pair difficulty calculation (used when only one block pair is available).
    func calculatePairDifficulty(previousDifficulty: UInt256, actualTime: Int64) -> UInt256 {
        let targetTime = Int64(targetBlockTime)
        if actualTime <= 0 { return previousDifficulty / UInt256(ChainSpec.maxDifficultyChange) }
        if actualTime < targetTime {
            let adjustmentFactor = min(Int64(ChainSpec.maxDifficultyChange), targetTime / max(actualTime, 1))
            return previousDifficulty / UInt256(adjustmentFactor)
        } else if actualTime > targetTime {
            let adjustmentFactor = min(Int64(ChainSpec.maxDifficultyChange), actualTime / targetTime)
            return previousDifficulty * UInt256(adjustmentFactor)
        }
        return previousDifficulty
    }

    /// Calculates difficulty based on a single block pair. Used during validation
    /// when the full ancestor window isn't available locally.
    func calculateMinimumDifficulty(previousDifficulty: UInt256, blockTimestamp: Int64, previousTimestamp: Int64) -> UInt256 {
        return calculatePairDifficulty(previousDifficulty: previousDifficulty, actualTime: blockTimestamp - previousTimestamp)
    }

    /// Calculates difficulty using a windowed average of ancestor block times.
    /// Uses up to `difficultyAdjustmentWindow` ancestor timestamps to compute
    /// the average block time, then adjusts difficulty based on how that average
    /// compares to the target. This prevents single-block timing from causing
    /// large difficulty swings.
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
    
    /// Validates that new difficulty meets minimum threshold
    /// In blockchain terms: newDifficulty <= minimumDifficulty (smaller number = harder)
    func validateDifficulty(_ newDifficulty: UInt256, minimumDifficulty: UInt256) -> Bool {
        return newDifficulty <= minimumDifficulty
    }
    
    /// Validates that block hash meets difficulty requirement
    /// Hash must be numerically less than the difficulty target
    func validateBlockHash(_ blockHashHex: String, difficulty: UInt256) -> Bool {
        // Convert hex string to UInt256 for comparison
        guard let blockHashValue = UInt256(blockHashHex, radix: 16) else {
            return false
        }
        
        return blockHashValue < difficulty
    }
    
    /// Validates if number of transactions in block is within limits
    func validateTransactionCount(_ transactionCount: UInt64) -> Bool {
        return transactionCount <= maxNumberOfTransactionsPerBlock
    }
    
    /// Validates if state growth is within limits
    func validateStateGrowth(_ stateGrowth: UInt64) -> Bool {
        return stateGrowth <= maxStateGrowth
    }
    
    
    /// Efficient batch reward calculation for multiple blocks - O(k) where k is number of halving periods
    func rewardRange(startBlock: UInt64, count: UInt64) -> [UInt64] {
        guard count > 0 else { return [] }
        
        var rewards: [UInt64] = []
        rewards.reserveCapacity(Int(count))
        
        // Calculate rewards for each block individually to account for premine offset
        for i in 0..<count {
            rewards.append(rewardAtBlock(startBlock + i))
        }
        
        return rewards
    }
    
}

// MARK: - Blockchain Convention Compliance
public extension ChainSpec {
    
    /// Bitcoin-like default configuration
    static let bitcoin: ChainSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 3000,
        maxStateGrowth: 1_000_000,
        maxBlockSize: 4_000_000,
        premine: 0,
        targetBlockTime: 600_000,
        initialRewardExponent: 26,
        difficultyAdjustmentWindow: 2016
    )

    static let ethereum: ChainSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 1000,
        maxStateGrowth: 24_000_000,
        maxBlockSize: 30_000_000,
        premine: 72_000_000,
        targetBlockTime: 12_000,
        initialRewardExponent: 24,
        difficultyAdjustmentWindow: 20
    )

    static let development: ChainSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 1000,
        targetBlockTime: 1_000,
        initialRewardExponent: 10,
        difficultyAdjustmentWindow: 5
    )
    
    /// Validates chain spec parameters
    var isValid: Bool {
        return maxNumberOfTransactionsPerBlock > 0 &&
               maxStateGrowth > 0 &&
               maxBlockSize > 0 &&
               targetBlockTime > 0 &&
               initialRewardExponent < totalExponent &&
               initialRewardExponent > 0 &&
               ChainSpec.maxDifficultyChange > 0 &&
               difficultyAdjustmentWindow > 0 &&
               premine < halvingInterval
    }
}
