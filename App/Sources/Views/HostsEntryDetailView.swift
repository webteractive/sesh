import SwiftUI
import SSHConfigCore

struct HostsEntryDetailView: View {
    @Environment(AppModel.self) private var model
    let entry: HostsFileEntry
    var onEdit: (HostsFileEntry) -> Void = { _ in }
    var onDelete: (HostsFileEntry) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.hostnames.first ?? entry.ip).font(.largeTitle.bold())
                    Spacer()
                    HostsEntryToggle(entry: entry)
                        .controlSize(.regular)
                }

                if model.isOverridden(entry) {
                    Label("Another line outside Sesh's section of /etc/hosts sets one of these hostnames, and it usually wins.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        row("IP Address", entry.ip)
                        row("Hostnames", entry.hostnames.joined(separator: " "))
                        row("Note", entry.note)
                        row("Status", entry.isEnabled ? "Enabled" : "Disabled")
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Line in /etc/hosts") {
                    Text(entry.line.rendered)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button {
                        onEdit(entry)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete(entry)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

                Spacer()
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "—").textSelection(.enabled)
        }
    }
}
