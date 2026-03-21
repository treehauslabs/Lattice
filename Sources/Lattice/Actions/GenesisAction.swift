import cashew

public let GENESIS_ACTION_PROPERTIES = Set(["block"])

public struct GenesisAction: Codable, Sendable {
    public let directory: String
    public let block: Block
    
    func stateDelta() throws -> Int {
        try block.getGenesisSize() + directory.utf8.count
    }
}
