import Foundation

public struct NodeResourceConfig: Sendable {
    // Storage: in-memory cache (hot path)
    public let memoryCacheEntries: Int
    public let memoryCacheMaxBytes: Int

    // Storage: disk cache (warm path)
    public let diskCacheEntries: Int
    public let diskCacheMaxBytes: Int

    // Mining
    public let miningBatchSize: UInt64

    // Network
    public let mempoolMaxSize: Int

    public init(
        memoryCacheEntries: Int = 10_000,
        memoryCacheMaxBytes: Int = 256_000_000,
        diskCacheEntries: Int = 100_000,
        diskCacheMaxBytes: Int = 1_000_000_000,
        miningBatchSize: UInt64 = 10_000,
        mempoolMaxSize: Int = 10_000
    ) {
        self.memoryCacheEntries = memoryCacheEntries
        self.memoryCacheMaxBytes = memoryCacheMaxBytes
        self.diskCacheEntries = diskCacheEntries
        self.diskCacheMaxBytes = diskCacheMaxBytes
        self.miningBatchSize = miningBatchSize
        self.mempoolMaxSize = mempoolMaxSize
    }

    public static let `default` = NodeResourceConfig()

    public static let light = NodeResourceConfig(
        memoryCacheEntries: 1_000,
        memoryCacheMaxBytes: 64_000_000,
        diskCacheEntries: 10_000,
        diskCacheMaxBytes: 256_000_000,
        miningBatchSize: 5_000,
        mempoolMaxSize: 1_000
    )

    public static let heavy = NodeResourceConfig(
        memoryCacheEntries: 100_000,
        memoryCacheMaxBytes: 1_000_000_000,
        diskCacheEntries: 1_000_000,
        diskCacheMaxBytes: 10_000_000_000,
        miningBatchSize: 50_000,
        mempoolMaxSize: 50_000
    )
}
