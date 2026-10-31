import ArgumentParser
import Foundation
import SSHConfigCore

struct HostsFileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hosts-file",
        abstract: "Manage /etc/hosts entries in Sesh's section of the file.",
        discussion: """
        Sesh owns one marked section at the end of /etc/hosts and leaves the rest alone. \
        Changes ask for your administrator password in a macOS dialog (macOS remembers it \
        for a few minutes). Enabling an entry turns off any other Sesh entry for the same \
        hostname.

        Name an entry by its id (or its first 4+ characters) or by a hostname it maps.
        """,
        subcommands: [List.self, Show.self, Add.self, AddText.self, Edit.self, Enable.self, Disable.self,
                      Duplicate.self, Delete.self, Status.self, Reapply.self, Import.self, Raw.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List Sesh's entries in file order.")
        @Option(help: "Only entries whose IP, hostname, or note contains this text.") var search: String?
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let search = search?.lowercased()
            try output.emit({
                try Client.send(.listHostsEntries, as: [HostsEntryInfo].self).filter { entry in
                    guard let search else { return true }
                    return ([entry.ip, entry.note ?? ""] + entry.hostnames).contains { $0.lowercased().contains(search) }
                }
            }) { entries in
                guard !entries.isEmpty else {
                    return search == nil
                        ? "No hosts-file entries yet. Add one with: sesh hosts-file add <ip> <hostname>\nOr move your existing lines into Sesh with: sesh hosts-file import"
                        : "No entries match."
                }
                return HostsEntryText.table(entries) + jsonHint("sesh hosts-file list")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one entry.")
        @Argument(help: "Entry id or hostname.") var entry: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.showHostsEntry(ref: entry)
            try output.emit({ try Client.send(command, as: HostsEntryInfo.self) }, human: HostsEntryText.detail)
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add an entry mapping hostnames to an IP.")
        @Argument(help: "IPv4 or IPv6 address.") var ip: String
        @Argument(help: "One or more hostnames.") var hostnames: [String]
        @Option(help: "A note, written as a trailing # comment.") var note: String?
        @Flag(help: "Add it switched off (written commented out).") var disabled = false
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.addHostsEntry(ip: ip, hostnames: hostnames, note: note, enabled: !disabled)
            try output.emit({ try Client.send(command, as: HostsEntryInfo.self) }) {
                "Added \($0.hostnames.joined(separator: ", ")) → \($0.ip) (\(ControlRefs.shortID($0.id)))\($0.isEnabled ? "" : ", disabled")."
            }
        }
    }

    struct AddText: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add several entries from /etc/hosts-style text, one write and one password prompt.",
            discussion: """
            Each line is IP hostname… [# note]; a commented-out line (# IP hostname…) is added \
            switched off. Reads the file given, or standard input:

              printf '10.0.0.5 api.test\\n10.0.0.6 web.test\\n' | sesh hosts-file add-text

            A line Sesh already has isn't duplicated, and a new line takes its hostnames over \
            from any clashing Sesh entry. Nothing is added if any line can't be read.
            """)
        @Argument(help: "File to read; - or nothing reads standard input.") var file: String?
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let file = file
            try output.emit({
                let text: String
                if let file, file != "-" {
                    guard let data = FileManager.default.contents(atPath: file) else {
                        throw CLIError.notFound("Couldn't read \(file).")
                    }
                    text = String(decoding: data, as: UTF8.self)
                } else {
                    text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                }
                return try Client.send(.addHostsText(text: text), as: ActionResult.self)
            }) { $0.message }
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change an entry's IP, hostnames, or note.")
        @Argument(help: "Entry id or hostname.") var entry: String
        @Option(help: "New IP address.") var ip: String?
        @Option(name: .customLong("hostname"), help: "Replace the hostnames. Repeatable.") var hostnames: [String] = []
        @Option(help: "New note; \"\" removes it.") var note: String?
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let changes = HostsEntryChanges(ip: ip, hostnames: hostnames.isEmpty ? nil : hostnames, note: note)
            let command = ControlCommand.editHostsEntry(ref: entry, changes: changes)
            try output.emit({ try Client.send(command, as: HostsEntryInfo.self) }, human: HostsEntryText.detail)
        }
    }

    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Switch entries on, in one write. Other Sesh entries for the same hostnames switch off.")
        @Argument(help: "Entry ids or hostnames.") var entries: [String]
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.setHostsEntries(refs: entries, enabled: true)
            try output.emit({ try Client.send(command, as: [HostsEntryInfo].self) }, human: HostsEntryText.table)
        }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Switch entries off (written commented out).")
        @Argument(help: "Entry ids or hostnames.") var entries: [String]
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.setHostsEntries(refs: entries, enabled: false)
            try output.emit({ try Client.send(command, as: [HostsEntryInfo].self) }, human: HostsEntryText.table)
        }
    }

    struct Duplicate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy an entry, switched off, to the end of the section.")
        @Argument(help: "Entry id or hostname.") var entry: String
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let command = ControlCommand.duplicateHostsEntry(ref: entry)
            try output.emit({ try Client.send(command, as: HostsEntryInfo.self) }) {
                "Copied as \(ControlRefs.shortID($0.id)), disabled."
            }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete entries.")
        @Argument(help: "Entry ids or hostnames.") var entries: [String]
        @Flag(help: "Don't ask first.") var yes = false
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            let refs = entries, yes = yes
            try output.emit({
                try Confirm.check("Delete \(plural(refs.count, "hosts-file entry", "hosts-file entries"))?", yes: yes)
                return try Client.send(.deleteHostsEntries(refs: refs), as: ActionResult.self)
            }) { $0.message }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check that /etc/hosts still matches Sesh, and which entries are overridden.")
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Client.send(.hostsFileStatus, as: HostsFileStatusInfo.self) }) { status in
                var text = hostsFileSummary(status)
                if !status.overridden.isEmpty {
                    text += "\n\nOverridden by an earlier line outside Sesh's section:\n" + HostsEntryText.table(status.overridden)
                }
                return text
            }
        }
    }

    struct Reapply: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rewrite Sesh's section from its entries, after something else changed it.")
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Client.send(.reapplyHostsFile, as: HostsFileStatusInfo.self) }) {
                "Rewrote Sesh's section. " + hostsFileSummary($0)
            }
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move your existing /etc/hosts lines into Sesh's section.",
            discussion: """
            Backs the file up to ~/Library/Application Support/Sesh/hosts-backups first. System \
            entries and Docker Desktop's and SwitchHosts' sections are left alone, and no \
            hostname changes what it resolves to.
            """)
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Client.send(.importHostsFile, as: ActionResult.self) }) { $0.message }
        }
    }

    struct Raw: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the whole /etc/hosts file.")
        @OptionGroup var output: OutputOptions

        mutating func run() throws {
            try output.emit({ try Client.send(.readHostsFile, as: TextResult.self) }) { $0.text }
        }
    }
}

enum HostsEntryText {
    static func table(_ entries: [HostsEntryInfo]) -> String {
        let rows = entries.map { entry -> [String] in
            var state = entry.isEnabled ? "on" : "off"
            if entry.isOverridden { state += " (overridden)" }
            return [ControlRefs.shortID(entry.id), state, entry.ip, entry.hostnames.joined(separator: " "), entry.note ?? ""]
        }
        return Table.render(["ID", "STATE", "IP", "HOSTNAMES", "NOTE"], rows)
    }

    static func detail(_ entry: HostsEntryInfo) -> String {
        Fields.render([
            ("ID", entry.id.uuidString.lowercased()),
            ("IP", entry.ip),
            ("Hostnames", entry.hostnames.joined(separator: " ")),
            ("Note", entry.note),
            ("State", entry.isEnabled ? (entry.isOverridden ? "on, but overridden by an earlier line outside Sesh's section" : "on") : "off"),
            ("Position", "\(entry.position)"),
        ])
    }
}
