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
