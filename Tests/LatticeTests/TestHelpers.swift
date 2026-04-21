import Foundation
import os
@testable import Lattice
import cashew

enum FetcherError: Error {
    case notFound(String)
}

final class StorableFetcher: Fetcher, Storer, Sendable {
    private let state = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    func store(rawCid: String, data: Data) {
        state.withLock { $0[rawCid] = data }
    }

    func contains(rawCid: String) -> Bool {
        state.withLock { $0[rawCid] != nil }
    }

    func fetch(rawCid: String) async throws -> Data {
        guard let data = state.withLock({ $0[rawCid] }) else {
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
