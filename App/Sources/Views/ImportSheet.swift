import SwiftUI
import SSHConfigCore

/// An export file read for import, presented as a sheet item.
struct PendingImport: Identifiable {
    let id = UUID()
    let kind: ArchiveKind
    /// Only the file's `kind` items.
    let archive: SeshArchive
}

/// Picks which SSH hosts, or which /etc/hosts entries, of an export file to
/// import. Items already in Sesh are listed but can't be ticked; SSH hosts
/// worth a look first (`SeshArchive.risks`) start unticked.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let kind: ArchiveKind
    let archive: SeshArchive
    @State private var selection = ArchiveSelection()
    @State private var sshNotes: [String: ArchiveItemNote] = [:]
    @State private var hostsNotes: [Int: ArchiveItemNote] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import \(kind.title)")
                .font(.title2.bold())
                .padding([.horizontal, .top])
            Text(footnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()

            ArchiveChecklist(archive: archive, selection: $selection, sshNotes: sshNotes, hostsNotes: hostsNotes,
                             workspaceOrder: model.workspaces.map(\.name))

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding([.horizontal, .top])
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Button(selection.count == 1 ? "Import 1 Item" : "Import \(selection.count) Items") { runImport() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.count == 0)
            }
            .padding()
        }
        .frame(width: 540, height: 520)
        .onAppear(perform: classify)
    }

    private var footnote: String {
        switch kind {
        case .sshHosts: "Tick what to bring in. SSH hosts whose alias Sesh already has are skipped."
        case .hostsFile: "Tick what to bring in. The entries are written in one go, after one administrator password prompt."
        }
    }

    /// Marks what's already in Sesh or worth a look, and ticks the rest.
    private func classify() {
        let present = model.presentSSHGroups(in: archive)
        let configAliases = model.configAliases
        for group in archive.sshGroups {
            let key = group[0].groupKey
            let risks = SeshArchive.risks(of: group, configAliases: configAliases)
            if present.contains(key) {
                sshNotes[key] = .unavailable("Already in Sesh")
            } else if !risks.isEmpty {
                sshNotes[key] = .warning("Risky: " + risks.joined(separator: "; "))
            } else {
                selection.sshGroups.insert(key)
            }
        }
        let mappings = model.hostsMappingKeys
        for (index, entry) in archive.hostsEntries.enumerated() {
            if mappings.contains(entry.line.mappingKey) {
                hostsNotes[index] = .unavailable("Already in Sesh")
            } else {
                selection.hostsEntries.insert(index)
            }
        }
    }

    private func runImport() {
        switch model.importArchive(selection.apply(to: archive)) {
        case .success(let summary):
            dismiss()
            // Keep a warning the import left (e.g. sesh.conf couldn't be written).
            model.pendingError = [summary, model.pendingError].compactMap { $0 }.joined(separator: "\n\n")
        case .failure(let failure):
            error = failure.message
        }
    }
}
