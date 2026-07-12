import SwiftUI
import SSHConfigCore

/// Grouped settings for the SSH config paths, the Connect terminal, appearance,
/// and app info. Interactive-dismissable (unlike the mandatory FirstRunSheet)
/// with explicit Cancel/Save.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var path = ConfigPathStore.defaultSuggestion
    @State private var error: String?
    @State private var managedPathDraft = ""
    @State private var managedPathError: String?
    @State private var showResetConfirm = false
    @State private var selectedTab = "general"

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title2.bold())
                .padding()

            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag("general")
                sshConfigTab
                    .tabItem { Label("SSH Config", systemImage: "doc.plaintext") }
                    .tag("ssh")
                aboutTab
                    .tabItem { Label("About", systemImage: "info.circle") }
                    .tag("about")
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onAppear {
            path = model.configPath ?? ConfigPathStore.defaultSuggestion
            managedPathDraft = model.managedPath
            model.refreshTerminals()
            if let tab = model.pendingSettingsTab {
                selectedTab = tab
                model.pendingSettingsTab = nil
            }
        }
        .confirmationDialog("Reset all preferences?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                model.resetPreferences()
                managedPathDraft = model.managedPath
                managedPathError = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The terminal choice, appearance, last selection, and managed-file path return to defaults.")
        }
    }

    private var generalTab: some View {
        Form {
            Section("Connect") {
                if model.selectableTerminals.isEmpty {
                    Text("No supported terminal detected — Connect uses the system default.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Open connections in", selection: Binding(
                        get: { model.preferredTerminal.id },
                        set: { model.preferredTerminalId = $0 }
                    )) {
                        ForEach(model.selectableTerminals) { terminal in
                            Text(terminal.name).tag(terminal.id)
                        }
                    }
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { model.appearancePreference },
                    set: { model.appearancePreference = $0 }
                )) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
    }

    private var sshConfigTab: some View {
        Form {
            Section {
                TextField("Config path", text: $path, prompt: Text("~/.ssh/config"))
                    .font(.body.monospaced())
                TextField("Managed file path", text: $managedPathDraft, prompt: Text("~/.ssh/sesh.conf"))
                    .font(.body.monospaced())
                    .onSubmit { commitManagedPath() }
                if let managedPathError {
                    Text(managedPathError).foregroundStyle(.red).font(.callout)
                }
                includeStatusRow
                Button("Import from ~/.ssh/config") {
                    let result = model.importFromConfig()
                    if model.pendingError == nil {
                        model.pendingError = "Imported \(result.added) host\(result.added == 1 ? "" : "s") (\(result.skipped) already present)."
                    }
                }
            } footer: {
                Text("The config path tells Sesh where your ~/.ssh/config lives, for linking and importing. The managed file holds Sesh's own hosts and is Included from your config.")
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: appVersion)
                Text("Sesh manages your SSH connections from the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                updatesContent
            }

            Section {
                Button("Reset Preferences…", role: .destructive) {
                    showResetConfirm = true
                }
            } footer: {
                Text("Restores the terminal choice, appearance, last selection, and managed-file path to defaults. Your linked config path and hosts are kept.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var updatesContent: some View {
        switch model.updatePhase {
        case .idle:
            Button("Check for Updates") { model.checkForUpdates(explicit: true) }
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate:
            HStack {
                Label("You're up to date.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Spacer()
                Button("Check Again") { model.checkForUpdates(explicit: true) }
            }
        case .available(let update):
            VStack(alignment: .leading, spacing: 8) {
                Text("Version \(update.version) is available.")
                HStack {
                    if update.isInstallable {
                        Button("Install & Restart") { model.installUpdate() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Release Notes") { openURL(update.releasePage) }
                }
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading…").foregroundStyle(.secondary)
                ProgressView(value: fraction)
            }
        case .verifying, .preparing, .relaunching:
            HStack {
                ProgressView().controlSize(.small)
                Text(installStatusText).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.red).font(.callout)
                Button("Try Again") { model.checkForUpdates(explicit: true) }
            }
        }
    }

    private var installStatusText: String {
        switch model.updatePhase {
        case .verifying: "Verifying…"
        case .preparing: "Preparing…"
        case .relaunching: "Restarting…"
        default: ""
        }
    }

    /// Commits the managed path (validating it) then saves the config path,
    /// dismissing only when both succeed. Committing here — not just on the
    /// field's onSubmit — means a typed-but-not-Entered path still saves.
    private func save() {
        commitManagedPath()
        guard managedPathError == nil else { return }
        if let message = model.saveConfigPath(path) {
            error = message
        } else {
            dismiss()
        }
    }

    /// Commits the managed-path draft: trims, rejects empty, and rejects a value
    /// that would alias the real config path (which would let export overwrite
    /// ~/.ssh/config instead of the managed fragment).
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
            Label("Linked into ~/.ssh/config", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            Button("Link into ~/.ssh/config") {
                if let message = model.linkInclude() {
                    error = message
                }
            }
        }
    }
}
