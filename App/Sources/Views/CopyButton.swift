import SwiftUI

/// An icon-only copy button that gives a brief "Copied!" confirmation: the
/// clipboard glyph swaps to a green checkmark and the tooltip changes for a
/// moment after each tap.
struct CopyButton: View {
    /// Tooltip shown in the idle state (e.g. "Copy the ssh command").
    let help: String
    let action: () -> Void

    @State private var copied = false

    var body: some View {
        Button {
            action()
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeInOut(duration: 0.15)) { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : "Copy",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.primary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .help(copied ? "Copied!" : help)
    }
}
