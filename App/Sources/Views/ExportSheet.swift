import SwiftUI
import SSHConfigCore

/// Picks which SSH hosts, or which /etc/hosts entries, go into an export
/// file. SSH hosts only in ~/.ssh/config are offered too, unticked; a host
/// Import would refuse is listed but can't be ticked.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let kind: ArchiveKind
    @State private var archive = SeshArchive(sshHosts: [], hostsEntries: [])
    @State private var selection = ArchiveSelection()
    @State private var sshNotes: [String: ArchiveItemNote] = [:]
    @State private var configOnlyKeys: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export \(kind.title)")
                .font(.title2.bold())
                .padding([.horizontal, .top])
            Text(kind == .sshHosts
                 ? "Tick what goes into the file. It holds host settings and identity file paths, not keys."
                 : "Tick the entries that go into the file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()

            if kind.isEmpty(in: archive) {
                ContentUnavailableView("Nothing to Export", systemImage: "tray",
                                       description: Text(kind == .sshHosts ? "Add SSH hosts first."
                                                                           : "Add hosts-file entries first."))
            } else {
                ArchiveChecklist(archive: archive, selection: $selection, sshNotes: sshNotes,
                                 workspaceOrder: model.workspaces.map(\.name), configOnlyKeys: configOnlyKeys)
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding([.horizontal, .top])
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Button(selection.count == 1 ? "Export 1 Item…" : "Export \(selection.count) Items…") { export() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.count == 0)
            }
            .padding()
        }
        .frame(width: 540, height: 520)
        .onAppear(perform: load)
    }

    /// Lists the store's items of `kind` (SSH hosts followed by config-only
    /// ones) and ticks those that can travel.
    private func load() {
        let stored = kind.part(of: model.currentArchive())
        let configOnly = kind == .sshHosts ? model.configOnlyHosts(besides: stored) : []
        archive = stored
        archive.sshHosts += configOnly
        selection.hostsEntries = Set(archive.hostsEntries.indices)
        configOnlyKeys = Set(configOnly.map(\.groupKey))
        for group in archive.sshGroups {
            let key = group[0].groupKey
            if let problem = group.lazy.compactMap(\.problem).first {
                sshNotes[key] = .unavailable(problem)
            } else if !configOnlyKeys.contains(key) {
                selection.sshGroups.insert(key)
            }
        }
    }

    private func export() {
        do {
            if try model.saveArchive(selection.apply(to: archive), kind: kind) { dismiss() }
        } catch {
            self.error = "Couldn't save the export: \(error.localizedDescription)"
        }
    }
}
