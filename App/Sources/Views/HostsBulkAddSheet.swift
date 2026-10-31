import SwiftUI
import SSHConfigCore

/// Adds several /etc/hosts entries at once from pasted lines in hosts-file
/// form, listing each parsed entry with an Enabled switch. The switch
/// comments its line out or back in, so the text stays the only state.
/// Everything lands in one write, so one administrator prompt covers them
/// all; a cancelled prompt keeps the sheet open with the text intact.
struct HostsBulkAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var error: String?

    var body: some View {
        let parsed = HostsFile.parseBulk(text)
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Hosts Entries")
                .font(.title2.bold())
                .padding()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("127.0.0.1 myapp.localhost\n10.0.0.5 api.test www.api.test # staging")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 140)
                .padding(.horizontal)

            if parsed.lines.isEmpty {
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(Array(zip(parsed.lineNumbers, parsed.lines)), id: \.0) { number, line in
                        row(line, number: number)
                    }
                }
                .padding(.top, 8)
            }

            summary(parsed)
                .font(.caption)
                .padding(.horizontal)
                .padding(.top, 8)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding([.horizontal, .top])
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Button(addTitle(parsed.lines.count)) { add(parsed.lines) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(parsed.lines.isEmpty || !parsed.invalid.isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 520)
    }

    private func row(_ line: HostsLine, number: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.hostnames.joined(separator: ", "))
                Text([line.ip, line.note].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(line.isEnabled ? 1 : 0.5)
            Spacer()
            Toggle("Enabled", isOn: .init(
                get: { line.isEnabled },
                set: { text = HostsFile.settingBulkLine(number, enabled: $0, in: text) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(line.isEnabled ? "Add this entry turned off" : "Add this entry turned on")
        }
    }

    @ViewBuilder
    private func summary(_ parsed: HostsBulkParse) -> some View {
        if let bad = parsed.invalid.first {
            let more = parsed.invalid.count - 1
            Text("Line \(bad.number) isn't an IP followed by hostnames: \(bad.text)"
                 + (more > 0 ? " (and \(more) more)" : ""))
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if parsed.lines.isEmpty {
            Text("One entry per line, an IP then its hostnames, as in /etc/hosts. Switch an entry off below (or start its line with #) to add it disabled. Adding asks for your administrator password once.")
                .foregroundStyle(.secondary)
        } else {
            let merge = model.previewHostsMerge(parsed.lines)
            Text(mergeSummary(merge)).foregroundStyle(.secondary)
        }
    }

    private func mergeSummary(_ merge: HostsImportMerge<UUID>) -> String {
        var parts = ["\(merge.added.count) new \(merge.added.count == 1 ? "entry" : "entries")"]
        if merge.skipped > 0 { parts.append("\(merge.skipped) already in Sesh") }
        if !merge.disable.isEmpty {
            parts.append("turns off \(merge.disable.count) clashing \(merge.disable.count == 1 ? "entry" : "entries")")
        }
        return parts.joined(separator: " · ")
    }

    private func addTitle(_ count: Int) -> String {
        count > 1 ? "Add \(count) Entries" : "Add Entry"
    }

    private func add(_ lines: [HostsLine]) {
        if let message = model.addHostsEntries(lines) {
            error = message
        } else {
            dismiss()
        }
    }
}
