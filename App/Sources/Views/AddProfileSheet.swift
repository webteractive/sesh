import SwiftUI
import SwiftData
import SSHConfigCore

struct AddProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query private var hosts: [HostEntry]

    let base: HostEntry
    @State private var label = ""
    @State private var user = ""
    @State private var identityFile = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Profile to '\(base.host)'").font(.title2.bold())
            Text("Creates a sibling SSH alias sharing this host's connection settings, with its own user and identity.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Label", text: $label, prompt: Text("deploy"))
                TextField("User", text: $user, prompt: Text("deploy"))
                TextField("IdentityFile", text: $identityFile, prompt: Text("~/.ssh/id_deploy"))
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Add") { add() }
                    .keyboardShortcut(.return).buttonStyle(.borderedProminent)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty
                              || user.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }

    private func add() {
        let id = identityFile.trimmingCharacters(in: .whitespaces)
        if let message = model.addProfile(
            to: base,
            label: label.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            identityFile: id.isEmpty ? nil : id,
            allHosts: hosts) {
            error = message
        } else {
            dismiss()
        }
    }
}
