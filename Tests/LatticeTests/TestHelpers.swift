import Foundation
@testable import Lattice
import cashew

enum FetcherError: Error {
    case notFound(String)
}

actor StorableFetcher: Fetcher {
    private var store: [String: Data] = [:]

    func store(rawCid: String, data: Data) {
        store[rawCid] = data
    }

    func fetch(rawCid: String) async throws -> Data {
        guard let data = store[rawCid] else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }
}

struct ThrowingFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw FetcherError.notFound(rawCid)
    }
}

/// Synchronous storer that collects CAS data in memory, then flushes to a StorableFetcher.
final class CollectingStorer: Storer, @unchecked Sendable {
    private var collected: [(String, Data)] = []

    func store(rawCid: String, data: Data) throws {
        collected.append((rawCid, data))
    }

    func flush(to fetcher: StorableFetcher) async {
        for (cid, data) in collected {
            await fetcher.store(rawCid: cid, data: data)
        }
    }
}
