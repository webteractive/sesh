import ArgumentParser
import Darwin
import Foundation
import SSHConfigCore

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Link Sesh into your ssh config, import from it, and set where things live.",
        discussion: """
        Sesh writes its hosts to a managed file (~/.ssh/sesh.conf by default) and adds one \
        Include line for it to your ssh config. Nothing else in your config is changed.
        """,
        subcommands: [Status.self, Link.self, Import.self, Show.self, SetPath.self, SetManagedPath.self])

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the config paths and whether Sesh is linked in.")
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Client.send(.configStatus, as: ConfigStatusInfo.self) }, human: ConfigText.status)
        }
    }

    struct Link: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write the managed file and add its Include line to your ssh config (backed up first).")
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Client.send(.linkInclude, as: ConfigStatusInfo.self) }, human: ConfigText.status)
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add the hosts in your ssh config that Sesh doesn't have.",
            discussion: "Hosts sharing a HostName across users come in as one host with profiles. Nothing is removed or renamed.")
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Client.send(.importConfig, as: ActionResult.self) }) { $0.message }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print Sesh's managed file, or your ssh config.")
        @Flag(help: "Print your ssh config instead.") var sshConfig = false
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command: ControlCommand = sshConfig ? .readConfig : .readManagedFile
            try output.emit({ try Client.send(command, as: TextResult.self) }) { $0.text }
        }
    }

    struct SetPath: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Tell Sesh where your ssh config is.")
        @Argument(help: "Path to it, inside ~/.ssh, e.g. ~/.ssh/config.") var path: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.setConfigPath(absolutePath(path))
            try output.emit({ try Client.send(command, as: ConfigStatusInfo.self) }, human: ConfigText.status)
        }
    }

    struct SetManagedPath: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move Sesh's managed file. It's written at the new path and the Include points there.")
        @Argument(help: "Path for it, inside ~/.ssh and without spaces, e.g. ~/.ssh/sesh.conf. An existing file there must be Sesh's own.") var path: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.setManagedPath(absolutePath(path))
            try output.emit({ try Client.send(command, as: ConfigStatusInfo.self) }, human: ConfigText.status)
        }
    }
}

enum ConfigText {
    static func status(_ status: ConfigStatusInfo) -> String {
        Fields.render([
            ("SSH config", status.configPath ?? "\(ConfigPathStore.defaultSuggestion) (not chosen yet)"),
            ("Managed file", status.managedPath),
            ("Linked", status.isLinked ? "yes; connections use ssh <alias>" : "no; run: sesh config link"),
        ])
    }
}

struct Settings: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show and change Sesh's settings.",
        subcommands: [Show.self, SetTerminal.self, SetAppearance.self, Reset.self, InstallCommand.self])

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the current settings.")
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Client.send(.showSettings, as: SettingsInfo.self) }, human: SettingsText.render)
        }
    }

    struct SetTerminal: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Choose the terminal app connections open in.")
        @Argument(help: "Its name or bundle id (see: sesh terminals).") var terminal: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.setTerminal(terminal)
            try output.emit({ try Client.send(command, as: SettingsInfo.self) }) { "Connections open in \($0.terminal.name)." }
        }
    }

    struct SetAppearance: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set the app's appearance.")
        @Argument(help: "system, light, or dark.") var appearance: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.setAppearance(appearance.lowercased())
            try output.emit({ try Client.send(command, as: SettingsInfo.self) }) { "Appearance: \($0.appearance)." }
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reset the terminal choice, appearance, and managed-file path to their defaults.",
            discussion: "The ssh config path is kept, so the Include line keeps working.")
        @Flag(help: "Don't ask first.") var yes = false
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let yes = yes
            try output.emit({
                try Confirm.check("Reset Sesh's settings to their defaults?", yes: yes)
                return try Client.send(.resetSettings, as: SettingsInfo.self)
            }) { "Settings reset.\n\n" + SettingsText.render($0) }
        }
    }

    struct InstallCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install-command",
            abstract: "Put `sesh` on your PATH, as a link to this copy inside Sesh.app.",
            discussion: """
            Links <dir>/sesh to the sesh inside Sesh.app, so it updates with the app. \
            /usr/local/bin usually needs sudo:

              sudo /Applications/Sesh.app/Contents/Helpers/sesh settings install-command

            Or link it somewhere you own that's on your PATH, with --dir.
            """)
        @Option(help: "Directory to link it in.") var dir = "/usr/local/bin"
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let dir = absolutePath(dir)
            try output.emit({ () -> [String: String] in
                guard let app = AppBundle.enclosing else {
                    throw CLIError.invalid("This sesh isn't inside Sesh.app, so there's nothing stable to link to.")
                }
                let target = app.appending(path: "Contents/Helpers/sesh").path
                let link = (dir as NSString).appendingPathComponent("sesh")
                try install(link: link, target: target, dir: dir)
                return ["link": link, "target": target]
            }) { "Linked \($0["link"]!) → \($0["target"]!)" }
        }

        private func install(link: String, target: String, dir: String) throws {
            let files = FileManager.default
            if let existing = try? files.destinationOfSymbolicLink(atPath: link) {
                if existing == target { return }
                try? files.removeItem(atPath: link)   // an older link, e.g. to a moved Sesh.app
            } else if files.fileExists(atPath: link) {
                throw CLIError.invalid("\(link) exists and isn't a link; move it out of the way first.")
            }
            do {
                try files.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try files.createSymbolicLink(atPath: link, withDestinationPath: target)
            } catch {
                throw CLIError.failed("Couldn't link \(link): \(error.localizedDescription). Try it with sudo, or pick a directory you own with --dir.")
            }
        }
    }
}

enum SettingsText {
    static func render(_ settings: SettingsInfo) -> String {
        Fields.render([
            ("Terminal", "\(settings.terminal.name) (\(settings.terminal.id))"),
            ("Appearance", settings.appearance),
            ("SSH config", settings.config.configPath ?? "\(ConfigPathStore.defaultSuggestion) (not chosen yet)"),
            ("Managed file", settings.config.managedPath),
        ])
    }
}
