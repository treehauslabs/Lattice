import Foundation
import cashew
import Acorn

public actor AcornFetcher: Fetcher {
    private let worker: any AcornCASWorker

    public init(worker: any AcornCASWorker) {
        self.worker = worker
    }

    public func fetch(rawCid: String) async throws -> Data {
        let cid = ContentIdentifier(rawValue: rawCid)
        guard let data = await worker.get(cid: cid) else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    public func store(rawCid: String, data: Data) async {
        let cid = ContentIdentifier(rawValue: rawCid)
        await worker.store(cid: cid, data: data)
    }
}

public enum FetcherError: Error {
    case notFound(String)
}
