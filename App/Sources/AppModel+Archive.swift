import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers
import SSHConfigCore

/// What an export or import covers: SSH hosts and /etc/hosts entries each
/// have their own sheets and files.
enum ArchiveKind: Identifiable, Equatable {
    case sshHosts
    case hostsFile

    var id: Self { self }

    /// "SSH Hosts" / "Hosts File", for titles and file names.
    var title: String {
        switch self {
        case .sshHosts: "SSH Hosts"
        case .hostsFile: "Hosts File"
        }
    }

    /// This kind's part of `archive`.
    func part(of archive: SeshArchive) -> SeshArchive {
        var part = archive
        switch self {
        case .sshHosts: part.hostsEntries = []
        case .hostsFile: part.sshHosts = []
        }
        return part
    }

    func isEmpty(in archive: SeshArchive) -> Bool {
        switch self {
        case .sshHosts: archive.sshHosts.isEmpty
        case .hostsFile: archive.hostsEntries.isEmpty
        }
    }
}

enum ArchiveRequest: Equatable {
    case export(ArchiveKind)
    case importFile(ArchiveKind)
}

/// Export to, and import from, a Sesh JSON file (`SeshArchive`), SSH hosts
/// and hosts-file entries separately. The sheets list the items with ticks
/// and hand back only the ticked ones.
extension AppModel {
    struct ArchiveError: Error {
        let message: String
    }

    /// Everything in the store, as the export sheet offers it.
    func currentArchive() -> SeshArchive {
        let hosts = (try? context.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let workspaceNames = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
        return SeshArchive(
            sshHosts: hosts.map {
                SeshArchive.SSHHost(alias: $0.host, properties: $0.properties, displayName: $0.displayName,
                                    groupName: $0.groupName, isDefaultProfile: $0.isDefaultProfile,
                                    workspace: $0.workspaceID.flatMap { workspaceNames[$0] })
            },
            hostsEntries: hostsEntries.map { SeshArchive.HostsEntry($0.line) })
    }

    /// Hosts in ~/.ssh/config that Sesh doesn't have, grouped the way
    /// Import from ~/.ssh/config groups them, for export to offer beside
    /// `archive`'s. A group whose key would merge it into one of `archive`'s
    /// logical hosts is left out.
    func configOnlyHosts(besides archive: SeshArchive) -> [SeshArchive.SSHHost] {
        let aliases = Set(archive.sshHosts.map(\.alias))
        let keys = Set(archive.sshHosts.map(\.groupKey))
        let path = configPath ?? ConfigPathStore.defaultSuggestion
        return ConfigImporter().groups(inConfigAt: path).flatMap { group -> [SeshArchive.SSHHost] in
            let hosts = group.members.filter { !aliases.contains($0.alias) }.enumerated().map { index, member in
                SeshArchive.SSHHost(alias: member.alias, properties: member.properties,
                                    displayName: group.displayName, groupName: group.groupName,
                                    isDefaultProfile: group.groupName != nil && index == 0)
            }
            guard let first = hosts.first, !keys.contains(first.groupKey) else { return [] }
            return hosts
        }
    }

    /// Asks where to save `archive` and writes it there, owner-only since it
    /// names servers, users, and key paths. False when the panel is cancelled.
    func saveArchive(_ archive: SeshArchive, kind: ArchiveKind) throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Sesh \(kind.title) \(Date.now.formatted(.iso8601.year().month().day())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try SSHConfigWriter().writeData(archive.encoded(), toPath: url.path)
        return true
    }

    /// Asks for an export file and reads its `kind` part; nil when the panel
    /// is cancelled. A file with none of `kind` is reported as an error.
    func openArchive(_ kind: ArchiveKind) throws -> SeshArchive? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let archive = kind.part(of: try SeshArchive.decode(Data(contentsOf: url)))
            guard !kind.isEmpty(in: archive) else {
                throw ArchiveError(message: kind == .sshHosts
                    ? "\(url.lastPathComponent) has no SSH hosts."
                    : "\(url.lastPathComponent) has no hosts-file entries.")
            }
            return archive
        } catch SeshArchiveError.unreadable {
            throw ArchiveError(message: "\(url.lastPathComponent) isn't a Sesh export.")
        } catch SeshArchiveError.newerVersion {
            throw ArchiveError(message: "\(url.lastPathComponent) was exported by a newer Sesh. Update Sesh, then import it again.")
        } catch SeshArchiveError.invalid(let reason) {
            throw ArchiveError(message: "\(url.lastPathComponent) wasn't imported: \(reason)")
        }
    }

    /// Host aliases in ~/.ssh/config, lowercased, so import can flag a host
    /// that would replace one of them.
    var configAliases: Set<String> {
        let path = configPath ?? ConfigPathStore.defaultSuggestion
        return Set(ConfigImporter().groups(inConfigAt: path).flatMap { $0.members.map { $0.alias.lowercased() } })
    }

    /// Store aliases, for the import sheet to mark hosts already present.
    var sshAliases: Set<String> {
        Set(((try? context.fetch(FetchDescriptor<HostEntry>())) ?? []).map(\.host))
    }

    /// Group keys of `archive`'s logical hosts an import would skip as
    /// already in Sesh — the same test `importArchive` applies.
    func presentSSHGroups(in archive: SeshArchive) -> Set<String> {
        let all = (try? context.fetch(FetchDescriptor<HostEntry>())) ?? []
        let aliases = Set(all.map(\.host)), groups = Set(all.compactMap(\.groupName))
        return Set(archive.sshGroups
            .filter { SeshArchive.isPresent($0, existingAliases: aliases, existingGroups: groups) }
            .map { $0[0].groupKey })
    }

    /// Mapping keys of the store's hosts entries (see `HostsLine.mappingKey`).
    var hostsMappingKeys: Set<String> {
        Set(hostsEntries.map(\.line.mappingKey))
    }

    /// Imports the (already ticked-down) `archive`: hosts entries first, as
    /// one /etc/hosts write merged like bulk add, so a cancelled password
    /// prompt stops the import before anything changes; then the SSH hosts,
    /// skipping aliases already present and creating missing workspaces by
    /// name. Returns a summary for the alert.
    func importArchive(_ archive: SeshArchive) -> Result<String, ArchiveError> {
        var hostsAdded = 0, skipped = 0
        let lines = archive.hostsEntries.map(\.line)
        if !lines.isEmpty {
            let preview = previewHostsMerge(lines)
            if let message = addHostsEntries(lines) { return .failure(ArchiveError(message: message)) }
            hostsAdded = preview.added.count
            skipped += preview.skipped
        }

        let all = (try? context.fetch(FetchDescriptor<HostEntry>())) ?? []
        let plan = SeshArchive.planSSHImport(archive.sshHosts, existingAliases: Set(all.map(\.host)),
                                             existingGroups: Set(all.compactMap(\.groupName)))
        skipped += plan.skipped
        if !plan.added.isEmpty {
            var workspaceIDs: [String: UUID] = [:]
            var nextOrder = (workspaces.map(\.sortOrder).max() ?? -1) + 1
            for ws in workspaces where workspaceIDs[ws.name.lowercased()] == nil {
                workspaceIDs[ws.name.lowercased()] = ws.id
            }
            for host in plan.added {
                let entry = HostEntry(host: host.alias, properties: host.properties, rawBlock: nil)
                entry.displayName = host.displayName
                entry.groupName = host.groupName
                entry.isDefaultProfile = host.isDefaultProfile
                if let name = host.workspace?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    if let id = workspaceIDs[name.lowercased()] {
                        entry.workspaceID = id
                    } else {
                        let ws = Workspace(name: name, sortOrder: nextOrder)
                        nextOrder += 1
                        context.insert(ws)
                        workspaceIDs[name.lowercased()] = ws.id
                        entry.workspaceID = ws.id
                    }
                }
                context.insert(entry)
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                let wrote = hostsAdded > 0 ? " The /etc/hosts entries were imported." : ""
                return .failure(ArchiveError(message: "SSH hosts weren't imported: \(error.localizedDescription).\(wrote)"))
            }
            exportNow()
        }

        var parts: [String] = []
        if !archive.sshHosts.isEmpty {
            parts.append("\(plan.added.count) SSH host\(plan.added.count == 1 ? "" : "s")")
        }
        if !lines.isEmpty {
            parts.append("\(hostsAdded) hosts-file entr\(hostsAdded == 1 ? "y" : "ies")")
        }
        return .success("Imported \(parts.joined(separator: " and ")) (\(skipped) already present).")
    }
}
