import Foundation
import Ivy

public struct NodeResourceConfig: Sendable {
    public let memoryBudgetGB: Double
    public let diskBudgetGB: Double
    public let mempoolBudgetMB: Double
    public let miningBatchSize: UInt64
    public let nodeIdentityHash: [UInt8]?

    public init(
        memoryBudgetGB: Double = 0.25,
        diskBudgetGB: Double = 1.0,
        mempoolBudgetMB: Double = 64.0,
        miningBatchSize: UInt64 = 10_000,
        nodeIdentityHash: [UInt8]? = nil
    ) {
        self.memoryBudgetGB = memoryBudgetGB
        self.diskBudgetGB = diskBudgetGB
        self.mempoolBudgetMB = mempoolBudgetMB
        self.miningBatchSize = miningBatchSize
        self.nodeIdentityHash = nodeIdentityHash
    }

    public static let `default` = NodeResourceConfig()

    public static let light = NodeResourceConfig(
        memoryBudgetGB: 0.064,
        diskBudgetGB: 0.25,
        mempoolBudgetMB: 16.0,
        miningBatchSize: 5_000
    )

    public static let heavy = NodeResourceConfig(
        memoryBudgetGB: 1.0,
        diskBudgetGB: 10.0,
        mempoolBudgetMB: 256.0,
        miningBatchSize: 50_000
    )

    public func memoryBytesPerChain(chainCount: Int) -> Int {
        let total = Int(memoryBudgetGB * 1_073_741_824)
        return max(total / max(chainCount, 1), 1_048_576)
    }

    public func diskBytesPerChain(chainCount: Int) -> Int {
        let total = Int(diskBudgetGB * 1_073_741_824)
        return max(total / max(chainCount, 1), 1_048_576)
    }

    public func mempoolSizePerChain(chainCount: Int) -> Int {
        let totalBytes = Int(mempoolBudgetMB * 1_048_576)
        let estimatedTxSize = 512
        let totalTxs = totalBytes / estimatedTxSize
        return max(totalTxs / max(chainCount, 1), 100)
    }

    public func withIdentity(publicKey: String) -> NodeResourceConfig {
        NodeResourceConfig(
            memoryBudgetGB: memoryBudgetGB,
            diskBudgetGB: diskBudgetGB,
            mempoolBudgetMB: mempoolBudgetMB,
            miningBatchSize: miningBatchSize,
            nodeIdentityHash: Router.hash(publicKey)
        )
    }
}
