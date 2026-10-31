import ArgumentParser
import Foundation
import SSHConfigCore

struct Hosts: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, add, edit, and remove SSH hosts.",
        discussion: "Sesh writes its hosts to ~/.ssh/sesh.conf, which your ~/.ssh/config Includes.",
        subcommands: [List.self, Show.self, Add.self, Edit.self, Duplicate.self, Delete.self, Move.self,
                      Command.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List SSH hosts, most recently changed first.")

        @Option(help: "Only hosts in this workspace (\"Default\" for those in none).") var workspace: String?
        @Option(help: "Only hosts whose name, alias, hostname, or user contains this text.") var search: String?
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let workspace = workspace, search = search?.lowercased()
            try output.emit({
                try Client.send(.listHosts, as: [HostInfo].self).filter { host in
                    if let workspace, (host.workspace ?? "Default").caseInsensitiveCompare(workspace) != .orderedSame {
                        return false
                    }
                    guard let search else { return true }
                    let fields = [host.name, host.key, host.hostname ?? ""]
                        + host.profiles.flatMap { [$0.alias, $0.user ?? ""] }
                    return fields.contains { $0.lowercased().contains(search) }
                }
            }) { hosts in
                guard !hosts.isEmpty else {
                    return workspace == nil && search == nil
                        ? "No SSH hosts yet. Add one with: sesh hosts add <name> --hostname <host> --user <user>\nOr bring in ~/.ssh/config with: sesh config import"
                        : "No hosts match."
                }
                return HostText.table(hosts) + jsonHint("sesh hosts list")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a host, its profiles, and every option it writes.")

        @Argument(help: "Alias, profile group, or display name.") var host: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.showHost(ref: host)
            try output.emit({ try Client.send(command, as: HostInfo.self) }, human: HostText.detail)
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add an SSH host.",
            discussion: """
            The alias comes from the name, as in the app ("My Server" → my-server). Add more \
            users to the same host with: sesh profiles add
            """)

        @Argument(help: "Display name, e.g. \"My Server\".") var name: String
        @Option(help: "IP address or domain to connect to.") var hostname: String
        @Option(help: "User to log in as.") var user: String
        @Option(help: "Port, when it isn't 22.") var port: String?
        @Option(help: "Private key to log in with, e.g. ~/.ssh/id_ed25519.") var identityFile: String?
        @Option(name: .customLong("option"), help: "Any other ssh option as Key=Value, e.g. ServerAliveInterval=60. Repeatable.")
        var options: [String] = []
        @Option(help: "Workspace to put it in (see: sesh workspaces list).") var workspace: String?
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let spec = HostSpec(name: name, hostname: hostname, user: user, port: port, identityFile: identityFile,
                                options: [], workspace: workspace)
            let raw = options
            try output.emit({
                var spec = spec
                spec.options = try parseOptions(raw)
                return try Client.send(.addHost(spec), as: HostInfo.self)
            }) { "Added \($0.name) as \($0.profiles[0].alias). Connect with: ssh \($0.profiles[0].alias)" }
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change a host. Connection settings apply to its default profile.",
            discussion: """
            Renaming a host renames its aliases, as in the app. To change another profile, \
            use: sesh profiles edit <alias>
            """)

        @Argument(help: "Alias, profile group, or display name.") var host: String
        @Option(help: "New display name.") var name: String?
        @Option(help: "New IP address or domain, for every profile.") var hostname: String?
        @Option(help: "Move it to this workspace.") var workspace: String?
        @Flag(help: "Move it to Default, out of any workspace.") var defaultWorkspace = false
        @OptionGroup var profile: ProfileChangeOptions
        @OptionGroup var output: OutputOptions

        func validate() throws {
            if workspace != nil && defaultWorkspace {
                throw ValidationError("Pass --workspace or --default-workspace, not both.")
            }
        }

        mutating func run() throws {
            let ref = host
            var changes = HostChanges(name: name, hostname: hostname, workspace: defaultWorkspace ? "" : workspace)
            let profile = profile
            try output.emit({
                changes.profile = try profile.changes()
                return try Client.send(.editHost(ref: ref, changes: changes), as: HostInfo.self)
            }) { "Updated \($0.name).\n\n" + HostText.detail($0) }
        }
    }

    struct Duplicate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy one alias to a new host named <alias>-copy-N.")

        @Argument(help: "The alias to copy (a host name copies its default profile).") var host: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.duplicateHost(ref: host)
            try output.emit({ try Client.send(command, as: HostInfo.self) }) { "Copied to \($0.profiles[0].alias)." }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete hosts, with all their profiles.")

        @Argument(help: "Hosts to delete.") var hosts: [String]
        @Flag(help: "Don't ask first.") var yes = false
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let refs = hosts, yes = yes
            try output.emit({
                try Confirm.check("Delete \(refs.count == 1 ? refs[0] : plural(refs.count, "host")) and all \(refs.count == 1 ? "its" : "their") profiles?", yes: yes)
                return try Client.send(.deleteHosts(refs: refs), as: ActionResult.self)
            }) { $0.message }
        }
    }

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move hosts to a workspace, or back to Default.")

        @Argument(help: "Hosts to move.") var hosts: [String]
        @Option(help: "Workspace to move them to.") var workspace: String?
        @Flag(name: .customLong("default"), help: "Move them to Default, out of any workspace.") var toDefault = false
        @OptionGroup var output: OutputOptions

        func validate() throws {
            if (workspace == nil) == !toDefault { throw ValidationError("Pass --workspace <name> or --default.") }
        }

        mutating func run() throws {
            let command = ControlCommand.moveHosts(refs: hosts, workspace: toDefault ? nil : workspace)
            try output.emit({ try Client.send(command, as: ActionResult.self) }) { $0.message }
        }
    }

    struct Command: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the ssh command for a host or profile.",
            discussion: "Run it yourself, or let Sesh open it in your terminal app with: sesh connect")

        @Argument(help: "A host or profile alias.") var host: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let ref = host
            try output.emit({ () -> ProfileInfo in
                let info = try Client.send(.showHost(ref: ref), as: HostInfo.self)
                return info.profiles.first { $0.alias.caseInsensitiveCompare(ref) == .orderedSame } ?? info.profiles[0]
            }) { $0.sshCommand }
        }
    }
}

struct Profiles: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage a host's profiles: other users or keys for the same server, each its own alias.",
        subcommands: [Add.self, Edit.self, Remove.self, Ungroup.self])

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a profile to a host. Its alias is <host>-<label>.")

        @Argument(help: "The host to add it to.") var host: String
        @Option(help: "Short name for the profile, e.g. deploy.") var label: String
        @Option(help: "User to log in as.") var user: String
        @Option(help: "Private key to log in with.") var identityFile: String?
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.addProfile(host: host, label: label, user: user, identityFile: identityFile)
            try output.emit({ try Client.send(command, as: HostInfo.self) }) { "Added a profile.\n\n" + HostText.detail($0) }
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change one profile's user, port, key, or options.",
            discussion: "Changing the user can change the profile's alias, as in the app.")

        @Argument(help: "The profile's alias (see: sesh hosts show <host>).") var alias: String
        @OptionGroup var profile: ProfileChangeOptions
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let alias = alias, profile = profile
            try output.emit({
                try Client.send(.editProfile(alias: alias, changes: profile.changes()), as: HostInfo.self)
            }) { "Updated.\n\n" + HostText.detail($0) }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove one profile from its host.")

        @Argument(help: "The profile's alias.") var alias: String
        @Flag(help: "Don't ask first.") var yes = false
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let alias = alias, yes = yes
            try output.emit({
                try Confirm.check("Remove the profile \(alias)?", yes: yes)
                return try Client.send(.removeProfile(alias: alias), as: HostInfo.self)
            }) { "Removed \(alias).\n\n" + HostText.detail($0) }
        }
    }

    struct Ungroup: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Split a host's profiles into separate hosts.")

        @Argument(help: "The host to split.") var host: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.ungroup(host: host)
            try output.emit({ try Client.send(command, as: [HostInfo].self) }) { hosts in
                "Split into \(plural(hosts.count, "host")):\n\n" + HostText.table(hosts)
            }
        }
    }
}

/// Connection-setting flags shared by `hosts edit` and `profiles edit`.
struct ProfileChangeOptions: ParsableArguments {
    @Option(help: "New user.") var user: String?
    @Option(help: "New port; \"\" goes back to 22.") var port: String?
    @Option(help: "New private key; \"\" removes it.") var identityFile: String?
    @Option(name: .customLong("option"), help: "Set an ssh option as Key=Value, replacing its old value. Repeatable.")
    var options: [String] = []
    @Option(name: .customLong("remove-option"), help: "Remove an ssh option by name. Repeatable.")
    var removeOptions: [String] = []

    func changes() throws -> ProfileChanges {
        ProfileChanges(user: user, port: port, identityFile: identityFile, setOptions: try parseOptions(options),
                       removeOptions: removeOptions)
    }
}

func parseOptions(_ raw: [String]) throws -> [SSHProperty] {
    try raw.map { option in
        switch ControlRefs.option(option) {
        case .success(let property): property
        case .failure(let failure): throw CLIError.app(failure)
        }
    }
}

enum HostText {
    static func table(_ hosts: [HostInfo]) -> String {
        let rows = hosts.map { host -> [String] in
            let lead = host.profiles[0]
            let users = host.profiles.compactMap(\.user)
            let user = users.isEmpty ? "—" : users.count == 1 ? users[0] : "\(users[0]) +\(users.count - 1)"
            return [host.name, host.hostname ?? "—", user, host.workspace ?? "Default",
                    host.profiles.map(\.alias).joined(separator: ", ") + (lead.isConnectable ? "" : " (pattern)")]
        }
        return Table.render(["NAME", "HOSTNAME", "USER", "WORKSPACE", "ALIASES"], rows)
    }

    static func detail(_ host: HostInfo) -> String {
        var text = Fields.render([
            ("Name", host.name),
            ("Key", host.key),
            ("Hostname", host.hostname ?? "—"),
            ("Workspace", host.workspace ?? "Default"),
        ])
        text += "\n\n" + (host.profiles.count == 1 ? "Profile" : "Profiles (* is the default)") + ":"
        for profile in host.profiles {
            let marker = host.profiles.count > 1 && profile.isDefault ? "*" : " "
            text += "\n\(marker) \(profile.alias)"
            if !profile.isConnectable { text += " (a pattern; not connectable)" }
            let core: Set<String> = ["hostname"]
            for option in profile.options where !core.contains(option.key.lowercased()) {
                text += "\n    \(option.key) \(option.values.joined(separator: " "))"
            }
        }
        return text
    }
}
