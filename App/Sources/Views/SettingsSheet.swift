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

            TextField("Managed file path", text: $model.managedPath, prompt: Text("~/.ssh/sesh.conf"))
                .font(.body.monospaced())

            includeStatusRow

            HStack {
                Button("Import from ~/.ssh/config") {
                    let result = model.importFromConfig()
                    model.pendingError = "Imported \(result.added) host\(result.added == 1 ? "" : "s") (\(result.skipped) already present)."
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
            model.refreshTerminals()
        }
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
