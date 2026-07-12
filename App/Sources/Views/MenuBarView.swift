import SwiftUI
import SwiftData
import SSHConfigCore

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HostEntry.updatedAt, order: .reverse) private var hosts: [HostEntry]
    // Not read directly — its presence makes SwiftUI re-render this panel
    // (sections come from `model.sections(from:)`) whenever a workspace is
    // created, renamed, or deleted.
    @Query private var workspaceEntities: [Workspace]

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private static let recentLimit = 10
    private static let rowHeight: CGFloat = 44
    private static let sectionHeaderHeight: CGFloat = 22

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

    /// `filtered`, widened so a query match on one profile of a multi-profile
    /// host pulls in every sibling sharing its `groupName` instead of
    /// rendering that group as a lone orphaned row. An empty query leaves the
    /// recent-10 quick-access list untouched — there's no search match to
    /// widen around.
    private var searchWidenedHosts: [HostEntry] {
        guard !query.isEmpty else { return filtered }
        let matched = filtered
        let matchedGroups = Set(matched.compactMap(\.groupName))
        return hosts.filter { h in
            matched.contains(where: { $0.persistentModelID == h.persistentModelID })
                || (h.groupName.map(matchedGroups.contains) ?? false)
        }
    }

    /// `searchWidenedHosts` grouped for display — a multi-profile host collapses
    /// to one row with a profile chooser instead of one row per alias.
    private var groups: [HostGroupView] {
        model.groups(from: searchWidenedHosts)
    }

    /// Workspace-mode sections over the same widened rows (Default first,
    /// omitted when empty; each workspace always present).
    private var sections: [WorkspaceSection] {
        model.sections(from: searchWidenedHosts)
    }

    /// Sections with at least one row — the ones actually rendered.
    private var nonEmptySections: [WorkspaceSection] {
        sections.filter { !$0.groups.isEmpty }
    }

    /// The single flat top-to-bottom ordering used for keyboard selection and
    /// Return-to-activate, regardless of whether rows are shown sectioned or flat.
    private var displayGroups: [HostGroupView] {
        model.isWorkspaceMode ? nonEmptySections.flatMap(\.groups) : groups
    }

    var body: some View {
        VStack(spacing: 0) {
            if let update = model.availableUpdate {
                Button { openUpdateSettings() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update to \(update.version)")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.15))
                .help("A newer version is available")
                Divider()
            }

            TextField("Search hosts…", text: $query)
                .textFieldStyle(.plain)
                .padding(10)
                .focused($searchFocused)
            Divider()

            if hosts.isEmpty {
                Text("No hosts yet")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else if filtered.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else if model.isWorkspaceMode {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(nonEmptySections) { section in
                            Text(section.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                            ForEach(section.groups) { group in
                                groupRow(group, selected: isSelected(group))
                            }
                        }
                    }
                }
                // See the flat-mode note below on why a definite height is required.
                .frame(height: min(
                    CGFloat(displayGroups.count) * Self.rowHeight + CGFloat(nonEmptySections.count) * Self.sectionHeaderHeight,
                    8 * Self.rowHeight + CGFloat(nonEmptySections.count) * Self.sectionHeaderHeight))
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
            model.applyAppearance()
            query = ""
            selectedIndex = 0
            // The window panel isn't key the instant it appears; focusing on the
            // next runloop tick makes the search field reliably accept typing.
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, max(0, displayGroups.count - 1)); return .handled
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

    /// Whether `group` is the row at `selectedIndex` within `displayGroups`
    /// (the flat top-to-bottom order keyboard navigation walks, sectioned or not).
    private func isSelected(_ group: HostGroupView) -> Bool {
        displayGroups.indices.contains(selectedIndex) && displayGroups[selectedIndex].id == group.id
    }

    private func activateSelected() {
        guard displayGroups.indices.contains(selectedIndex) else { return }
        let member = displayGroups[selectedIndex].defaultMember
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
                            Menu(member.label) {
                                if member.isConnectable {
                                    Button("Connect") { model.connect(memberEntry) }
                                }
                                Button("Copy") { model.copyCommand(memberEntry) }
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
                CopyButton(help: "Copy \(defaultEntry.sshCommand)") {
                    model.copyCommand(defaultEntry)
                }
            }

            if let defaultEntry {
                Button {
                    editInWindow(defaultEntry)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit in Sesh")
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
            Button { openMainWindow() } label: {
                Image(systemName: "macwindow")
            }
            .help("Open Sesh")
            Spacer()
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .help("Quit Sesh")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    /// Opens the main window and asks it (via AppModel) to show Settings.
    private func openSettings() {
        model.pendingShowSettings = true
        openMainWindow()
    }

    /// Opens Settings straight to the About tab, where the update install lives.
    private func openUpdateSettings() {
        model.pendingSettingsTab = "about"
        model.pendingShowSettings = true
        openMainWindow()
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()   // close the menu bar panel once the window is up
    }

    /// Opens the main window and asks it (via AppModel) to select this host and
    /// open its edit form.
    private func editInWindow(_ entry: HostEntry) {
        model.pendingEditAlias = entry.host
        openMainWindow()
    }

    private func subtitle(_ entry: HostEntry) -> String {
        let hostName = entry.properties.first("HostName") ?? "—"
        if let user = entry.properties.first("User") { return "\(user)@\(hostName)" }
        return hostName
    }
}
