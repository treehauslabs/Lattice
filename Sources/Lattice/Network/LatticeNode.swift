import Foundation
import Ivy
import Acorn
import AcornDiskWorker
import Tally
import cashew
import UInt256

public struct LatticeNodeConfig: Sendable {
    public let publicKey: String
    public let privateKey: String
    public let listenPort: UInt16
    public let bootstrapPeers: [PeerEndpoint]
    public let storagePath: URL
    public let enableLocalDiscovery: Bool
    public let persistInterval: UInt64

    public init(
        publicKey: String,
        privateKey: String,
        listenPort: UInt16 = 4001,
        bootstrapPeers: [PeerEndpoint] = [],
        storagePath: URL,
        enableLocalDiscovery: Bool = true,
        persistInterval: UInt64 = 100
    ) {
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.listenPort = listenPort
        self.bootstrapPeers = bootstrapPeers
        self.storagePath = storagePath
        self.enableLocalDiscovery = enableLocalDiscovery
        self.persistInterval = persistInterval
    }
}

public actor LatticeNode: ChainNetworkDelegate, MinerDelegate {
    public let config: LatticeNodeConfig
    public let lattice: Lattice
    public let genesisConfig: GenesisConfig
    public let genesisResult: GenesisResult
    private var networks: [String: ChainNetwork]
    private var miners: [String: MinerLoop]
    private var persisters: [String: ChainStatePersister]
    private var blocksSinceLastPersist: [String: UInt64]
    private var recentPeerBlocks: [String: ContinuousClock.Instant]

    // MARK: - Initialization

    public init(config: LatticeNodeConfig, genesisConfig: GenesisConfig) async throws {
        self.config = config
        self.genesisConfig = genesisConfig

        let nexusNetwork = try await ChainNetwork(
            directory: genesisConfig.spec.directory,
            config: IvyConfig(
                publicKey: config.publicKey,
                listenPort: config.listenPort,
                bootstrapPeers: config.bootstrapPeers,
                enableLocalDiscovery: config.enableLocalDiscovery
            ),
            storagePath: config.storagePath
        )

        let persister = ChainStatePersister(
            storagePath: config.storagePath,
            directory: genesisConfig.spec.directory
        )
        let persisted = try? await persister.load()

        let genesis: GenesisResult
        if let persisted = persisted {
            let restoredChain = ChainState.restore(from: persisted)
            let genesisBlock = try await BlockBuilder.buildGenesis(
                spec: genesisConfig.spec,
                timestamp: genesisConfig.timestamp,
                difficulty: genesisConfig.difficulty,
                fetcher: nexusNetwork.fetcher
            )
            let blockHash = HeaderImpl<Block>(node: genesisBlock).rawCID
            genesis = GenesisResult(block: genesisBlock, blockHash: blockHash, chainState: restoredChain)
        } else {
            genesis = try await GenesisCeremony.create(
                config: genesisConfig,
                fetcher: nexusNetwork.fetcher
            )
            if let blockData = genesis.block.toData() {
                await nexusNetwork.storeBlock(cid: genesis.blockHash, data: blockData)
            }
        }

        self.genesisResult = genesis
        let nexusLevel = ChainLevel(chain: genesis.chainState, children: [:])
        self.lattice = Lattice(nexus: nexusLevel)
        self.networks = [genesisConfig.spec.directory: nexusNetwork]
        self.miners = [:]
        self.persisters = [genesisConfig.spec.directory: persister]
        self.blocksSinceLastPersist = [:]
        self.recentPeerBlocks = [:]
    }

    // MARK: - Lifecycle

    public func start() async throws {
        for (_, network) in networks {
            await network.setDelegate(self)
            try await network.start()
        }
    }

    public func stop() async {
        for (_, miner) in miners {
            await miner.stop()
        }
        for (dir, _) in networks {
            await persistChainState(directory: dir)
        }
        for (_, network) in networks {
            await network.stop()
        }
    }

    // MARK: - Persistence

    private func persistChainState(directory: String) async {
        guard let persister = persisters[directory] else { return }
        let nexus = await lattice.nexus
        let chainState = await nexus.chain
        let persisted = await chainState.persist()
        try? await persister.save(persisted)
        blocksSinceLastPersist[directory] = 0
    }

    private func maybePersist(directory: String) async {
        let count = (blocksSinceLastPersist[directory] ?? 0) + 1
        blocksSinceLastPersist[directory] = count
        if count >= config.persistInterval {
            await persistChainState(directory: directory)
        }
    }

    // MARK: - Mining

    public func startMining(directory: String) async {
        guard let network = networks[directory] else { return }
        guard miners[directory] == nil else { return }

        let nexus = await lattice.nexus
        let chainState = await nexus.chain
        let miner = MinerLoop(
            chainState: chainState,
            mempool: network.mempool,
            fetcher: network.fetcher,
            spec: genesisConfig.spec
        )
        await miner.setDelegate(self)
        miners[directory] = miner
        await miner.start()
    }

    public func stopMining(directory: String) async {
        guard let miner = miners[directory] else { return }
        await miner.stop()
        miners.removeValue(forKey: directory)
    }

    // MARK: - MinerDelegate

    nonisolated public func minerDidProduceBlock(_ block: Block, hash: String) async {
        let directory = block.spec.node?.directory ?? "Nexus"
        await submitMinedBlock(directory: directory, block: block)
    }

    // MARK: - Transaction Submission & Mempool Gossip

    public func submitTransaction(directory: String, transaction: Transaction) async -> Bool {
        guard let network = networks[directory] else { return false }
        let added = await network.submitTransaction(transaction)
        if added {
            await network.announceBlock(cid: transaction.body.rawCID)
        }
        return added
    }

    // MARK: - Block Submission (from mining)

    public func submitMinedBlock(directory: String, block: Block) async {
        guard let network = networks[directory] else { return }
        let header = HeaderImpl<Block>(node: block)
        guard let blockData = block.toData() else { return }

        await network.storeBlock(cid: header.rawCID, data: blockData)
        let _ = await lattice.processBlockHeader(header, fetcher: network.fetcher)
        await network.broadcastBlock(cid: header.rawCID, data: blockData)
        await maybePersist(directory: directory)
    }

    // MARK: - Block Reception (ChainNetworkDelegate) with Rate Limiting

    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlock cid: String,
        data: Data
    ) async {
        let now = ContinuousClock.Instant.now
        let key = cid
        if let lastSeen = await recentBlockTime(for: key) {
            let elapsed = now - lastSeen
            if elapsed < .milliseconds(100) {
                return
            }
        }
        await recordBlockTime(key: key, time: now)

        let directory = await network.directory
        await network.storeBlock(cid: cid, data: data)

        let header = HeaderImpl<Block>(rawCID: cid)
        let fetcher = await network.fetcher
        let _ = await lattice.processBlockHeader(header, fetcher: fetcher)
        await maybePersist(directory: directory)
    }

    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlockAnnouncement cid: String
    ) async {
        let now = ContinuousClock.Instant.now
        if let lastSeen = await recentBlockTime(for: cid) {
            if now - lastSeen < .milliseconds(100) { return }
        }
        await recordBlockTime(key: cid, time: now)

        let fetcher = await network.fetcher
        let header = HeaderImpl<Block>(rawCID: cid)
        let _ = await lattice.processBlockHeader(header, fetcher: fetcher)
    }

    private func recentBlockTime(for key: String) -> ContinuousClock.Instant? {
        recentPeerBlocks[key]
    }

    private func recordBlockTime(key: String, time: ContinuousClock.Instant) {
        recentPeerBlocks[key] = time
        if recentPeerBlocks.count > 10_000 {
            let cutoff = ContinuousClock.Instant.now - .seconds(60)
            recentPeerBlocks = recentPeerBlocks.filter { $0.value > cutoff }
        }
    }

    // MARK: - Chain Network Management

    public func network(for directory: String) -> ChainNetwork? {
        networks[directory]
    }

    public func registerChainNetwork(
        directory: String,
        config: IvyConfig
    ) async throws {
        guard networks[directory] == nil else { return }
        let network = try await ChainNetwork(
            directory: directory,
            config: config,
            storagePath: self.config.storagePath
        )
        await network.setDelegate(self)
        networks[directory] = network
        persisters[directory] = ChainStatePersister(
            storagePath: self.config.storagePath,
            directory: directory
        )
        try await network.start()
    }
}

extension MinerLoop {
    func setDelegate(_ delegate: MinerDelegate) {
        self.delegate = delegate
    }
}

extension ChainNetwork {
    public func setDelegate(_ delegate: ChainNetworkDelegate) {
        self.delegate = delegate
    }
}
