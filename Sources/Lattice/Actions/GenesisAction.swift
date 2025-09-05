import cashew

public let GENESIS_ACTION_PROPERTIES = Set(["block"])

public struct GenesisAction {
    let directory: String
    let block: HeaderImpl<Block>
    
    func stateDelta() -> Int? {
        guard let directoryCount = directory.data(using: .utf8)?.count else { return nil }
        guard let blockCount = block.rawCID.data(using: .utf8)?.count else { return nil }
        return blockCount + directoryCount
    }
}

extension GenesisAction: Node {
    public func get(property: PathSegment) -> (any cashew.Address)? {
        switch property {
            case "block": return block
            default: return nil
        }
    }
    
    public func properties() -> Set<PathSegment> {
        return GENESIS_ACTION_PROPERTIES
    }
    
    public func set(properties: [PathSegment : any cashew.Address]) -> GenesisAction {
        return Self(directory: directory, block: properties["block"] as! HeaderImpl<Block>)
    }
}
