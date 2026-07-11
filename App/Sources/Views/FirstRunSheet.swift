import SwiftUI
import SSHConfigCore

struct FirstRunSheet: View {
    @Environment(AppModel.self) private var model
    @State private var path = ConfigPathStore.defaultSuggestion
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    if let message = model.saveConfigPath(path) {
                        error = message
                        return
                    }
                    if let message = model.linkInclude() {
                        model.pendingError = message
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
