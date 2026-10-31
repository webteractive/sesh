import ArgumentParser
import Foundation
import SSHConfigCore

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export SSH hosts and hosts-file entries to a Sesh export file (JSON).",
        discussion: """
        Exports every SSH host and hosts-file entry Sesh has, unless you pick some. The file \
        holds settings, profiles, workspaces, and identity file paths, never keys, and is \
        written readable by you only. Hosts that can't be exported (see `sesh import`) are \
        left out and named.

          sesh export ~/Desktop/sesh.json
          sesh export --host web --host db --no-hosts-file > hosts.json
        """)

    @Argument(help: "File to write; - or nothing writes to standard output.") var file: String?
    @Option(name: .customLong("host"), help: "Export only this SSH host. Repeatable.") var hosts: [String] = []
    @Option(name: .customLong("hosts-entry"), help: "Export only this hosts-file entry, by id or hostname. Repeatable.")
    var hostsEntries: [String] = []
    @Flag(help: "Leave out SSH hosts.") var noSshHosts = false
    @Flag(help: "Leave out hosts-file entries.") var noHostsFile = false
    @Flag(help: "Also export hosts that are only in ~/.ssh/config, not in Sesh.") var includeConfigOnly = false
    @Flag(help: "Overwrite the file if it exists.") var force = false
    @OptionGroup var output: OutputOptions

    struct Summary: Encodable {
        var path: String
        var sshHosts: [String]
        var hostsEntries: Int
        var skipped: [Skip]

        struct Skip: Encodable {
            var host: String
            var reason: String
        }
    }

    mutating func run() throws {
        let toStdout = file == nil || file == "-"
        let command = self
        if toStdout {
            // The archive is the output, so --json changes nothing here.
            do {
                let (archive, summary) = try command.build()
                print(String(decoding: try archive.encoded(), as: UTF8.self))
                for skip in summary.skipped {
                    FileHandle.standardError.write(Data("warning: left out \(skip.host): \(skip.reason)\n".utf8))
                }
            } catch let error as CLIError {
                throw output.fail(error)
            }
            return
        }
        try output.emit({ () -> Summary in
            let (archive, summary) = try command.build()
            try command.write(archive, to: summary.path)
            return summary
        }) { summary in
            var lines = ["Exported \(plural(summary.sshHosts.count, "SSH host")) and \(plural(summary.hostsEntries, "hosts-file entry", "hosts-file entries")) to \(summary.path)."]
            lines += summary.skipped.map { "Left out \($0.host): \($0.reason)" }
            return lines.joined(separator: "\n")
        }
    }

    private func build() throws -> (SeshArchive, Summary) {
        let export = try Client.send(.exportArchive(includeConfigOnly: includeConfigOnly), as: ExportInfo.self)
        var archive = export.archive
        let configOnly = Set(export.configOnly)

        var keys: [String] = []
        if !noSshHosts {
            let candidates = archive.sshHosts.map {
                ControlRefs.HostCandidate(alias: $0.alias, groupKey: $0.groupKey, displayName: $0.displayName)
            }
            keys = hosts.isEmpty
                ? archive.sshGroups.map { $0[0].groupKey }
                : try hosts.map { try ControlRefs.hostKey($0, in: candidates).get() }
            if hosts.isEmpty && !includeConfigOnly { keys.removeAll { configOnly.contains($0) } }
        }
        var skipped: [Summary.Skip] = []
        for group in archive.sshGroups where keys.contains(group[0].groupKey) {
            if let problem = group.lazy.compactMap(\.problem).first {
                skipped.append(.init(host: group[0].groupKey, reason: problem))
                keys.removeAll { $0 == group[0].groupKey }
            }
        }

        var indices = Set<Int>()
        if !noHostsFile {
            if hostsEntries.isEmpty {
                indices = Set(archive.hostsEntries.indices)
            } else {
                let entries = try Client.send(.listHostsEntries, as: [HostsEntryInfo].self)
                for ref in hostsEntries {
                    let id = try ControlRefs.hostsEntryID(ref, in: entries.map { (id: $0.id, hostnames: $0.hostnames) }).get()
                    if let entry = entries.first(where: { $0.id == id }) { indices.insert(entry.position - 1) }
                }
            }
        }
        archive = archive.selecting(sshGroups: Set(keys), hostsEntries: indices)
        guard !archive.sshHosts.isEmpty || !archive.hostsEntries.isEmpty else {
            throw CLIError.invalid("Nothing to export.")
        }
        let path = file.map(absolutePath) ?? "-"
        return (archive, Summary(path: path, sshHosts: keys, hostsEntries: archive.hostsEntries.count, skipped: skipped))
    }

    private func write(_ archive: SeshArchive, to path: String) throws {
        if !force, FileManager.default.fileExists(atPath: path) {
            throw CLIError.invalid("\(path) already exists. Pass --force to overwrite it.")
        }
        do {
            try SSHConfigWriter().writeData(archive.encoded(), toPath: path)
        } catch {
            throw CLIError.failed("Couldn't write \(path): \(error.localizedDescription)")
        }
    }
}

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import a Sesh export file.",
        discussion: """
        Imports everything in the file Sesh doesn't already have: SSH hosts by alias, \
        hosts-file entries by IP and hostnames. Risky SSH hosts are left out unless you \
        pass --allow-risky: ones that set any option beyond where to connect, as whom \
        and how patiently (HostName, User, Port, IdentityFile, ServerAliveInterval, …), \
        since others run commands (ProxyCommand, RemoteCommand), open ports or send \
        your environment (RemoteForward, SendEnv), or loosen host key checks \
        (StrictHostKeyChecking, HostKeyAlias); ones that would \
        replace a host in your ~/.ssh/config, and ones named like a real server \
        (github.com) whose HostName points elsewhere. Hosts-file entries go in first, behind one password prompt, so \
        cancelling it imports nothing.

        Preview what would happen with --dry-run.
        """)

    @Argument(help: "The export file; - reads standard input.") var file: String
    @Option(name: .customLong("host"), help: "Import only this SSH host from the file. Repeatable.") var hosts: [String] = []
    @Flag(help: "Leave out SSH hosts.") var noSshHosts = false
    @Flag(help: "Leave out hosts-file entries.") var noHostsFile = false
    @Flag(help: "Also import risky SSH hosts (see above).") var allowRisky = false
    @Flag(help: "Show what would be imported, and change nothing.") var dryRun = false
    @OptionGroup var output: OutputOptions

    struct Plan: Encodable {
        var file: String
        var sshHosts: [Host]
        var hostsEntries: [Entry]
        /// Set when the import ran.
        var result: ActionResult?

        struct Host: Encodable {
            var key: String
            var name: String
            var aliases: [String]
            /// "import", "exists", "risky", or "notPicked".
            var action: String
            /// Why it's risky, when it is (see `SeshArchive.risks`).
            var risks: [String]
        }

        struct Entry: Encodable {
            var ip: String
            var hostnames: [String]
            var isEnabled: Bool
            /// "import", "exists", or "notPicked".
            var action: String
        }
    }

    mutating func run() throws {
        let command = self
        try output.emit({ try command.importFile() }) { plan in
            var lines: [String] = []
            if let result = plan.result { lines.append(result.message) } else { lines.append("Dry run; nothing was changed.") }
            for host in plan.sshHosts {
                lines.append("  \(Self.mark(host.action)) SSH host \(host.name) (\(host.aliases.joined(separator: ", ")))\(Self.reason(host))")
            }
            for entry in plan.hostsEntries {
                lines.append("  \(Self.mark(entry.action)) hosts entry \(entry.ip) \(entry.hostnames.joined(separator: " "))\(entry.action == "exists" ? " — already in Sesh" : "")")
            }
            if plan.sshHosts.contains(where: { $0.action == "risky" }) {
                lines.append("Hosts marked ! are risky. Check them, then import them with --allow-risky.")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func mark(_ action: String) -> String {
        switch action {
        case "import": "+"
        case "risky": "!"
        default: "-"
        }
    }

    private static func reason(_ host: Plan.Host) -> String {
        switch host.action {
        case "exists": " — already in Sesh"
        case "risky": " — " + host.risks.joined(separator: "; ")
        case "notPicked": " — not picked"
        default: ""
        }
    }

    private func importFile() throws -> Plan {
        let archive = try readArchive()
        let preview = try Client.send(.previewImport(archive), as: ImportPreview.self)
        let existingHosts = Set(preview.existingHosts)
        let existingEntries = Set(preview.existingHostsEntries)
        let configAliases = Set(preview.configAliases)

        var picked: Set<String>?
        if !hosts.isEmpty {
            let candidates = archive.sshHosts.map {
                ControlRefs.HostCandidate(alias: $0.alias, groupKey: $0.groupKey, displayName: $0.displayName)
            }
            picked = Set(try hosts.map { try ControlRefs.hostKey($0, in: candidates).get() })
        }

        var plan = Plan(file: file, sshHosts: [], hostsEntries: [])
        for group in archive.sshGroups {
            let key = group[0].groupKey
            let risks = SeshArchive.risks(of: group, configAliases: configAliases)
            let action: String
            if noSshHosts || picked.map({ !$0.contains(key) }) == true {
                action = "notPicked"
            } else if existingHosts.contains(key) {
                action = "exists"
            } else if !risks.isEmpty && !allowRisky {
                action = "risky"
            } else {
                action = "import"
            }
            let lead = group.first(where: \.isDefaultProfile) ?? group[0]
            plan.sshHosts.append(.init(key: key, name: lead.displayName ?? key, aliases: group.map(\.alias),
                                       action: action, risks: risks))
        }
        for (index, entry) in archive.hostsEntries.enumerated() {
            let action = noHostsFile ? "notPicked" : existingEntries.contains(index) ? "exists" : "import"
            plan.hostsEntries.append(.init(ip: entry.ip, hostnames: entry.hostnames, isEnabled: entry.isEnabled,
                                           action: action))
        }

        let keys = Set(plan.sshHosts.filter { $0.action == "import" }.map(\.key))
        let indices = Set(plan.hostsEntries.indices.filter { plan.hostsEntries[$0].action == "import" })
        guard !dryRun else { return plan }
        guard !keys.isEmpty || !indices.isEmpty else {
            plan.result = ActionResult("Nothing to import.", added: 0)
            return plan
        }
        plan.result = try Client.send(.importArchive(archive.selecting(sshGroups: keys, hostsEntries: indices)),
                                      as: ActionResult.self)
        return plan
    }

    private func readArchive() throws -> SeshArchive {
        let data: Data
        let name: String
        if file == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
            name = "Standard input"
        } else {
            guard let contents = FileManager.default.contents(atPath: absolutePath(file)) else {
                throw CLIError.notFound("Couldn't read \(file).")
            }
            data = contents
            name = (file as NSString).lastPathComponent
        }
        do {
            return try SeshArchive.decode(data)
        } catch SeshArchiveError.unreadable {
            throw CLIError.invalid("\(name) isn't a Sesh export.")
        } catch SeshArchiveError.newerVersion {
            throw CLIError.unsupported("\(name) was exported by a newer Sesh. Update Sesh (sesh update install), then import it again.")
        } catch SeshArchiveError.invalid(let reason) {
            throw CLIError.invalid("\(name) wasn't imported: \(reason)")
        }
    }
}

/// `path` made absolute against the shell's directory, so the app (which
/// runs elsewhere) and messages see the same file. `~` is expanded.
func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
    return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
}
