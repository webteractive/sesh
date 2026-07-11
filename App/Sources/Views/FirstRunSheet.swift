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
            Text("Setting your SSH config path is required to use this app. It tells Sesh where your configuration file lives. If the file exists it will be backed up and imported.")
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
                    error = model.saveConfigPath(path)
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
