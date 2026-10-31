import ArgumentParser
import Foundation
import SSHConfigCore

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show what Sesh manages: counts, file paths, links, and the hosts-file state.")

    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        try output.emit({ try Client.send(.status, as: StatusInfo.self) }) { status in
            Fields.render([
                ("Sesh", "\(status.appVersion)  \(status.appPath)"),
                ("SSH hosts", "\(plural(status.hostCount, "host")), \(plural(status.profileCount, "alias", "aliases")) in \(plural(status.workspaceCount, "workspace"))"),
                ("SSH config", status.config.configPath ?? "\(ConfigPathStore.defaultSuggestion) (not chosen yet)"),
                ("Managed file", "\(status.config.managedPath) — \(status.config.isLinked ? "linked" : "not linked; run: sesh config link")"),
                ("/etc/hosts", hostsFileSummary(status.hostsFile)),
                ("Terminal", status.terminal.name),
                ("Update", status.availableUpdate.map { "\($0) is available; run: sesh update install" }),
            ]) + jsonHint("sesh status")
        }
    }
}

func hostsFileSummary(_ status: HostsFileStatusInfo) -> String {
    var text = "\(plural(status.entryCount, "entry", "entries")), \(status.enabledCount) enabled"
    if !status.inSync { text += " — out of sync; run: sesh hosts-file reapply" }
    if !status.overridden.isEmpty { text += " — \(status.overridden.count) overridden by earlier lines" }
    return text
}

struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open an SSH session in your terminal app.",
        discussion: "Naming a host opens its default profile; name a profile's alias to pick another.")

    @Argument(help: "A host or profile alias.") var host: String
    @Option(help: "Terminal to open it in, by name or bundle id, instead of the one set in Settings (see: sesh terminals).")
    var terminal: String?
    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        let command = ControlCommand.connect(alias: host, terminal: terminal)
        try output.emit({ try Client.send(command, as: ActionResult.self) }) { $0.message }
    }
}

struct Terminals: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the installed terminal apps Connect can open. Choose one with: sesh settings set-terminal")

    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        try output.emit({ try Client.send(.showSettings, as: SettingsInfo.self).terminals }) { terminals in
            guard !terminals.isEmpty else {
                return "No terminal that opens ssh:// links is installed, so Connect uses the system default."
            }
            let rows = terminals.map { [$0.isSelected ? "*" : "", $0.name, $0.id] }
            return Table.render(["", "NAME", "ID"], rows) + "\n\n* opens connections" + jsonHint("sesh terminals")
        }
    }
}

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check for and install Sesh updates.",
        subcommands: [Check.self, Install.self])

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check GitHub for a newer Sesh.")
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Update.checked(Client.send(.checkForUpdates, as: UpdateInfo.self)) },
                            human: Update.describe)
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download and install the newest Sesh. Sesh quits and restarts to finish.")
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Update.checked(Client.send(.installUpdate, as: UpdateInfo.self)) },
                            human: Update.describe)
        }
    }

    /// A failed check is an error, not a result.
    static func checked(_ info: UpdateInfo) throws -> UpdateInfo {
        if info.state == .failed { throw CLIError.failed(info.message ?? "Couldn't check for updates.") }
        return info
    }

    static func describe(_ info: UpdateInfo) -> String {
        switch info.state {
        case .upToDate: "Sesh \(info.currentVersion) is up to date."
        case .available:
            "Sesh \(info.latestVersion ?? "?") is available (you have \(info.currentVersion))."
                + (info.isInstallable ? " Install it with: sesh update install" : " \(info.message ?? "")")
        case .installing: info.message ?? "Installing an update."
        case .failed: info.message ?? "Couldn't check for updates."
        }
    }
}
