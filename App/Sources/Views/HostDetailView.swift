import SwiftUI
import SwiftData
import SSHConfigCore

struct HostDetailView: View {
    @Environment(AppModel.self) private var model
    @Query private var hosts: [HostEntry]
    let entry: HostEntry
    var onEdit: (HostEntry) -> Void = { _ in }
    var onAddProfile: (HostEntry) -> Void = { _ in }
    var onRemoveProfile: (HostEntry, [HostEntry]) -> Void = { _, _ in }

    /// The entry's group (nil when it isn't part of one). Looked up fresh from
    /// `hosts` each render so profile add/remove is reflected immediately.
    private var group: HostGroupView? {
        guard entry.groupName != nil else { return nil }
        return model.groups(from: hosts).first { $0.id == entry.groupName }
    }

    private var groupMembers: [HostEntry] {
        guard let group else { return [] }
        return group.members.compactMap { model.entry(forAlias: $0.alias, in: hosts) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.host).font(.largeTitle.bold())

                if let group {
                    GroupBox("Profiles") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(group.members) { member in
                                profileRow(member)
                                if member.id != group.members.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Connection") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        row("HostName", entry.properties.first("HostName"))
                        row("User", entry.properties.first("User"))
                        row("Port", entry.port)
                        row("IdentityFile", entry.properties.first("IdentityFile"))
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                let extras = entry.properties.filter { !HostFormData.coreKeys.contains($0.key.lowercased()) }
                if !extras.isEmpty {
                    GroupBox("Other Options") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                            ForEach(extras, id: \.key) { prop in
                                row(prop.key, prop.values.joined(separator: ", "))
                            }
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        model.copyCommand(entry)
                    } label: {
                        Label(entry.sshCommand, systemImage: "doc.on.doc").font(.body.monospaced())
                    }
                    .help("Copy the ssh command")

                    Button {
                        onEdit(entry)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Button {
                        onAddProfile(entry)
                    } label: {
                        Label("Add Profile…", systemImage: "plus.circle")
                    }

                    if entry.isConnectable {
                        Menu {
                            ForEach(model.selectableTerminals) { terminal in
                                Button("Connect with \(terminal.name)") {
                                    model.connect(entry, with: terminal)
                                }
                            }
                        } label: {
                            Label("Connect · \(model.preferredTerminal.name)", systemImage: "terminal")
                        } primaryAction: {
                            model.connect(entry)
                        }
                        .fixedSize()
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }

                if let raw = entry.rawBlock, !raw.isEmpty {
                    GroupBox("Raw Block (as last imported)") {
                        Text(raw)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
                Spacer()
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "—").textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func profileRow(_ member: ProfileRef) -> some View {
        let memberEntry = model.entry(forAlias: member.alias, in: hosts)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.label).font(.headline)
                    if member.isDefault {
                        Text("default").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(member.user.map { "\($0)@\(memberEntry?.properties.first("HostName") ?? "—")" }
                     ?? member.alias).font(.caption).foregroundStyle(.secondary)
                if let identity = member.identityFile, !identity.isEmpty {
                    Text(identity).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if member.isConnectable, let memberEntry {
                Menu {
                    ForEach(model.selectableTerminals) { terminal in
                        Button("Connect with \(terminal.name)") {
                            model.connect(memberEntry, with: terminal)
                        }
                    }
                } label: {
                    Label("Connect", systemImage: "terminal")
                } primaryAction: {
                    model.connect(memberEntry)
                }
                .fixedSize()
            }
            Button(role: .destructive) {
                if let memberEntry {
                    onRemoveProfile(memberEntry, groupMembers)
                }
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help("Remove this profile")
        }
    }
}
