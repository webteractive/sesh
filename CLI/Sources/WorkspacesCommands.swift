import ArgumentParser
import Foundation
import SSHConfigCore

struct Workspaces: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Organize hosts into workspaces, the sidebar's collapsible groups.",
        discussion: "Workspaces live only in Sesh; nothing about them is written to your ssh config.",
        subcommands: [List.self, Create.self, Rename.self, Delete.self, Move.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List workspaces in sidebar order.")
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Client.send(.listWorkspaces, as: [WorkspaceInfo].self) }) { workspaces in
                workspaces.isEmpty
                    ? "No workspaces. Every host is in Default. Create one with: sesh workspaces create <name>"
                    : WorkspaceText.table(workspaces) + jsonHint("sesh workspaces list")
            }
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a workspace at the end of the sidebar.")
        @Argument(help: "Its name.") var name: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.createWorkspace(name: name), name = name
            try output.emit({ try Client.send(command, as: [WorkspaceInfo].self) }) { _ in
                "Created \(name). Move hosts into it with: sesh hosts move <host> --workspace \"\(name)\""
            }
        }
    }

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a workspace.")
        @Argument(help: "The workspace.") var workspace: String
        @Argument(help: "Its new name.") var name: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.renameWorkspace(ref: workspace, name: name), name = name
            try output.emit({ try Client.send(command, as: [WorkspaceInfo].self) }) { _ in "Renamed to \(name)." }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a workspace. Its hosts move to Default; none are deleted.")
        @Argument(help: "The workspace.") var workspace: String
        @Flag(help: "Don't ask first.") var yes = false
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let ref = workspace, yes = yes
            try output.emit({
                try Confirm.check("Delete the workspace \(ref)? Its hosts move to Default.", yes: yes)
                return try Client.send(.deleteWorkspace(ref: ref), as: ActionResult.self)
            }) { $0.message }
        }
    }

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a workspace's place in the sidebar.")
        @Argument(help: "The workspace.") var workspace: String
        @Flag(help: "One place up.") var up = false
        @Flag(help: "One place down.") var down = false
        @Option(help: "Into this workspace's place.") var onto: String?
        @OptionGroup var output: OutputOptions

        func validate() throws {
            if [up, down, onto != nil].filter({ $0 }).count != 1 {
                throw ValidationError("Pass one of --up, --down, or --onto <workspace>.")
            }
        }

        mutating func run() throws {
            let placement: WorkspacePlacement = up ? .up : down ? .down : .onto(onto ?? "")
            let command = ControlCommand.moveWorkspace(ref: workspace, placement: placement)
            try output.emit({ try Client.send(command, as: [WorkspaceInfo].self) }, human: WorkspaceText.table)
        }
    }
}

enum WorkspaceText {
    static func table(_ workspaces: [WorkspaceInfo]) -> String {
        Table.render(["#", "NAME", "HOSTS"], workspaces.map { ["\($0.position)", $0.name, "\($0.hostCount)"] })
    }
}
