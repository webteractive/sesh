import SwiftUI
import SwiftData
import SSHConfigCore

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HostEntry.updatedAt, order: .reverse) private var hosts: [HostEntry]

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private static let recentLimit = 10
    private static let rowHeight: CGFloat = 44

    /// Empty query → the 10 most-recently-updated hosts (quick access).
    /// A query → fuzzy search across all hosts.
    private var filtered: [HostEntry] {
        guard !query.isEmpty else {
            return Array(hosts.prefix(Self.recentLimit))
        }
        return hosts
            .compactMap { entry -> (HostEntry, Int)? in
                let target = entry.host + " " + (entry.properties.first("HostName") ?? "")
                guard let score = FuzzyMatcher.score(query, in: target) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// `filtered` grouped for display — a multi-profile host collapses to one
    /// row with a profile chooser instead of one row per alias.
    private var groups: [HostGroupView] {
        model.groups(from: filtered)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search hosts…", text: $query)
                .textFieldStyle(.plain)
                .padding(10)
                .focused($searchFocused)
            Divider()

            if hosts.isEmpty {
                Text("No hosts yet")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else if groups.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            groupRow(group, selected: index == selectedIndex)
                        }
                    }
                }
                // A window-style MenuBarExtra self-sizes to its content, and a
                // ScrollView's ideal height is ~0 — so it MUST get a definite
                // height or the list collapses and renders blank. Show up to
                // ~8 rows, then scroll.
                .frame(height: CGFloat(min(groups.count, 8)) * Self.rowHeight)
            }

            Divider()
            footer
        }
        .frame(width: 300)
        .onAppear {
            query = ""
            selectedIndex = 0
            // The window panel isn't key the instant it appears; focusing on the
            // next runloop tick makes the search field reliably accept typing.
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, max(0, groups.count - 1)); return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0); return .handled
        }
        .onKeyPress(.return) {
            activateSelected(); return .handled
        }
        .onKeyPress(.escape) {
            dismiss(); return .handled
        }
    }

    private func activateSelected() {
        guard groups.indices.contains(selectedIndex) else { return }
        let member = groups[selectedIndex].defaultMember
        guard let entry = model.entry(forAlias: member.alias, in: hosts) else { return }
        // Enter opens in the terminal when possible; wildcard/pattern hosts
        // (no single connectable alias) fall back to copying the command.
        if member.isConnectable {
            model.connect(entry)
        } else {
            model.copyCommand(entry)
        }
    }

    @ViewBuilder
    private func groupRow(_ group: HostGroupView, selected: Bool) -> some View {
        let defaultEntry = model.entry(forAlias: group.defaultMember.alias, in: hosts)
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                if let defaultEntry {
                    Text(subtitle(defaultEntry)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if group.isMultiProfile {
                Menu {
                    ForEach(group.members) { member in
                        if let memberEntry = model.entry(forAlias: member.alias, in: hosts) {
                            Button("Connect as \(member.label)") {
                                model.connect(memberEntry)
                            }
                            Button("Copy \(member.label)") {
                                model.copyCommand(memberEntry)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "person.2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose a profile")
            } else if let defaultEntry {
                Button {
                    model.copyCommand(defaultEntry)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy \(defaultEntry.sshCommand)")
            }

            if group.defaultMember.isConnectable, let defaultEntry {
                Button {
                    model.connect(defaultEntry)
                } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(.borderless)
                .help("Open in \(model.preferredTerminal.name)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear)
    }

    private var footer: some View {
        HStack {
            Button("Export") { model.exportNow() }
                .help("Re-write the managed config file from the store")
            Spacer()
            Button("Open Sesh") { openMainWindow() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(10)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func subtitle(_ entry: HostEntry) -> String {
        let hostName = entry.properties.first("HostName") ?? "—"
        if let user = entry.properties.first("User") { return "\(user)@\(hostName)" }
        return hostName
    }
}
