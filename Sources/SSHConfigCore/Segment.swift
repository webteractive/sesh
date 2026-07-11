public struct ParsedHost: Equatable, Sendable {
    public var pattern: String
    public var properties: [SSHProperty]
    public var rawBlock: String

    public init(pattern: String, properties: [SSHProperty], rawBlock: String) {
        self.pattern = pattern
        self.properties = properties
        self.rawBlock = rawBlock
    }
}

public enum Segment: Equatable, Sendable {
    case prologue(String)
    case comment(String)
    case include(String)
    case matchBlock(String)
    case hostBlock(ParsedHost)
}
