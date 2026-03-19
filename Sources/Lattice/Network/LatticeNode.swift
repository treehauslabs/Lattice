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

    public init(
        publicKey: String,
        privateKey: String,
        listenPort: UInt16 = 4001,
        bootstrapPeers: [PeerEndpoint] = [],
        storagePath: URL,
        enableLocalDiscovery: Bool = true
    ) {
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.listenPort = listenPort
        self.bootstrapPeers = bootstrapPeers
        self.storagePath = storagePath
        self.enableLocalDiscovery = enableLocalDiscovery
    }
}

public actor LatticeNode: ChainNetworkDelegate, MinerDelegate {
    public let config: LatticeNodeConfig
    public let lattice: Lattice
    public let genesisConfig: GenesisConfig
    public let genesisResult: GenesisResult
    private var networks: [String: ChainNetwork]
    private var miners: [String: MinerLoop]

    // MARK: - Initialization via Genesis Ceremony

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

        let genesis = try await GenesisCeremony.create(
            config: genesisConfig,
            fetcher: nexusNetwork.fetcher
        )
        self.genesisResult = genesis

        if let blockData = genesis.block.toData() {
            await nexusNetwork.storeBlock(cid: genesis.blockHash, data: blockData)
        }

        let nexusLevel = ChainLevel(chain: genesis.chainState, children: [:])
        self.lattice = Lattice(nexus: nexusLevel)
        self.networks = [genesisConfig.spec.directory: nexusNetwork]
        self.miners = [:]
    }

    // MARK: - Lifecycle

    public func start() async throws {
        for (dir, network) in networks {
            await network.setDelegate(self)
            try await network.start()
        }
    }

    public func stop() async {
        for (_, miner) in miners {
            await miner.stop()
        }
        for (_, network) in networks {
            await network.stop()
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

    // MARK: - Transaction Submission & Relay

    public func submitTransaction(directory: String, transaction: Transaction) async -> Bool {
        guard let network = networks[directory] else { return false }
        let added = await network.submitTransaction(transaction)
        if added {
            if let txData = transaction.body.node?.toData() {
                await network.broadcastBlock(cid: transaction.body.rawCID, data: txData)
            }
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
    }

    // MARK: - Block Reception from Peers (ChainNetworkDelegate)

    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlock cid: String,
        data: Data
    ) async {
        let directory = await network.directory

        await network.storeBlock(cid: cid, data: data)

        let header = HeaderImpl<Block>(rawCID: cid)
        let fetcher = await network.fetcher
        let _ = await lattice.processBlockHeader(header, fetcher: fetcher)
    }

    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlockAnnouncement cid: String
    ) async {
        let fetcher = await network.fetcher
        let header = HeaderImpl<Block>(rawCID: cid)
        let _ = await lattice.processBlockHeader(header, fetcher: fetcher)
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
        try await network.start()
    }
}

// MARK: - MinerLoop delegate setter

extension MinerLoop {
    func setDelegate(_ delegate: MinerDelegate) {
        self.delegate = delegate
    }
}

// MARK: - ChainNetwork delegate setter

extension ChainNetwork {
    public func setDelegate(_ delegate: ChainNetworkDelegate) {
        self.delegate = delegate
    }
}
