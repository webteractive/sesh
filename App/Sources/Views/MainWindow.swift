import SwiftUI
import SwiftData
import SSHConfigCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \HostEntry.updatedAt, order: .reverse) private var hosts: [HostEntry]
    // Not read directly — its presence makes SwiftUI re-render the sidebar
    // (sections come from `model.sections(from:)`) whenever a workspace is
    // created, renamed, or deleted.
    @Query private var workspaceEntities: [Workspace]
    @State private var search = ""
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var formMode: FormMode?
    @State private var showSettings = false
    @State private var deleteRequest: HostGroupView?
    @State private var multiDeleteRequest: Set<PersistentIdentifier>?
    @State private var showPalette = false
    @State private var removeProfileRequest: (entry: HostEntry, members: [HostEntry])?
    @State private var showNewWorkspace = false
    @State private var pendingMoveAlias: String?
    @State private var renameWorkspaceTarget: Workspace?
    @State private var deleteWorkspaceTarget: Workspace?
    @State private var expandedSections: [String: Bool] = [:]

    private var filtered: [HostEntry] {
        guard !search.isEmpty else { return hosts }
        return hosts.filter {
            $0.host.localizedCaseInsensitiveContains(search)
                || ($0.displayName ?? "").localizedCaseInsensitiveContains(search)
                || ($0.properties.first("HostName") ?? "").localizedCaseInsensitiveContains(search)
                || ($0.properties.first("User") ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    /// The search-filtered host set, widened so a match on one profile of a
    /// multi-profile host pulls in every sibling sharing its `groupName`
    /// instead of rendering that group as a lone orphaned row. Empty search
    /// returns every host untouched. Feeds both the flat sidebar and the
    /// workspace-mode sections so search behaves consistently in either mode.
    private var searchWidenedHosts: [HostEntry] {
        guard !search.isEmpty else { return hosts }
        let matched = filtered
        let matchedGroups = Set(matched.compactMap(\.groupName))
        return hosts.filter { h in
            matched.contains(where: { $0.persistentModelID == h.persistentModelID })
                || (h.groupName.map(matchedGroups.contains) ?? false)
        }
    }

    /// Groups for the sidebar, built from the widened search set.
    private var sidebarGroups: [HostGroupView] {
        model.groups(from: searchWidenedHosts)
    }

    /// Workspace-mode sections, computed from the same widened search set so
    /// a search narrows rows within each section without orphaning multi-profile
    /// groups, matching the flat-mode sidebar's behavior.
    private var workspaceSections: [WorkspaceSection] {
        model.sections(from: searchWidenedHosts)
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Search hosts", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        Button("New Host") { formMode = .create }
                        Button("New Workspace") { showNewWorkspace = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("New Host or Workspace")
                }
                .padding(8)

                List(selection: $selection) {
                    if model.isWorkspaceMode {
                        ForEach(workspaceSections) { section in
                            Section {
                                if expandedSections[section.id] ?? true {
                                    ForEach(section.groups) { group in hostRow(group) }
                                }
                            } header: {
                                workspaceHeader(section)
                            }
                        }
                    } else {
                        ForEach(sidebarGroups) { group in hostRow(group) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detailContent
        }
        .navigationTitle("Sesh")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    importNow()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import hosts from ~/.ssh/config that aren't already in Sesh")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    openWindow(id: "raw-config")
                } label: {
                    Label("Raw Config", systemImage: "doc.plaintext")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(item: $formMode) { mode in
            HostFormSheet(mode: mode)
        }
        .sheet(isPresented: $model.showFirstRun) {
            FirstRunSheet()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: $showNewWorkspace, onDismiss: { pendingMoveAlias = nil }) {
            WorkspaceNameSheet(mode: .create, onSaved: { ws in
                if let alias = pendingMoveAlias {
                    if let message = model.move(groupDefaultAlias: alias, toWorkspace: ws.id) {
                        model.pendingError = message
                    }
                    pendingMoveAlias = nil
                }
            })
        }
        .sheet(isPresented: .init(
            get: { renameWorkspaceTarget != nil },
            set: { if !$0 { renameWorkspaceTarget = nil } }
        )) {
            if let ws = renameWorkspaceTarget {
                WorkspaceNameSheet(mode: .rename(ws))
            }
        }
        .confirmationDialog(
            "Delete workspace '\(deleteWorkspaceTarget?.name ?? "")'?",
            isPresented: .init(
                get: { deleteWorkspaceTarget != nil },
                set: { if !$0 { deleteWorkspaceTarget = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let ws = deleteWorkspaceTarget, let message = model.deleteWorkspace(ws) {
                    model.pendingError = message
                }
                deleteWorkspaceTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteWorkspaceTarget = nil }
        } message: {
            Text("Hosts in this workspace move back to Default.")
        }
        .alert("Sesh", isPresented: .init(
            get: { model.pendingError != nil },
            set: { if !$0 { model.pendingError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.pendingError ?? "")
        }
        .confirmationDialog(
            "Delete '\(deleteRequest?.title ?? "")'?",
            isPresented: .init(
                get: { deleteRequest != nil },
                set: { if !$0 { deleteRequest = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let group = deleteRequest { deleteGroup(group) }
                deleteRequest = nil
            }
            Button("Cancel", role: .cancel) { deleteRequest = nil }
        }
        .confirmationDialog(
            "Delete \(multiDeleteRequest?.count ?? 0) hosts?",
            isPresented: .init(
                get: { multiDeleteRequest != nil },
                set: { if !$0 { multiDeleteRequest = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let ids = multiDeleteRequest { deleteMultiple(ids) }
                multiDeleteRequest = nil
            }
            Button("Cancel", role: .cancel) { multiDeleteRequest = nil }
        }
        .confirmationDialog(
            "Remove profile '\(removeProfileRequest?.entry.host ?? "")'?",
            isPresented: .init(
                get: { removeProfileRequest != nil },
                set: { if !$0 { removeProfileRequest = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let req = removeProfileRequest {
                    selection.remove(req.entry.persistentModelID)
                    _ = model.removeProfile(req.entry, groupMembers: req.members)
                }
                removeProfileRequest = nil
            }
            Button("Cancel", role: .cancel) { removeProfileRequest = nil }
        }
        .overlay {
            if showPalette {
                CommandPalette(
                    groups: model.groups(from: hosts),
                    resolve: { alias in model.entry(forAlias: alias, in: hosts) },
                    onHost: { entry, action in
                        switch action {
                        case .connect: model.connect(entry)
                        case .copy: model.copyCommand(entry)
                        case .reveal:
                            search = ""
                            selection = [entry.persistentModelID]
                        }
                    },
                    onAction: { action in
                        switch action {
                        case .newHost: formMode = .create
                        case .importFromConfig: importNow()
                        case .rawConfig: openWindow(id: "raw-config")
                        case .settings: showSettings = true
                        }
                    },
                    isPresented: $showPalette
                )
            }
        }
        .background {
            Button("") { showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
            Button("") { formMode = .create }
                .keyboardShortcut("n", modifiers: .command)
                .hidden()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if selection.count == 1, let id = selection.first,
           let entry = hosts.first(where: { $0.persistentModelID == id }) {
            HostDetailView(entry: entry,
                           onEdit: { formMode = .edit($0) },
                           onRemoveProfile: { profileEntry, members in
                               removeProfileRequest = (entry: profileEntry, members: members)
                           })
        } else if hosts.isEmpty {
            ContentUnavailableView {
                Label("No Hosts Yet", systemImage: "server.rack")
            } description: {
                Text("Press ⌘N to add one, or import your existing config.")
            } actions: {
                Button {
                    importNow()
                } label: {
                    Label("Import from ~/.ssh/config", systemImage: "square.and.arrow.down")
                }
            }
        } else if selection.isEmpty {
            ContentUnavailableView("No Host Selected",
                                   systemImage: "server.rack",
                                   description: Text("Select a host, or press ⌘N to add one."))
        } else {
            ContentUnavailableView("\(selection.count) Hosts Selected",
                                   systemImage: "server.rack",
                                   description: Text("Select a single host to view its details."))
        }
    }

    /// The shared HostName shown under a group's title in the sidebar row.
    private func hostSubtitle(_ group: HostGroupView) -> String {
        guard let entry = model.entry(forAlias: group.defaultMember.alias, in: hosts) else { return "—" }
        return entry.properties.first("HostName") ?? "—"
    }

    /// A single sidebar row: Name + IP, tagged for selection, with the
    /// Edit/Duplicate/Delete context menu plus a "Move to Workspace" submenu.
    @ViewBuilder
    private func hostRow(_ group: HostGroupView) -> some View {
        if let entry = model.entry(forAlias: group.defaultMember.alias, in: hosts) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(.headline)
                Text(hostSubtitle(group)).font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(entry.persistentModelID)
            .contextMenu {
                Button("Edit") { formMode = .edit(entry) }
                Button("Duplicate") { duplicate(entry) }
                Menu("Move to Workspace") {
                    Button("Default") { move(group, toWorkspace: nil) }
                    ForEach(model.workspaces, id: \.id) { ws in
                        Button(ws.name) { move(group, toWorkspace: ws.id) }
                    }
                    Divider()
                    Button("New Workspace…") {
                        pendingMoveAlias = group.defaultMember.alias
                        showNewWorkspace = true
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { requestDeleteGroup(group) }
            }
        }
    }

    private func move(_ group: HostGroupView, toWorkspace id: UUID?) {
        if let message = model.move(groupDefaultAlias: group.defaultMember.alias, toWorkspace: id) {
            model.pendingError = message
        }
    }

    /// A sidebar section header: plain title for Default, with a
    /// Rename…/Delete context menu for a real workspace.
    @ViewBuilder
    private func workspaceHeader(_ section: WorkspaceSection) -> some View {
        let expanded = expandedSections[section.id] ?? true
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
            Text(section.title)
            Spacer(minLength: 0)
        }
        // Clicking anywhere on the header row toggles the section's collapse.
        .contentShape(Rectangle())
        .onTapGesture { expandedSections[section.id] = !expanded }
        .contextMenu {
            if let ref = section.workspace {
                Button("Rename…") {
                    if let ws = model.workspaces.first(where: { $0.id == ref.id }) {
                        renameWorkspaceTarget = ws
                    }
                }
                Button("Delete", role: .destructive) {
                    if let ws = model.workspaces.first(where: { $0.id == ref.id }) {
                        deleteWorkspaceTarget = ws
                    }
                }
            }
        }
    }


    /// Laravel's DuplicateSshConfigAction: unique "-copy-N" suffix, then sync.
    private func duplicate(_ entry: HostEntry) {
        let existing = Set(hosts.map(\.host))
        var newHost = entry.host
        var counter = 1
        while existing.contains(newHost) {
            newHost = "\(entry.host)-copy-\(counter)"
            counter += 1
        }
        let duplicated = HostEntry(host: newHost, properties: entry.properties, rawBlock: nil)
        duplicated.displayName = entry.displayName
        context.insert(duplicated)
        do {
            try context.save()
            model.exportNow()
        } catch {
            context.rollback()
            model.pendingError = error.localizedDescription
        }
    }

    /// Right-clicking a row that's part of a larger multi-selection confirms
    /// deleting the whole selection (every selected logical host) at once;
    /// otherwise it confirms deleting just the group whose row was clicked.
    private func requestDeleteGroup(_ group: HostGroupView) {
        if selection.count > 1,
           let entry = model.entry(forAlias: group.defaultMember.alias, in: hosts),
           selection.contains(entry.persistentModelID) {
            multiDeleteRequest = selection
        } else {
            deleteRequest = group
        }
    }

    /// Deletes every member entry of a logical host (all aliases sharing its
    /// group), not just the default profile.
    private func deleteGroup(_ group: HostGroupView) {
        let entries = group.members.compactMap { model.entry(forAlias: $0.alias, in: hosts) }
        for entry in entries { selection.remove(entry.persistentModelID) }
        for entry in entries { context.delete(entry) }
        do {
            try context.save()
            model.exportNow()
        } catch {
            context.rollback()
            model.pendingError = error.localizedDescription
        }
    }

    /// Expands each selected id to its full logical host (group) before
    /// deleting, so a selected default member takes its sibling profiles
    /// with it.
    private func deleteMultiple(_ ids: Set<PersistentIdentifier>) {
        let selected = hosts.filter { ids.contains($0.persistentModelID) }
        let groupKeys = Set(selected.map { $0.groupName ?? $0.host })
        let entries = hosts.filter { groupKeys.contains($0.groupName ?? $0.host) }
        for entry in entries { context.delete(entry) }
        selection = []
        do {
            try context.save()
            model.exportNow()
        } catch {
            context.rollback()
            model.pendingError = error.localizedDescription
        }
    }

    /// Imports hosts from the configured ~/.ssh/config and surfaces the result
    /// via the same alert channel used for errors.
    private func importNow() {
        let result = model.importFromConfig()
        if model.pendingError == nil {
            model.pendingError = "Imported \(result.added) host\(result.added == 1 ? "" : "s") (\(result.skipped) already present)."
        }
    }
}
