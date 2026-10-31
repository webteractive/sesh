import SwiftUI
import SSHConfigCore

/// The ticked items of a `SeshArchive`: logical SSH hosts by group key,
/// hosts entries by index.
struct ArchiveSelection: Equatable {
    var sshGroups: Set<String> = []
    var hostsEntries: Set<Int> = []

    var count: Int { sshGroups.count + hostsEntries.count }

    func apply(to archive: SeshArchive) -> SeshArchive {
        archive.selecting(sshGroups: sshGroups, hostsEntries: hostsEntries)
    }
}

/// Why an item is shown differently in the checklist.
enum ArchiveItemNote: Equatable {
    /// Listed, but can't be ticked (already in Sesh, or can't be exported).
    case unavailable(String)
    /// Something to weigh before ticking it.
    case warning(String)

    var isUnavailable: Bool {
        if case .unavailable = self { true } else { false }
    }
}

/// Export's and import's list of items, one checkbox each, with a
/// tick-all checkbox per section. SSH hosts are grouped by workspace, like
/// the sidebar, each group with its own tick-all checkbox.
struct ArchiveChecklist: View {
    let archive: SeshArchive
    @Binding var selection: ArchiveSelection
    var sshNotes: [String: ArchiveItemNote] = [:]
    var hostsNotes: [Int: ArchiveItemNote] = [:]
    /// Sesh's workspace names in sidebar order.
    var workspaceOrder: [String] = []
    /// Group keys of hosts only in ~/.ssh/config, grouped on their own last.
    var configOnlyKeys: Set<String> = []

    @State private var collapsed: Set<String> = []

    private struct SSHSection: Identifiable {
        let id: String
        let title: String
        let groups: [[SeshArchive.SSHHost]]
    }

    var body: some View {
        List {
            let groups = archive.sshGroups
            if !groups.isEmpty {
                let sections = sshSections
                Section {
                    // With no workspaces and nothing from ~/.ssh/config there's
                    // only Default, so the hosts are listed without a group.
                    if sections.count == 1, sections[0].id == "default" {
                        ForEach(groups, id: \.[0].groupKey) { group in
                            sshRow(group)
                        }
                    } else {
                        ForEach(sections) { section in
                            DisclosureGroup(isExpanded: .init(
                                get: { !collapsed.contains(section.id) },
                                set: { if $0 { collapsed.remove(section.id) } else { collapsed.insert(section.id) } }
                            )) {
                                ForEach(section.groups, id: \.[0].groupKey) { group in
                                    sshRow(group)
                                }
                            } label: {
                                header(section.title, ticked: $selection.sshGroups, of: selectable(section.groups))
                            }
                        }
                    }
                } header: {
                    header("SSH Hosts", ticked: $selection.sshGroups, of: selectable(groups))
                }
            }
            if !archive.hostsEntries.isEmpty {
                let indices = archive.hostsEntries.indices.filter { hostsNotes[$0]?.isUnavailable != true }
                Section {
                    ForEach(archive.hostsEntries.indices, id: \.self) { index in
                        hostsRow(index)
                    }
                } header: {
                    header("Hosts File", ticked: $selection.hostsEntries, of: Set(indices))
                }
            }
        }
    }

    /// The archive's hosts by workspace, then the config-only ones.
    private var sshSections: [SSHSection] {
        var inSesh = archive
        inSesh.sshHosts.removeAll { configOnlyKeys.contains($0.groupKey) }
        var sections = inSesh.sshSections(workspaceOrder: workspaceOrder).map {
            SSHSection(id: $0.workspace.map { "workspace:" + $0.lowercased() } ?? "default",
                       title: $0.workspace ?? "Default", groups: $0.groups)
        }
        let configOnly = archive.sshGroups.filter { configOnlyKeys.contains($0[0].groupKey) }
        if !configOnly.isEmpty {
            sections.append(SSHSection(id: "config-only", title: "Only in ~/.ssh/config", groups: configOnly))
        }
        return sections
    }

    private func selectable(_ groups: [[SeshArchive.SSHHost]]) -> Set<String> {
        Set(groups.map { $0[0].groupKey }.filter { sshNotes[$0]?.isUnavailable != true })
    }

    /// A tick-all checkbox for `all`, showing a dash when only some are
    /// ticked. It changes only `all`, so a workspace's checkbox leaves the
    /// other workspaces' ticks alone.
    private func header<ID: Hashable>(_ title: String, ticked: Binding<Set<ID>>, of all: Set<ID>) -> some View {
        let items = all.map { id in
            Binding(get: { ticked.wrappedValue.contains(id) },
                    set: { if $0 { ticked.wrappedValue.insert(id) } else { ticked.wrappedValue.remove(id) } })
        }
        return HStack {
            Toggle(title, sources: items, isOn: \.self)
                .toggleStyle(.checkbox)
                .disabled(all.isEmpty)
            Spacer()
            Text("\(ticked.wrappedValue.intersection(all).count) of \(all.count)")
                .foregroundStyle(.secondary)
        }
    }

    private func sshRow(_ group: [SeshArchive.SSHHost]) -> some View {
        let lead = group.first(where: \.isDefaultProfile) ?? group[0]
        var details = [lead.properties.first("HostName") ?? lead.alias]
        if group.count > 1 { details.append("\(group.count) profiles") }
        return row(title: lead.displayName ?? lead.groupKey, subtitle: details.joined(separator: " · "),
                   note: sshNotes[lead.groupKey], ticked: $selection.sshGroups, id: lead.groupKey)
    }

    private func hostsRow(_ index: Int) -> some View {
        let entry = archive.hostsEntries[index]
        var details = [entry.ip]
        if !entry.isEnabled { details.append("disabled") }
        if let note = entry.note { details.append(note) }
        return row(title: entry.hostnames.joined(separator: ", "), subtitle: details.joined(separator: " · "),
                   note: hostsNotes[index], ticked: $selection.hostsEntries, id: index)
    }

    private func row<ID: Hashable>(title: String, subtitle: String, note: ArchiveItemNote?,
                                   ticked: Binding<Set<ID>>, id: ID) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: .init(
                get: { ticked.wrappedValue.contains(id) },
                set: { if $0 { ticked.wrappedValue.insert(id) } else { ticked.wrappedValue.remove(id) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(note?.isUnavailable == true)
            Spacer()
            switch note {
            case .unavailable(let message):
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(message)
            case .warning(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
        }
    }
}
