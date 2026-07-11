import Foundation

public struct ImportedHost: Equatable, Sendable {
    public let alias: String
    public let properties: [SSHProperty]
    public init(alias: String, properties: [SSHProperty]) {
        self.alias = alias
        self.properties = properties
    }
}

/// One-way, additive read of the user's ~/.ssh/config into importable hosts.
public struct ConfigImporter {
    private let parser = SSHConfigParser()

    public init() {}

    public func hosts(inConfigAt path: String, managedPath: String) -> [ImportedHost] {
        // `parseFile(at:)` throws on an unreadable (e.g. permission-denied) file;
        // a missing file already parses as `[]` internally, so `try?` here only
        // swallows the genuinely-unreadable case, which we treat as "nothing to
        // import" rather than propagating — this importer has no throwing
        // signature per the brief's produced interface.
        let segments = (try? parser.parseFile(at: path)) ?? []
        return parser.hosts(in: segments)
            .map { ImportedHost(alias: $0.pattern, properties: $0.properties) }
    }
}
