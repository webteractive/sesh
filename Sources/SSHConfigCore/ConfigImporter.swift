import Foundation

public struct ImportedHost: Equatable, Sendable {
    public let alias: String
    public let properties: [SSHProperty]
    public init(alias: String, properties: [SSHProperty]) {
        self.alias = alias
        self.properties = properties
    }
}

/// A single importable unit: either one standalone host (`groupName == nil`)
/// or a shared-HostName profile group whose members keep their original
/// aliases (`groupName` is the first member's alias).
public struct ImportGroup: Equatable, Sendable {
    public let displayName: String
    public let groupName: String?
    public let members: [ImportedHost]
    public init(displayName: String, groupName: String?, members: [ImportedHost]) {
        self.displayName = displayName
        self.groupName = groupName
        self.members = members
    }
}

/// One-way, additive read of the user's ~/.ssh/config into importable hosts.
public struct ConfigImporter {
    private let parser = SSHConfigParser()

    public init() {}

    public func hosts(inConfigAt path: String) -> [ImportedHost] {
        // `parseFile(at:)` throws on an unreadable (e.g. permission-denied) file;
        // a missing file already parses as `[]` internally, so `try?` here only
        // swallows the genuinely-unreadable case, which we treat as "nothing to
        // import" rather than propagating — this importer has no throwing
        // signature per the brief's produced interface.
        let segments = (try? parser.parseFile(at: path)) ?? []
        return parser.hosts(in: segments)
            .map { ImportedHost(alias: $0.pattern, properties: $0.properties) }
    }

    /// A host's `Host` pattern is only directly connectable (and thus
    /// groupable) when it's a single literal alias — no wildcards, negation,
    /// or multiple space-separated patterns.
    private static func isWildcard(_ alias: String) -> Bool {
        alias.contains(where: { "*?! ".contains($0) })
    }

    /// Groups hosts sharing a `HostName` into one profile group when the
    /// bucket has ≥2 members with ≥2 distinct `User` values; every other host
    /// (including wildcard patterns and same-HostName-same-user buckets)
    /// becomes its own singleton group. Order follows first appearance in the
    /// file: a group appears where its first member was encountered, and a
    /// non-grouped bucket's members appear as singletons in their own
    /// encounter order.
    public func groups(inConfigAt path: String) -> [ImportGroup] {
        let hostList = hosts(inConfigAt: path)

        // Bucket groupable hosts by HostName, remembering encounter order.
        var buckets: [String: [ImportedHost]] = [:]
        // `nil` HostName key stands in for "this position holds a standalone
        // entry" (wildcard pattern, or no HostName at all) — each gets a
        // unique key so it doesn't collide with others.
        var standalone: [String: ImportedHost] = [:]
        var order: [String] = []   // sequence of keys (bucket keys or standalone keys), first-seen

        for (i, host) in hostList.enumerated() {
            let hostName = host.properties.first("HostName")
            if Self.isWildcard(host.alias) || hostName == nil {
                let key = "\u{0}standalone:\(i)"
                standalone[key] = host
                order.append(key)
                continue
            }
            let key = hostName!
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(host)
        }

        var result: [ImportGroup] = []
        for key in order {
            if let host = standalone[key] {
                result.append(ImportGroup(displayName: host.alias, groupName: nil, members: [host]))
                continue
            }
            let members = buckets[key]!
            let distinctUsers = Set(members.map { $0.properties.first("User") ?? "" })
            if members.count >= 2 && distinctUsers.count >= 2 {
                let prefix = Self.commonAliasPrefix(members.map(\.alias))
                let displayName = prefix.count >= 2 ? prefix : members[0].alias
                result.append(ImportGroup(displayName: displayName, groupName: members[0].alias, members: members))
            } else {
                // Not groupable (single member, or all sharing one user) —
                // each member becomes its own singleton, in encounter order.
                for m in members {
                    result.append(ImportGroup(displayName: m.alias, groupName: nil, members: [m]))
                }
            }
        }
        return result
    }

    /// Longest common prefix across `aliases`, trimmed of trailing `.`, `-`,
    /// `_` separators. Falls back to the sole alias when only one is given,
    /// and to `""` when there's no shared prefix at all.
    public static func commonAliasPrefix(_ aliases: [String]) -> String {
        guard let first = aliases.first else { return "" }
        guard aliases.count > 1 else { return first }
        var prefix = first
        for alias in aliases.dropFirst() {
            while !prefix.isEmpty, !alias.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
            }
            if prefix.isEmpty { return "" }
        }
        while let last = prefix.last, ".-_".contains(last) {
            prefix = String(prefix.dropLast())
        }
        return prefix
    }
}
