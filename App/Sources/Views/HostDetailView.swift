import SwiftUI
import SwiftData
import SSHConfigCore

struct HostDetailView: View {
    @Environment(AppModel.self) private var model
    @Query private var hosts: [HostEntry]
    let entry: HostEntry
    var onEdit: (HostEntry) -> Void = { _ in }
    var onRemoveProfile: (HostEntry, [HostEntry]) -> Void = { _, _ in }
    var onDelete: (HostEntry) -> Void = { _ in }

    /// The entry's group, whether it's a real multi-profile group or the
    /// singleton bucket `HostGrouping` synthesizes for an ungrouped host.
    /// Looked up fresh from `hosts` each render so profile add/remove is
    /// reflected immediately.
    private var group: HostGroupView? {
        model.groups(from: hosts).first { $0.members.contains { $0.alias == entry.host } }
    }

    private var groupMembers: [HostEntry] {
        guard let group else { return [] }
        return group.members.compactMap { model.entry(forAlias: $0.alias, in: hosts) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.displayName ?? entry.host).font(.largeTitle.bold())

                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        row("HostName", entry.properties.first("HostName"))
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                GroupBox("Credentials") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(group?.members ?? []) { member in
                            profileRow(member)
                            if member.id != group?.members.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button {
                        onEdit(entry)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete(entry)
                    } label: {
                        Label("Delete", systemImage: "trash")
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
                Text("Port \(memberEntry?.port ?? "22")").font(.caption).foregroundStyle(.secondary)
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
            if let memberEntry {
                Button {
                    model.copyCommand(memberEntry)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Copy the ssh command")
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
