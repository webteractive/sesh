import AppKit
import SwiftUI
import SwiftData
import SSHConfigCore

enum FormMode: Identifiable {
    case create
    case edit(HostEntry)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let entry): "edit-\(entry.host)"
        }
    }
}

struct HostFormSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query private var hosts: [HostEntry]

    let mode: FormMode
    @State private var form = HostFormModel(displayName: "", hostName: "", rows: [CredentialRow(user: "")])
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isCreate ? "New Host" : "Edit Host")
                .font(.title2.bold())
                .padding()

            Form {
                Section {
                    TextField("Name", text: $form.displayName, prompt: Text("My Server"))
                    TextField("Host (ip or domain)", text: $form.hostName, prompt: Text("example.com"))
                    if model.isWorkspaceMode {
                        Picker("Workspace", selection: $form.workspaceID) {
                            Text("Default").tag(UUID?.none)
                            ForEach(model.workspaces, id: \.id) { ws in
                                Text(ws.name).tag(UUID?.some(ws.id))
                            }
                        }
                    }
                }

                Section("Credentials") {
                    ForEach(form.rows.indices, id: \.self) { i in
                        credentialRow(i)
                    }
                    Button {
                        form.rows.append(CredentialRow(user: ""))
                    } label: {
                        Label("Add Credential", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
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
                    .disabled(form.validationError() != nil)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onAppear {
            if case .edit(let entry) = mode {
                form = HostFormModel(editing: entry, allHosts: hosts)
            }
        }
    }

    private var isCreate: Bool { if case .create = mode { true } else { false } }

    @ViewBuilder
    private func credentialRow(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("User", text: $form.rows[i].user, prompt: Text("root"))
                TextField("Port", text: $form.rows[i].port, prompt: Text("22"))
                    .frame(width: 80)
                Button(role: .destructive) {
                    form.rows.remove(at: i)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(form.rows.count <= 1)
            }
            HStack {
                TextField("SSH Key", text: $form.rows[i].identityFile, prompt: Text("~/.ssh/id_ed25519"))
                Button("Choose…") { chooseIdentityFile(for: i) }
            }
        }
        .padding(.vertical, 4)
    }

    private func chooseIdentityFile(for index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        form.rows[index].identityFile = url.path
    }

    private func save() {
        let groupID: String? = {
            if case .edit(let entry) = mode { return entry.groupName ?? entry.host }
            return nil
        }()
        if let message = model.saveHostForm(form, editingGroup: groupID) {
            error = message
        } else {
            dismiss()
        }
    }
}
