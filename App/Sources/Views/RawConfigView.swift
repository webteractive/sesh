import SwiftUI

struct RawConfigView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.managedPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    text = managedConfigText()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                Text(text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear { text = managedConfigText() }
    }

    /// Reads the managed sesh.conf fragment directly — this is Sesh's own
    /// rendered output, not the user's real ~/.ssh/config.
    private func managedConfigText() -> String {
        let expanded = (model.managedPath as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return "No managed config yet."
        }
        return text
    }
}
