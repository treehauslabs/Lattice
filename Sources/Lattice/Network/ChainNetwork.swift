import Foundation
import Ivy
import Acorn
import AcornDiskWorker
import Tally
import cashew
import UInt256

public protocol ChainNetworkDelegate: AnyObject, Sendable {
    func chainNetwork(_ network: ChainNetwork, didReceiveBlock cid: String, data: Data) async
    func chainNetwork(_ network: ChainNetwork, didReceiveBlockAnnouncement cid: String) async
}

public actor ChainNetwork: IvyDelegate {
    public let directory: String
    public let ivy: Ivy
    public let fetcher: AcornFetcher
    private let storage: any AcornCASWorker
    public weak var delegate: ChainNetworkDelegate?

    public init(
        directory: String,
        config: IvyConfig,
        storagePath: URL
    ) async throws {
        self.directory = directory

        let disk = try DiskCASWorker(
            directory: storagePath.appendingPathComponent(directory),
            capacity: 100_000,
            maxBytes: 1_000_000_000
        )

        let ivy = Ivy(config: config)
        let network = await ivy.worker()

        let composite = await CompositeCASWorker(
            workers: ["disk": disk, "net": network],
            order: ["disk", "net"]
        )

        self.ivy = ivy
        self.storage = composite
        self.fetcher = AcornFetcher(worker: composite)
    }

    public func start() async throws {
        await ivy.setDelegate(self)
        try await ivy.start()
    }

    public func stop() async {
        await ivy.stop()
    }

    public func announceBlock(cid: String) async {
        await ivy.announceBlock(cid: cid)
    }

    public func broadcastBlock(cid: String, data: Data) async {
        let acornCid = ContentIdentifier(rawValue: cid)
        await storage.store(cid: acornCid, data: data)
        await ivy.broadcastBlock(cid: cid, data: data)
    }

    public func storeBlock(cid: String, data: Data) async {
        let acornCid = ContentIdentifier(rawValue: cid)
        await storage.store(cid: acornCid, data: data)
    }

    // MARK: - IvyDelegate

    nonisolated public func ivy(_ ivy: Ivy, didConnect peer: PeerID) {}
    nonisolated public func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {}

    nonisolated public func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {
        Task { await delegate?.chainNetwork(self, didReceiveBlockAnnouncement: cid) }
    }

    nonisolated public func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {
        Task { await delegate?.chainNetwork(self, didReceiveBlock: cid, data: data) }
    }
}

// MARK: - Ivy delegate setter extension

extension Ivy {
    func setDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}
