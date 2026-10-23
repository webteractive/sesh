import SwiftUI
import SwiftData
import SSHConfigCore

/// The main window's sidebar in Hosts File mode: search, add/delete, the
/// out-of-sync banner, and one row per entry with an enable toggle.
struct HostsFileList: View {
    @Environment(AppModel.self) private var model
    @Query(sort: HostsFileEntry.blockOrder)
    private var entries: [HostsFileEntry]

    @Binding var selection: Set<UUID>
    @Binding var search: String
    var searchFocused: FocusState<Bool>.Binding
    var onNew: () -> Void
    var onEdit: (HostsFileEntry) -> Void
    var onDelete: (Set<UUID>) -> Void

    private var filtered: [HostsFileEntry] { entries.filter { $0.matches(search) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search hosts file", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused(searchFocused)
                Button { onNew() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Hosts Entry")
                Button(role: .destructive) {
                    onDelete(selection)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(selection.isEmpty)
                .help("Delete selected entry")
            }
            .padding(8)

            if model.hostsOutOfSync {
                HostsOutOfSyncBanner()
            }

            List(selection: $selection) {
                ForEach(filtered) { entry in
                    row(entry)
                        .tag(entry.id)
                        .contextMenu {
                            Button("Edit") { onEdit(entry) }
                            Button("Duplicate") { model.duplicateHostsEntry(entry) }
                            Divider()
                            Button("Delete", role: .destructive) { onDelete([entry.id]) }
                        }
                }
            }
            .onDeleteCommand { onDelete(selection) }
        }
    }

    private func row(_ entry: HostsFileEntry) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.hostnames.joined(separator: ", ")).font(.headline)
                Text(entry.ip).font(.caption).foregroundStyle(.secondary)
            }
            .opacity(entry.isEnabled ? 1 : 0.5)
            Spacer(minLength: 0)
            if model.isOverridden(entry) {
                HostsOverrideIcon()
            }
            HostsEntryToggle(entry: entry)
        }
    }
}

/// The per-entry on/off switch shared by the window and the menu bar. It
/// reads the stored state, so a cancelled password prompt snaps it back.
struct HostsEntryToggle: View {
    @Environment(AppModel.self) private var model
    let entry: HostsFileEntry

    var body: some View {
        // Reading `hostsRevision` ties this view to failed/cancelled writes:
        // the bump forces a re-render so the switch shows the stored state
        // again instead of the position the user flipped it to.
        let _ = model.hostsRevision
        Toggle("Enabled", isOn: Binding(
            get: { entry.isEnabled },
            set: { model.setHostsEntry(entry, enabled: $0) }
        ))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .help(entry.isEnabled ? "Disable in /etc/hosts" : "Enable in /etc/hosts")
    }
}

struct HostsOverrideIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .help("Also set outside Sesh's section in /etc/hosts — may be overridden")
    }
}

/// Shown when Sesh's block in /etc/hosts no longer matches the store. Sesh
/// never rewrites the file on its own; Re-apply is the user's call.
struct HostsOutOfSyncBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            Text("/etc/hosts is out of sync")
            Spacer(minLength: 0)
            Button("Re-apply") { model.reapplyHostsFile() }
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }
}

extension HostsFileEntry {
    /// Case-insensitive search across hostnames, IP, and note; empty matches all.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return ([ip, note ?? ""] + hostnames).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
