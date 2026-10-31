import Foundation

public enum SeshArchiveError: Error, Equatable {
    /// Not JSON, or not shaped like a Sesh export.
    case unreadable
    /// Written by a newer Sesh that may carry fields this build would drop.
    case newerVersion(Int)
    /// Parsed, but an item would write something unsafe or malformed.
    case invalid(String)
}

/// A portable export of Sesh's SSH hosts and /etc/hosts entries, as JSON.
/// Carries the app-only fields too (display name, profile grouping,
/// workspace by name) so an import on another Mac rebuilds the same sidebar.
public struct SeshArchive: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct SSHHost: Codable, Equatable, Sendable {
        public var alias: String
        public var properties: [SSHProperty]
        public var displayName: String?
        public var groupName: String?
        public var isDefaultProfile: Bool
        /// Workspace name; nil is Default.
        public var workspace: String?

        public init(alias: String, properties: [SSHProperty], displayName: String? = nil,
                    groupName: String? = nil, isDefaultProfile: Bool = false, workspace: String? = nil) {
            self.alias = alias
            self.properties = properties
            self.displayName = displayName
            self.groupName = groupName
            self.isDefaultProfile = isDefaultProfile
            self.workspace = workspace
        }

        /// Why this host can't travel in an export, or nil when it can.
        /// Anything that would write a broken or injected line is refused: a
        /// line break in the alias or a value, an odd option name, or an
        /// option that opens a block or pulls in a file — written under a
        /// host those escape it (`Match exec` runs a command on every
        /// connection, past the `riskyOptions` warning). So is an alias that
        /// is a pattern (`*`, `!`, `?`) or several, which would apply its
        /// settings to hosts besides itself — `Host *` to every connection.
        public var problem: String? {
            if alias.isEmpty || SSHOptionRules.hasLineBreak(alias)
                || alias.contains(where: { $0.isWhitespace || "#*?!\",".contains($0) }) {
                return "'\(alias)' isn't a usable Host alias."
            }
            for property in properties {
                if let problem = SSHOptionRules.problem(key: property.key, values: property.values) {
                    return "Host '\(alias)': \(problem)"
                }
            }
            return nil
        }

        /// One logical host: profiles share their group, a lone host is its own.
        public var groupKey: String { groupName ?? alias }

        /// Options that make ssh run a local command or load a library when
        /// connecting, or loosen what it checks and shares: host key checks,
        /// agent and X11 forwarding. A file from someone else carrying one
        /// deserves a look before it lands in ~/.ssh/sesh.conf.
        public var riskyOptions: [String] {
            let risky: Set<String> = [
                "proxycommand", "localcommand", "permitlocalcommand", "knownhostscommand",
                "pkcs11provider", "securitykeyprovider", "xauthlocation",
                "stricthostkeychecking", "userknownhostsfile", "globalknownhostsfile", "identityagent",
                "forwardagent", "forwardx11", "forwardx11trusted",
            ]
            return properties.map(\.key).filter { risky.contains($0.lowercased()) }
        }
    }

    public struct HostsEntry: Codable, Equatable, Sendable {
        public var ip: String
        public var hostnames: [String]
        public var note: String?
        public var isEnabled: Bool

        public init(_ line: HostsLine) {
            ip = line.ip
            hostnames = line.hostnames
            note = line.note
            isEnabled = line.isEnabled
        }

        public var line: HostsLine {
            HostsLine(ip: ip, hostnames: hostnames, note: note, isEnabled: isEnabled)
        }
    }

    public var version: Int
    public var exportedAt: Date
    public var sshHosts: [SSHHost]
    public var hostsEntries: [HostsEntry]

    public init(sshHosts: [SSHHost], hostsEntries: [HostsEntry], exportedAt: Date = .now) {
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.sshHosts = sshHosts
        self.hostsEntries = hostsEntries
    }

    /// SSH hosts bundled into logical hosts, in order of first appearance.
    public var sshGroups: [[SSHHost]] {
        var order: [String] = []
        var byKey: [String: [SSHHost]] = [:]
        for host in sshHosts {
            if byKey[host.groupKey] == nil { order.append(host.groupKey) }
            byKey[host.groupKey, default: []].append(host)
        }
        return order.map { byKey[$0]! }
    }

    /// Logical hosts of one workspace; a nil `workspace` is Default.
    public struct SSHSection: Equatable, Sendable {
        public let workspace: String?
        public let groups: [[SSHHost]]
    }

    /// `sshGroups` by workspace, laid out like the sidebar: Default first,
    /// then the names in `order` (matched ignoring case), then any other
    /// names A–Z. A logical host goes where its default profile is.
    public func sshSections(workspaceOrder order: [String]) -> [SSHSection] {
        var byName: [String: [[SSHHost]]] = [:]
        var names: [String: String] = [:]
        var defaultGroups: [[SSHHost]] = []
        for group in sshGroups {
            let lead = group.first(where: \.isDefaultProfile) ?? group[0]
            guard let name = lead.workspace?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                defaultGroups.append(group)
                continue
            }
            byName[name.lowercased(), default: []].append(group)
            if names[name.lowercased()] == nil { names[name.lowercased()] = name }
        }
        var sections = defaultGroups.isEmpty ? [] : [SSHSection(workspace: nil, groups: defaultGroups)]
        for name in order {
            if let groups = byName.removeValue(forKey: name.lowercased()) {
                sections.append(SSHSection(workspace: name, groups: groups))
            }
        }
        for key in byName.keys.sorted() {
            sections.append(SSHSection(workspace: names[key], groups: byName[key]!))
        }
        return sections
    }

    /// Whether an import would add nothing from `group`, given the store's
    /// aliases and group names: every alias is taken, or it's a plain host
    /// named like an existing group (see `planSSHImport`).
    public static func isPresent(_ group: [SSHHost], existingAliases: Set<String>, existingGroups: Set<String>) -> Bool {
        if group.count == 1, group[0].groupName == nil, existingGroups.contains(group[0].alias) { return true }
        return group.allSatisfy { existingAliases.contains($0.alias) }
    }

    /// Why importing `group` deserves a look first, or empty: risky options;
    /// an alias that's one of the user's ~/.ssh/config hosts (Sesh's
    /// Include comes first, so its settings would win); or an alias that's a
    /// domain name with HostName pointing elsewhere, so `ssh github.com`
    /// would go somewhere else. `configAliases` are lowercased.
    public static func risks(of group: [SSHHost], configAliases: Set<String>) -> [String] {
        var risks: [String] = []
        let options = Array(Set(group.flatMap(\.riskyOptions))).sorted()
        if !options.isEmpty { risks.append("sets \(options.joined(separator: ", "))") }
        for host in group {
            let alias = host.alias.lowercased()
            if configAliases.contains(alias) {
                risks.append("replaces \(host.alias) from your ~/.ssh/config")
            } else if let target = host.properties.first("HostName"), target.lowercased() != alias,
                      looksLikeDomain(alias) {
                risks.append("sends \(host.alias) to \(target)")
            }
        }
        return risks
    }

    /// "github.com", not "web" or "10.0.0.5": dotted, ending in letters.
    static func looksLikeDomain(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, last.count >= 2 else { return false }
        return last.allSatisfy(\.isLetter) && labels.allSatisfy { !$0.isEmpty }
    }

    /// This archive cut down to the logical hosts in `sshGroups` (by
    /// `groupKey`) and the hosts entries at `hostsEntries` indices.
    public func selecting(sshGroups keys: Set<String>, hostsEntries indices: Set<Int>) -> SeshArchive {
        var copy = self
        copy.sshHosts = sshHosts.filter { keys.contains($0.groupKey) }
        copy.hostsEntries = hostsEntries.indices.filter(indices.contains).map { hostsEntries[$0] }
        return copy
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Decodes and validates an export. Any SSH host with a `problem`, or a
    /// hosts entry `HostsFile.validate` rejects, refuses the whole file.
    public static func decode(_ data: Data) throws -> SeshArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).version
        } catch {
            throw SeshArchiveError.unreadable
        }
        guard version <= currentVersion else { throw SeshArchiveError.newerVersion(version) }
        let archive: SeshArchive
        do {
            archive = try decoder.decode(SeshArchive.self, from: data)
        } catch {
            throw SeshArchiveError.unreadable
        }
        if let message = archive.validationError() { throw SeshArchiveError.invalid(message) }
        return archive
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }

    private func validationError() -> String? {
        if let problem = sshHosts.lazy.compactMap(\.problem).first { return problem }
        for entry in hostsEntries {
            if let message = HostsFile.validate(ip: entry.ip, hostnames: entry.hostnames, note: entry.note) {
                return message
            }
        }
        return nil
    }

    /// Which of `hosts` an import adds to a store holding `existingAliases`
    /// (profile groups named in `existingGroups`). An alias already present,
    /// or repeated in the file, is skipped. Profiles joining a group the
    /// store already has never become its default; a new group whose default
    /// was skipped promotes its first added profile; and a new group left
    /// with one profile becomes a plain host.
    ///
    /// A logical host is keyed by its group name, or by its alias when it
    /// has none, so keys must not collide with the store's: a new group
    /// named like an existing alias is renamed ("prod-2"), and a plain host
    /// whose alias is an existing group's name is skipped.
    public static func planSSHImport(_ hosts: [SSHHost], existingAliases: Set<String>,
                                     existingGroups: Set<String>) -> (added: [SSHHost], skipped: Int) {
        var taken = existingAliases
        var added: [SSHHost] = []
        for host in hosts {
            if host.groupName == nil && existingGroups.contains(host.alias) { continue }
            guard taken.insert(host.alias).inserted else { continue }
            added.append(host)
        }
        let skipped = hosts.count - added.count

        var membersByGroup: [String: [Int]] = [:]
        for (index, host) in added.enumerated() {
            if let group = host.groupName { membersByGroup[group, default: []].append(index) }
        }
        for (group, indices) in membersByGroup {
            if existingGroups.contains(group) {
                for i in indices { added[i].isDefaultProfile = false }
            } else if indices.count == 1 {
                added[indices[0]].groupName = nil
                added[indices[0]].isDefaultProfile = false
            } else {
                let defaults = indices.filter { added[$0].isDefaultProfile }
                for i in defaults.dropFirst() { added[i].isDefaultProfile = false }
                if defaults.isEmpty { added[indices[0]].isDefaultProfile = true }
                if existingAliases.contains(group) {
                    let keys = existingAliases.union(existingGroups).union(membersByGroup.keys).union(added.map(\.alias))
                    let renamed = (2...).lazy.map { "\(group)-\($0)" }.first { !keys.contains($0) }!
                    for i in indices { added[i].groupName = renamed }
                }
            }
        }
        return (added, skipped)
    }
}
