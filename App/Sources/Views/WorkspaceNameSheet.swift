import SwiftUI
import SSHConfigCore

enum WorkspaceSheetMode {
    case create
    case rename(Workspace)
}

/// Create/rename sheet for a `Workspace`. Save calls the matching AppModel
/// mutator, shows the returned error inline, and dismisses on success (nil).
struct WorkspaceNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: WorkspaceSheetMode
    /// Fired with the newly created workspace right before dismissing, so a
    /// caller (e.g. "Move to Workspace → New Workspace…") can chain a move.
    var onSaved: ((Workspace) -> Void)? = nil

    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isCreate ? "New Workspace" : "Rename Workspace")
                .font(.title2.bold())
                .padding()

            Form {
                TextField("Name", text: $name, prompt: Text("Production"))
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 360, height: 160)
        .onAppear {
            if case .rename(let ws) = mode {
                name = ws.name
            }
        }
    }

    private var isCreate: Bool { if case .create = mode { true } else { false } }

    private func save() {
        switch mode {
        case .create:
            if let message = model.createWorkspace(name: name) {
                error = message
            } else {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if let created = model.workspaces.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    onSaved?(created)
                }
                dismiss()
            }
        case .rename(let ws):
            if let message = model.renameWorkspace(ws, to: name) {
                error = message
            } else {
                dismiss()
            }
        }
    }
}
