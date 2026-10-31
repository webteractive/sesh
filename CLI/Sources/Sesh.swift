import ArgumentParser
import Foundation

@main
struct Sesh: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sesh",
        abstract: "Drive Sesh from the terminal: SSH hosts, /etc/hosts entries, export and import, settings.",
        discussion: """
        sesh talks to the Sesh app, starting it in the background if it isn't running, so \
        every change goes through the app and shows up in its window straight away. Changes \
        to /etc/hosts ask for your administrator password in a macOS dialog.

        Name a host by its alias, its profile group, or its display name; a workspace by \
        name; a hosts-file entry by its id (or the first 4+ characters of it) or a hostname \
        it maps.

        For scripts and agents, add --json to any command: results print as JSON on stdout, \
        and so do errors, as {"error": {"code": …, "message": …}}. Warnings, such as a change \
        saved but not written to ~/.ssh/sesh.conf, go to stderr and leave the exit code at 0.

        Exit codes:
          0  success
          1  failed
          2  invalid input; nothing was changed
          3  not found
          4  ambiguous: the name matches more than one thing
          5  conflict: already exists
          6  cancelled: a password prompt or confirmation was declined
          7  Sesh isn't running and couldn't be started
          8  this sesh and the running Sesh are different versions
          9  confirmation required: pass --yes
          64 usage error
        """,
        version: "sesh \(AppBundle.versionLine)",
        subcommands: [
            Status.self, Connect.self,
            Hosts.self, Profiles.self, Workspaces.self, HostsFileCommand.self,
            Export.self, Import.self,
            Config.self, Settings.self, Terminals.self, Update.self,
            Version.self,
        ]
    )

    /// Answers `-v` beside the generated `--version`.
    @Flag(name: .customShort("v"), help: "Show the version.")
    var shortVersion = false

    mutating func run() throws {
        if shortVersion {
            print("sesh \(AppBundle.versionLine)")
            return
        }
        print(Sesh.helpMessage())
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the version of sesh and the Sesh.app it came in.")

    @OptionGroup var output: OutputOptions

    mutating func run() throws {
        if output.json {
            print(OutputOptions.encode(["version": AppBundle.versionLine, "appPath": AppBundle.enclosing?.path]))
        } else {
            print("sesh \(AppBundle.versionLine)")
        }
    }
}
