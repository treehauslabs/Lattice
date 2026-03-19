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

public actor LatticeNode {
    public let config: LatticeNodeConfig
    public let lattice: Lattice
    private var networks: [String: ChainNetwork]

    public init(config: LatticeNodeConfig, nexusSpec: ChainSpec) async throws {
        self.config = config

        let nexusNetwork = try await ChainNetwork(
            directory: nexusSpec.directory,
            config: IvyConfig(
                publicKey: config.publicKey,
                listenPort: config.listenPort,
                bootstrapPeers: config.bootstrapPeers,
                enableLocalDiscovery: config.enableLocalDiscovery
            ),
            storagePath: config.storagePath
        )

        let genesisBlock = try await BlockBuilder.buildGenesis(
            spec: nexusSpec,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            difficulty: UInt256.max,
            fetcher: nexusNetwork.fetcher
        )

        let nexusChain = ChainState.fromGenesis(block: genesisBlock)
        let nexusLevel = ChainLevel(chain: nexusChain, children: [:])
        self.lattice = Lattice(nexus: nexusLevel)
        self.networks = [nexusSpec.directory: nexusNetwork]
    }

    public func start() async throws {
        for (_, network) in networks {
            try await network.start()
        }
    }

    public func stop() async {
        for (_, network) in networks {
            await network.stop()
        }
    }

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
        networks[directory] = network
        try await network.start()
    }

    public func processReceivedBlock(directory: String, cid: String, data: Data) async {
        guard let network = networks[directory] else { return }
        let header = HeaderImpl<Block>(rawCID: cid)
        let _ = await lattice.processBlockHeader(header, fetcher: network.fetcher)
    }

    public func submitMinedBlock(directory: String, block: Block) async {
        guard let network = networks[directory] else { return }
        let header = HeaderImpl<Block>(node: block)
        guard let blockData = block.toData() else { return }

        await network.storeBlock(cid: header.rawCID, data: blockData)

        let _ = await lattice.processBlockHeader(header, fetcher: network.fetcher)

        await network.broadcastBlock(cid: header.rawCID, data: blockData)
    }
}
