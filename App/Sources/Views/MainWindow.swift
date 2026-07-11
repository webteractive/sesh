import SwiftUI
import SwiftData
import SSHConfigCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \HostEntry.updatedAt, order: .reverse) private var hosts: [HostEntry]
    @State private var search = ""
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var formMode: FormMode?
    @State private var showSettings = false
    @State private var deleteRequest: HostEntry?
    @State private var multiDeleteRequest: Set<PersistentIdentifier>?
    @State private var showPalette = false
    @State private var addProfileBase: HostEntry?
    @State private var removeProfileRequest: (entry: HostEntry, members: [HostEntry])?

    private var filtered: [HostEntry] {
        guard !search.isEmpty else { return hosts }
        return hosts.filter {
            $0.host.localizedCaseInsensitiveContains(search)
                || ($0.properties.first("HostName") ?? "").localizedCaseInsensitiveContains(search)
                || ($0.properties.first("User") ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    /// Groups for the sidebar. When searching, expands the filtered set to
    /// include every sibling of a matched entry's group so a match on one
    /// alias doesn't collapse the whole group to a lone row.
    private var sidebarGroups: [HostGroupView] {
        guard !search.isEmpty else { return model.groups(from: hosts) }
        let matched = filtered
        let matchedGroups = Set(matched.compactMap(\.groupName))
        let expanded = hosts.filter { h in
            matched.contains(where: { $0.persistentModelID == h.persistentModelID })
                || (h.groupName.map(matchedGroups.contains) ?? false)
        }
        return model.groups(from: expanded)
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(sidebarGroups) { group in
                    if group.isMultiProfile {
                        DisclosureGroup {
                            ForEach(group.members) { member in
                                memberRow(member)
                            }
                        } label: {
                            groupLabel(group)
                        }
                    } else {
                        memberRow(group.members[0])
                    }
                }
            }
            .searchable(text: $search, prompt: "Search hosts")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detailContent
        }
        .navigationTitle("Sesh")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    ForEach(SyncMode.allCases) { mode in
                        Button(mode.rawValue) { model.runSync(mode) }
                    }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    formMode = .create
                } label: {
                    Label("New Host", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(item: $formMode) { mode in
            HostFormSheet(mode: mode)
        }
        .sheet(item: $addProfileBase) { base in
            AddProfileSheet(base: base)
        }
        .sheet(isPresented: $model.showSyncSheet) {
            SyncSheet()
        }
        .sheet(isPresented: $model.showFirstRun) {
            FirstRunSheet()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
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
            "Delete '\(deleteRequest?.host ?? "")'?",
            isPresented: .init(
                get: { deleteRequest != nil },
                set: { if !$0 { deleteRequest = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let entry = deleteRequest { delete(entry) }
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
                        case .connect: model.connect(entry.host)
                        case .copy: model.copyCommand(entry)
                        case .reveal:
                            search = ""
                            selection = [entry.persistentModelID]
                        }
                    },
                    onAction: { action in
                        switch action {
                        case .newHost: formMode = .create
                        case .syncFromFile: model.runSync(.fromFile)
                        case .syncToFile: model.runSync(.toFile)
                        case .syncBoth: model.runSync(.both)
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
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if selection.count == 1, let id = selection.first,
           let entry = hosts.first(where: { $0.persistentModelID == id }) {
            HostDetailView(entry: entry,
                           onEdit: { formMode = .edit($0) },
                           onAddProfile: { addProfileBase = $0 },
                           onRemoveProfile: { profileEntry, members in
                               removeProfileRequest = (entry: profileEntry, members: members)
                           })
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

    @ViewBuilder
    private func groupLabel(_ group: HostGroupView) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title).font(.headline)
            Text("^[\(group.members.count) profile](inflect: true)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func memberRow(_ member: ProfileRef) -> some View {
        if let entry = model.entry(forAlias: member.alias, in: hosts) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.label).font(.headline)
                    if member.isDefault {
                        Text("default").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(member.user.map { "\($0)@\(entry.properties.first("HostName") ?? "—")" }
                     ?? member.alias).font(.caption).foregroundStyle(.secondary)
            }
            .tag(entry.persistentModelID)
            .contextMenu {
                Button("Edit") { formMode = .edit(entry) }
                Button("Duplicate") { duplicate(entry) }
                Button("Add Profile…") { addProfileBase = entry }
                if let group = entry.groupName {
                    Button("Ungroup '\(group)'") { _ = model.ungroupOne(entry, allHosts: hosts) }
                }
                Divider()
                Button("Delete", role: .destructive) { requestDelete(entry) }
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
        context.insert(HostEntry(host: newHost, properties: entry.properties, rawBlock: nil))
        do {
            try context.save()
            model.autoSyncToFile()
        } catch {
            context.rollback()
            model.pendingError = error.localizedDescription
        }
    }

    /// Right-clicking a row that's part of a larger multi-selection confirms
    /// deleting the whole selection at once; otherwise it confirms deleting
    /// just the row that was clicked.
    private func requestDelete(_ entry: HostEntry) {
        if selection.count > 1, selection.contains(entry.persistentModelID) {
            multiDeleteRequest = selection
        } else {
            deleteRequest = entry
        }
    }

    private func delete(_ entry: HostEntry) {
        selection.remove(entry.persistentModelID)
        context.delete(entry)
        do {
            try context.save()
            model.autoSyncToFile()
        } catch {
            context.rollback()
            model.pendingError = error.localizedDescription
        }
    }

    private func deleteMultiple(_ ids: Set<PersistentIdentifier>) {
        let entries = hosts.filter { ids.contains($0.persistentModelID) }
        for entry in entries { context.delete(entry) }
        selection = []
        do {
            try context.save()
            model.autoSyncToFile()
        } catch {
            context.rollback()
            model.pendingError = error.localizedDescription
        }
    }
}
