import SwiftUI
import SSHConfigCore

struct FirstRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path = ConfigPathStore.defaultSuggestion
    @State private var error: String?
    /// Flips once the path is saved and Include is linked, revealing the
    /// import offer step below. Kept separate from `model.showFirstRun` so
    /// the sheet stays open long enough to ask about importing.
    @State private var didSaveConfig = false

    private var existingConfigFound: Bool {
        FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if didSaveConfig {
                importOfferSection
            } else {
                pathSetupSection
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var pathSetupSection: some View {
        Label("SSH Config Path", systemImage: "gearshape")
            .font(.title2.bold())
        Text("Setting your ~/.ssh/config path is required to use this app. Sesh links its managed config into it, and can import your existing hosts from it.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        TextField("Config path", text: $path, prompt: Text("~/.ssh/config"))
            .font(.body.monospaced())

        if let error {
            Text(error).foregroundStyle(.red).font(.callout)
        }

        HStack {
            Spacer()
            Button("Save") {
                save()
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
        }
    }

    private func save() {
        if let message = model.saveConfigPath(path) {
            error = message
            return
        }
        if let message = model.linkInclude() {
            model.pendingError = message
        }
        // Only offer to import when there's an existing file to import from;
        // otherwise there's nothing to ask about, so finish first run here.
        guard existingConfigFound else {
            finish()
            return
        }
        didSaveConfig = true
    }

    @ViewBuilder
    private var importOfferSection: some View {
        Label("Import Existing Hosts", systemImage: "square.and.arrow.down")
            .font(.title2.bold())
        Text("We found an existing config at \(path). Import its hosts into Sesh now? You can always import later from the toolbar.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            Button("Skip") {
                finish()
            }
            Spacer()
            Button("Import my existing hosts") {
                importAndFinish()
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
        }
    }

    /// Imports, surfacing the result via the same `pendingError`-as-info
    /// channel the toolbar Import button uses (only set on success — a real
    /// failure already left its own message in `pendingError`), then dismisses.
    private func importAndFinish() {
        let result = model.importFromConfig()
        if model.pendingError == nil {
            model.pendingError = "Imported \(result.added) host\(result.added == 1 ? "" : "s") (\(result.skipped) already present)."
        }
        finish()
    }

    private func finish() {
        model.showFirstRun = false
        dismiss()
    }
}
