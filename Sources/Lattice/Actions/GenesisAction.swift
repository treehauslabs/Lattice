import cashew

public let GENESIS_ACTION_PROPERTIES = Set(["block"])

public struct GenesisAction: Codable, Sendable {
    public let directory: String
    public let block: Block
    
    func stateDelta() throws -> Int {
        guard let directoryCount = directory.data(using: .utf8)?.count else { throw ValidationErrors.serializationError }
        let genesisSize = try block.getGenesisSize()
        return genesisSize + directoryCount
    }
}
