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
    @Query(sort: HostsFileEntry.blockOrder)
    private var hostsEntries: [HostsFileEntry]
    @AppStorage("menuBarMode") private var mode: SidebarMode = .ssh

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private static let recentLimit = 10
    private static let rowHeight: CGFloat = 44
    private static let sectionHeaderHeight: CGFloat = 22
    private static let workspaceRowHeight: CGFloat = 32

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
        guard !query.isEmpty else {
            // Browsing workspaces lists *every* host under its workspace — the
            // recent-10 cap only makes sense for the flat quick-access list.
            return model.isWorkspaceMode ? hosts : filtered
        }
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

    /// Workspace browsing: with workspaces defined and nothing typed, the panel
    /// lists workspaces as rows whose submenus hold their hosts. Typing swaps
    /// back to searchable host rows — a submenu you can't type into is no way
    /// to run a search.
    private var isBrowsingWorkspaces: Bool {
        model.isWorkspaceMode && query.isEmpty
    }

    /// The single flat top-to-bottom ordering used for keyboard selection and
    /// Return-to-activate, regardless of whether rows are shown sectioned or
    /// flat. Empty while browsing workspaces — those rows open menus rather
    /// than connecting, so there's nothing for Return to activate.
    private var displayGroups: [HostGroupView] {
        if isBrowsingWorkspaces { return [] }
        return model.isWorkspaceMode ? nonEmptySections.flatMap(\.groups) : groups
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

            Picker("Mode", selection: $mode) {
                Text("SSH").tag(SidebarMode.ssh)
                Text("Hosts").tag(SidebarMode.hosts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 8)

            TextField(mode == .hosts ? "Search hosts file…" : "Search hosts…", text: $query)
                .textFieldStyle(.plain)
                .padding(10)
                .focused($searchFocused)
            Divider()

            if mode == .hosts {
                hostsContent
            } else if hosts.isEmpty {
                Text("No hosts yet")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else if filtered.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else if isBrowsingWorkspaces {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(nonEmptySections) { section in
                            workspaceRow(section)
                        }
                    }
                }
                // See the flat-mode note below on why a definite height is required.
                .frame(height: CGFloat(min(nonEmptySections.count, 8)) * Self.workspaceRowHeight)
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
            model.refreshHostsFileState()
            query = ""
            selectedIndex = 0
            // The window panel isn't key the instant it appears; focusing on the
            // next runloop tick makes the search field reliably accept typing.
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: mode) { _, _ in
            query = ""
            selectedIndex = 0
            model.refreshHostsFileState()
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, max(0, selectableCount - 1)); return .handled
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

    /// Hosts-file entries matching the search, in block order.
    private var filteredHostsEntries: [HostsFileEntry] {
        hostsEntries.filter { $0.matches(query) }
    }

    /// Row count keyboard selection walks in the current mode.
    private var selectableCount: Int {
        mode == .hosts ? filteredHostsEntries.count : displayGroups.count
    }

    /// Whether `group` is the row at `selectedIndex` within `displayGroups`
    /// (the flat top-to-bottom order keyboard navigation walks, sectioned or not).
    private func isSelected(_ group: HostGroupView) -> Bool {
        displayGroups.indices.contains(selectedIndex) && displayGroups[selectedIndex].id == group.id
    }

    private func activateSelected() {
        if mode == .hosts {
            // Return toggles the selected entry.
            let entries = filteredHostsEntries
            guard entries.indices.contains(selectedIndex) else { return }
            let entry = entries[selectedIndex]
            model.setHostsEntry(entry, enabled: !entry.isEnabled)
            return
        }
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

    /// A workspace row: the workspace name and its host count, opening a
    /// submenu of its hosts. Workspaces come in sidebar order (Default first),
    /// hosts within one in the same most-recently-updated order the sidebar uses.
    private func workspaceRow(_ section: WorkspaceSection) -> some View {
        Menu {
            ForEach(section.groups) { group in
                hostMenu(group)
            }
        } label: {
            HStack(spacing: 6) {
                Text(section.title)
                Spacer(minLength: 0)
                Text("\(section.groups.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
        .frame(height: Self.workspaceRowHeight)
    }

    /// One host inside a workspace submenu. A multi-profile host nests a menu
    /// per profile; a single-profile host offers its actions directly.
    @ViewBuilder
    private func hostMenu(_ group: HostGroupView) -> some View {
        let defaultEntry = model.entry(forAlias: group.defaultMember.alias, in: hosts)
        Menu(group.title) {
            if group.isMultiProfile {
                ForEach(group.members) { member in
                    if let memberEntry = model.entry(forAlias: member.alias, in: hosts) {
                        Menu(member.label) {
                            if member.isConnectable {
                                Button("Connect") { model.connect(memberEntry) }
                            }
                            Button("Copy Command") { model.copyCommand(memberEntry) }
                        }
                    }
                }
            } else if let defaultEntry {
                if group.defaultMember.isConnectable {
                    Button("Connect") { model.connect(defaultEntry) }
                }
                Button("Copy Command") { model.copyCommand(defaultEntry) }
            }
            if let defaultEntry {
                Divider()
                Button("Edit in Sesh…") { editInWindow(defaultEntry) }
            }
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

    /// Hosts mode: the out-of-sync banner and one row per entry with its
    /// enable toggle. Adding and editing hand off to the main window.
    @ViewBuilder
    private var hostsContent: some View {
        if model.hostsOutOfSync {
            HostsOutOfSyncBanner()
        }
        if hostsEntries.isEmpty {
            Text("No hosts file entries yet")
                .foregroundStyle(.secondary)
                .padding(.vertical, 16)
        } else if filteredHostsEntries.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .padding(.vertical, 16)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredHostsEntries.enumerated()), id: \.element.id) { index, entry in
                        hostsRow(entry, selected: index == selectedIndex)
                    }
                }
            }
            // See the flat-mode note in `body` on why a definite height is required.
            .frame(height: CGFloat(min(filteredHostsEntries.count, 8)) * Self.rowHeight)
        }
    }

    private func hostsRow(_ entry: HostsFileEntry, selected: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.hostnames.joined(separator: ", ")).lineLimit(1)
                Text(entry.ip).font(.caption).foregroundStyle(.secondary)
            }
            .opacity(entry.isEnabled ? 1 : 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isOverridden(entry) {
                HostsOverrideIcon()
            }

            Button {
                editHostsInWindow(.edit(entry.id))
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit in Sesh")

            HostsEntryToggle(entry: entry)
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
            if mode == .hosts {
                Spacer()
                Button { editHostsInWindow(.create) } label: {
                    Image(systemName: "plus")
                }
                .help("New Hosts Entry")
                Spacer()
                Button {
                    model.pendingShowHostsFile = true
                    openMainWindow()
                } label: {
                    Image(systemName: "doc.plaintext")
                }
                .help("View /etc/hosts")
            }
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

    /// Opens the main window on the hosts-entry form (new or edit).
    private func editHostsInWindow(_ request: HostsEditRequest) {
        model.pendingHostsEdit = request
        openMainWindow()
    }

    private func subtitle(_ entry: HostEntry) -> String {
        let hostName = entry.properties.first("HostName") ?? "—"
        if let user = entry.properties.first("User") { return "\(user)@\(hostName)" }
        return hostName
    }
}
