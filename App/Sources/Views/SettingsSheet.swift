import SwiftUI
import SSHConfigCore

/// Lets the user revisit the SSH config path after first run. Pattern-matches
/// FirstRunSheet but, unlike that mandatory onboarding sheet, allows interactive
/// dismissal and offers an explicit Cancel.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path = ConfigPathStore.defaultSuggestion
    @State private var error: String?
    @State private var managedPathDraft = ""
    @State private var managedPathError: String?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Label("Settings", systemImage: "gearshape")
                .font(.title2.bold())
            Text("The SSH config path tells Sesh where your ~/.ssh/config lives, for linking and importing.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Config path", text: $path, prompt: Text("~/.ssh/config"))
                .font(.body.monospaced())

            TextField("Managed file path", text: $managedPathDraft, prompt: Text("~/.ssh/sesh.conf"))
                .font(.body.monospaced())
                .onSubmit { commitManagedPath() }

            if let managedPathError {
                Text(managedPathError).foregroundStyle(.red).font(.callout)
            }

            includeStatusRow

            HStack {
                Button("Import from ~/.ssh/config") {
                    let result = model.importFromConfig()
                    if model.pendingError == nil {
                        model.pendingError = "Imported \(result.added) host\(result.added == 1 ? "" : "s") (\(result.skipped) already present)."
                    }
                }
                Spacer()
            }

            if model.selectableTerminals.isEmpty {
                Text("No supported terminal detected — Connect uses the system default.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Connect with", selection: Binding(
                    get: { model.preferredTerminal.id },
                    set: { model.preferredTerminalId = $0 }
                )) {
                    ForEach(model.selectableTerminals) { terminal in
                        Text(terminal.name).tag(terminal.id)
                    }
                }
                .pickerStyle(.menu)
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") {
                    if let message = model.saveConfigPath(path) {
                        error = message
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            path = model.configPath ?? ConfigPathStore.defaultSuggestion
            managedPathDraft = model.managedPath
            model.refreshTerminals()
        }
    }

    /// Commits the managed-path draft on submit: trims, rejects empty, and
    /// rejects a value that would alias the real config path (which would
    /// let export overwrite ~/.ssh/config instead of the managed fragment).
    private func commitManagedPath() {
        let trimmed = managedPathDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            managedPathError = "Managed file path is required."
            return
        }
        let expandedManaged = (trimmed as NSString).expandingTildeInPath
        let expandedConfig = (path as NSString).expandingTildeInPath
        guard expandedManaged != expandedConfig else {
            managedPathError = "Managed file path can't be your main ~/.ssh/config."
            return
        }
        managedPathError = nil
        model.managedPath = trimmed
        managedPathDraft = trimmed
    }

    @ViewBuilder
    private var includeStatusRow: some View {
        if model.managedFileActive {
            Label("Linked into ~/.ssh/config ✓", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            HStack {
                Button("Link into ~/.ssh/config") {
                    if let message = model.linkInclude() {
                        error = message
                    }
                }
                Spacer()
            }
        }
    }
}
