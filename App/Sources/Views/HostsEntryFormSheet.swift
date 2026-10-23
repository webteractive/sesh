import SwiftUI
import SSHConfigCore

enum HostsFormMode: Identifiable {
    case create
    case edit(HostsFileEntry)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let entry): "edit-\(entry.id)"
        }
    }
}

/// New/Edit form for one /etc/hosts entry. Saving writes /etc/hosts, so the
/// macOS administrator prompt appears; a cancelled prompt keeps the sheet open.
struct HostsEntryFormSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: HostsFormMode
    @State private var ip = ""
    @State private var hostnames = ""
    @State private var note = ""
    @State private var isEnabled = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isCreate ? "New Hosts Entry" : "Edit Hosts Entry")
                .font(.title2.bold())
                .padding()

            Form {
                Section {
                    TextField("IP Address", text: $ip, prompt: Text("127.0.0.1"))
                    TextField("Hostnames", text: $hostnames, prompt: Text("myapp.localhost www.myapp.localhost"))
                    TextField("Note", text: $note, prompt: Text("Optional"))
                    Toggle("Enabled", isOn: $isEnabled)
                } footer: {
                    Text("Separate several hostnames with spaces or commas. Saving asks for your administrator password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(ip.trimmingCharacters(in: .whitespaces).isEmpty || parsedHostnames.isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 360)
        .onAppear {
            if case .edit(let entry) = mode {
                ip = entry.ip
                hostnames = entry.hostnames.joined(separator: " ")
                note = entry.note ?? ""
                isEnabled = entry.isEnabled
            }
        }
    }

    private var isCreate: Bool { if case .create = mode { true } else { false } }

    private var parsedHostnames: [String] {
        hostnames.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
    }

    private func save() {
        let existing: HostsFileEntry? = if case .edit(let entry) = mode { entry } else { nil }
        if let message = model.saveHostsEntry(existing, ip: ip, hostnames: parsedHostnames,
                                              note: note, isEnabled: isEnabled) {
            error = message
        } else {
            dismiss()
        }
    }
}
