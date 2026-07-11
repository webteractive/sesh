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
    @Environment(\.modelContext) private var context

    let mode: FormMode
    @State private var form = HostFormData()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isCreate ? "New Host" : "Edit Host")
                .font(.title2.bold())
                .padding()

            Form {
                TextField("Host", text: $form.host, prompt: Text("myserver"))
                TextField("HostName", text: $form.hostName, prompt: Text("example.com"))
                TextField("User", text: $form.user, prompt: Text("root"))
                TextField("Port", text: $form.port, prompt: Text("22"))
                TextField("IdentityFile", text: $form.identityFile, prompt: Text("~/.ssh/id_ed25519"))

                Section("Other Options") {
                    ForEach(form.extras.indices, id: \.self) { i in
                        HStack {
                            TextField("Option", text: $form.extras[i].key, prompt: Text("ProxyJump"))
                                .frame(width: 160)
                            TextField("Value", text: valueBinding(i), prompt: Text("bastion"))
                            Button(role: .destructive) {
                                form.extras.remove(at: i)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        form.extras.append(SSHProperty(key: "", values: [""]))
                    } label: {
                        Label("Add Option", systemImage: "plus.circle")
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
                Button("Save") { save() }.keyboardShortcut(.return).buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear {
            if case .edit(let entry) = mode { form = HostFormData(entry: entry) }
        }
    }

    private var isCreate: Bool { if case .create = mode { true } else { false } }

    private func valueBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { form.extras[i].values.first ?? "" },
            set: { form.extras[i].values = [$0] }
        )
    }

    private func save() {
        let others = (try? context.fetch(FetchDescriptor<HostEntry>())) ?? []
        var existingHosts = Set(others.map(\.host))
        if case .edit(let entry) = mode { existingHosts.remove(entry.host) }

        if let message = form.validationError(existingHosts: existingHosts) {
            error = message
            return
        }
        let host = form.host.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .create:
            context.insert(HostEntry(host: host, properties: form.properties(), rawBlock: nil))
        case .edit(let entry):
            entry.host = host
            entry.properties = form.properties()
            entry.updatedAt = .now
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            self.error = error.localizedDescription
            return
        }
        model.exportNow()
        dismiss()
    }
}
