import SwiftUI
import SSHConfigCore

struct SyncSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var renameTarget: Conflict?
    @State private var newName = ""
    @State private var keepBoth = false
    @State private var renameError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Results").font(.title2.bold())

            if let items = model.syncItems {
                if items.isEmpty {
                    Text("Everything is already in sync.").foregroundStyle(.secondary)
                } else {
                    List(items) { item in
                        Label(item.host, systemImage: icon(item.action))
                            .badge(label(item.action))
                    }
                    .frame(minHeight: 120)
                }
            }

            if !model.conflicts.isEmpty {
                Text("Conflicts").font(.headline)
                List(model.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(conflict.host).font(.body.monospaced().bold())
                            Text(sourceLabel(conflict.source))
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        diffText(conflict)
                        HStack {
                            if conflict.fileProperties != nil {
                                Button("Use File Version") { acceptFile(conflict) }
                            }
                            if conflict.source != .file {
                                Button("Rename…") {
                                    renameTarget = conflict
                                    newName = conflict.host
                                    keepBoth = false
                                    renameError = nil
                                }
                            }
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 160)
                Text("Store-only hosts are written to the file on the next Sync To File / Sync Both.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.return).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .sheet(item: $renameTarget) { conflict in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename '\(conflict.host)'").font(.headline)
                TextField("New host name", text: $newName)
                Toggle("Keep both (duplicate under the new name)", isOn: $keepBoth)
                if let renameError {
                    Text(renameError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { renameTarget = nil }
                    Button("Rename") {
                        let trimmed = newName.trimmingCharacters(in: .whitespaces)
                        do {
                            try model.resolver.rename(host: conflict.host, to: trimmed,
                                                       updateExisting: !keepBoth, context: context)
                            model.autoSyncToFile()
                            model.refreshConflicts()
                            renameError = nil
                            renameTarget = nil
                        } catch {
                            renameError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    private func acceptFile(_ conflict: Conflict) {
        try? model.resolver.acceptFileVersion(conflict, context: context)
        model.autoSyncToFile()
        model.refreshConflicts()
    }

    private func icon(_ action: SyncAction) -> String {
        switch action {
        case .created: "plus.circle"
        case .updated: "arrow.triangle.2.circlepath"
        case .addedToFile: "arrow.up.doc"
        }
    }

    private func label(_ action: SyncAction) -> String {
        switch action {
        case .created: "added to store"
        case .updated: "updated from file"
        case .addedToFile: "written to file"
        }
    }

    private func sourceLabel(_ source: Conflict.Source) -> String {
        switch source {
        case .both: "differs"
        case .store: "store only"
        case .file: "file only"
        }
    }

    @ViewBuilder
    private func diffText(_ conflict: Conflict) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let file = conflict.fileProperties {
                Text("file:  " + summary(file)).font(.caption.monospaced())
            }
            if let store = conflict.storeProperties {
                Text("store: " + summary(store)).font(.caption.monospaced())
            }
        }
        .foregroundStyle(.secondary)
    }

    private func summary(_ props: [SSHProperty]) -> String {
        props.map { "\($0.key)=\($0.values.joined(separator: ","))" }.joined(separator: " ")
    }
}
