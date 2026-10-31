import Foundation

/// How the CLI's names for things are matched to the store's items.
public enum ControlRefs {
    public struct HostCandidate: Sendable {
        public var alias: String
        public var groupKey: String
        public var displayName: String?

        public init(alias: String, groupKey: String, displayName: String?) {
            self.alias = alias
            self.groupKey = groupKey
            self.displayName = displayName
        }
    }

    /// The group key of the logical host `ref` names: an exact alias or
    /// group key first, then a display name, alias, or key ignoring case.
    public static func hostKey(_ ref: String, in hosts: [HostCandidate]) -> Result<String, ControlFailure> {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        if let host = hosts.first(where: { $0.alias == ref }) { return .success(host.groupKey) }
        if hosts.contains(where: { $0.groupKey == ref }) { return .success(ref) }
        let keys = orderedUnique(hosts.filter {
            $0.alias.caseInsensitiveCompare(ref) == .orderedSame
                || $0.groupKey.caseInsensitiveCompare(ref) == .orderedSame
                || $0.displayName?.caseInsensitiveCompare(ref) == .orderedSame
        }.map(\.groupKey))
        switch keys.count {
        case 0: return .failure(ControlFailure(.notFound, "No host named '\(ref)'. List them with: sesh hosts list"))
        case 1: return .success(keys[0])
        default: return .failure(ControlFailure(.ambiguous, "'\(ref)' matches several hosts: \(keys.joined(separator: ", ")). Use an alias."))
        }
    }

    /// The id of the hosts-file entry `ref` names: a full id, an id prefix of
    /// at least four characters, or a hostname the entry maps.
    public static func hostsEntryID(_ ref: String, in entries: [(id: UUID, hostnames: [String])])
        -> Result<UUID, ControlFailure> {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: ref), entries.contains(where: { $0.id == id }) { return .success(id) }
        var matches: [UUID] = []
        if ref.count >= 4, ref.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            matches = entries.map(\.id).filter { $0.uuidString.lowercased().hasPrefix(ref.lowercased()) }
        }
        if matches.isEmpty {
            matches = entries.filter { $0.hostnames.contains { $0.caseInsensitiveCompare(ref) == .orderedSame } }
                .map(\.id)
        }
        switch matches.count {
        case 0:
            return .failure(ControlFailure(.notFound, "No hosts-file entry matches '\(ref)'. List them with: sesh hosts-file list"))
        case 1:
            return .success(matches[0])
        default:
            let ids = matches.map { shortID($0) }.joined(separator: ", ")
            return .failure(ControlFailure(.ambiguous, "'\(ref)' matches several hosts-file entries (\(ids)). Use an id."))
        }
    }

    /// The workspace `ref` names, by id or by name ignoring case.
    public static func workspaceID(_ ref: String, in workspaces: [(id: UUID, name: String)])
        -> Result<UUID, ControlFailure> {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: ref), workspaces.contains(where: { $0.id == id }) { return .success(id) }
        if let ws = workspaces.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) {
            return .success(ws.id)
        }
        return .failure(ControlFailure(.notFound, "No workspace named '\(ref)'. List them with: sesh workspaces list"))
    }

    /// The first eight characters of an id, as the CLI shows it.
    public static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    /// Parses `Key=Value` (or `Key Value`) into an option. Keys the CLI has
    /// its own flags for, and anything an import would refuse, are rejected.
    public static func option(_ raw: String) -> Result<SSHProperty, ControlFailure> {
        let separator = raw.firstIndex(where: { $0 == "=" || $0 == " " })
        guard let separator else {
            return .failure(ControlFailure(.invalid, "'\(raw)' isn't an option. Write it as Key=Value, e.g. ServerAliveInterval=60."))
        }
        let key = String(raw[..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(raw[raw.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        if let flag = coreOptionFlags[key.lowercased()] {
            return .failure(ControlFailure(.invalid, "Set \(key) with \(flag), not --option."))
        }
        if value.isEmpty { return .failure(ControlFailure(.invalid, "Option \(key) has no value.")) }
        if let problem = SSHOptionRules.problem(key: key, values: [value]) {
            return .failure(ControlFailure(.invalid, problem))
        }
        return .success(SSHProperty(key: key, values: [value]))
    }

    private static let coreOptionFlags = [
        "hostname": "--hostname", "user": "--user", "port": "--port", "identityfile": "--identity-file",
    ]

    private static func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// What may be written as an option under a `Host` line.
public enum SSHOptionRules {
    /// Why `key` with `values` can't go under a host, or nil when it can:
    /// an odd option name, a line break, or a keyword that opens a block or
    /// pulls in a file (written under a host, those escape it).
    public static func problem(key: String, values: [String]) -> String? {
        if key.range(of: "^[A-Za-z][A-Za-z0-9]*$", options: .regularExpression) == nil {
            return "'\(key)' isn't a valid option name."
        }
        if ["host", "match", "include"].contains(key.lowercased()) {
            return "A '\(key)' line can't go inside a host."
        }
        if values.contains(where: hasLineBreak) {
            return "The \(key) value has a line break."
        }
        return nil
    }

    /// A line break, or another control character, in text bound for a
    /// config line would start a line of its own.
    public static func hasLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
    }
}
