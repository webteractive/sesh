import SwiftUI
import SSHConfigCore

/// Read-only view of the whole /etc/hosts file, with Sesh's section
/// highlighted so it's clear which lines Sesh owns.
struct HostsFileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var content = AttributedString()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("/etc/hosts").font(.title2.bold())
                Spacer()
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding()

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(content)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

            Divider()

            HStack {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                Text("Sesh's section").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 540)
        .onAppear { reload() }
    }

    private func reload() {
        model.refreshHostsFileState()
        guard let text = try? model.hostsWriter.read() else {
            content = AttributedString("Couldn't read /etc/hosts.")
            return
        }
        content = Self.highlighted(text)
    }

    /// The file as one attributed string (so selection spans lines), with the
    /// lines from Sesh's start marker through its end marker in the accent color.
    private static func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        var inSection = false
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == HostsFile.startMarker { inSection = true }
            var piece = AttributedString(line + (index < lines.count - 1 ? "\n" : ""))
            if inSection { piece.foregroundColor = .accentColor }
            result += piece
            if trimmed == HostsFile.endMarker { inSection = false }
        }
        return result
    }
}
