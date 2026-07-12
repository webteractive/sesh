import AppKit
import Foundation
import Observation
import SwiftData
import SSHConfigCore

@MainActor
@Observable
final class AppModel {
    static let container: ModelContainer = {
        do {
            let dir = URL.applicationSupportDirectory.appending(path: "Sesh", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let config = ModelConfiguration(url: dir.appending(path: "Sesh.store"))
            return try ModelContainer(for: HostEntry.self, Workspace.self, configurations: config)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }()

    private let pathStore = ConfigPathStore()
    private let exporter = ConfigExporter()
    private let includeManager = IncludeManager()
    private let importer = ConfigImporter()

    private let terminalLauncher = TerminalLauncher()
    var installedTerminals: [Terminal] = []

    static let preferredTerminalKey = "preferredTerminalId"
    static let managedPathKey = "managedConfigPath"

    var preferredTerminalId: String {
        get { UserDefaults.standard.string(forKey: Self.preferredTerminalKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.preferredTerminalKey) }
    }

    /// Path to the app-managed config fragment that's `Include`d from the
    /// user's real ssh config; defaults alongside it under `~/.ssh`.
    var managedPath: String {
        get { UserDefaults.standard.string(forKey: Self.managedPathKey) ?? "~/.ssh/sesh.conf" }
        set { UserDefaults.standard.set(newValue, forKey: Self.managedPathKey) }
    }

    /// Detected terminals the user can actually pick — System Default is a
    /// silent last-resort, never an offered option.
    var selectableTerminals: [Terminal] {
        installedTerminals.filter { $0.id != TerminalRegistry.systemDefaultId }
    }

    /// Resolved terminal used by Connect: the explicit pick if still installed,
    /// else the first detected ssh:// terminal, else the invisible
    /// system-default fallback (so Connect never dead-ends).
    var preferredTerminal: Terminal {
        if let stored = installedTerminals.first(where: { $0.id == preferredTerminalId }),
           stored.id != TerminalRegistry.systemDefaultId {
            return stored
        }
        return selectableTerminals.first ?? TerminalRegistry.known[0]
    }

    var pendingError: String?
    var showFirstRun = false

    var context: ModelContext { Self.container.mainContext }
    var configPath: String? { pathStore.path }

    init() {
        // Carry the config-path preference over from the pre-rename bundle id
        // (the SwiftData store lives at the shared default location, so hosts
        // and groupings migrate automatically; only this pref is domain-keyed).
        Self.migrateLegacyPreferencesIfNeeded()
        // Detect terminals up front so the menu bar can connect before the
        // main window is ever opened (this is a menu-bar-first app).
        refreshTerminals()
    }

    private static let legacyBundleId = "co.webteractive.sshconfig"

    private static func migrateLegacyPreferencesIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: ConfigPathStore.key) == nil,
              let legacy = UserDefaults(suiteName: legacyBundleId),
              let path = legacy.string(forKey: ConfigPathStore.key) else { return }
        defaults.set(path, forKey: ConfigPathStore.key)
    }

    func onLaunch() {
        refreshTerminals()
        showFirstRun = (configPath == nil)
    }

    func refreshTerminals() {
        installedTerminals = terminalLauncher.detectInstalled()
    }

    // MARK: - Dock icon visibility

    /// Number of visible app windows. The Dock icon (`.regular` policy) is
    /// shown while ≥1 window is open and hidden (`.accessory`, menu-bar-only)
    /// once the last window is explicitly closed.
    private var openWindowCount = 0

    func windowAppeared() {
        openWindowCount += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDisappeared() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Returns an error message, or nil on success. Only stores the path;
    /// import is manual/optional and nothing touches the file at path-set
    /// time (backups happen in ensureInclude/export when we actually write).
    ///
    /// Doesn't flip `showFirstRun` itself — `FirstRunSheet` stays open after a
    /// successful save so it can offer to import existing hosts, dismissing
    /// only once the user picks Import or Skip.
    func saveConfigPath(_ raw: String) -> String? {
        switch ConfigPathStore.validate(raw) {
        case .failure(let message):
            return message
        case .success(let expanded):
            pathStore.path = expanded
            return nil
        }
    }

    /// Renders the whole store to the managed file and ensures the Include.
    /// Store is the source of truth, so failures only warn (file is rebuildable).
    func exportNow() {
        // Defense-in-depth: if the managed path somehow aliases the real
        // config (e.g. a stray/mistyped Settings entry), refuse to export —
        // exporter.write would overwrite the user's actual ~/.ssh/config
        // with only the store's rendered hosts, destroying everything else
        // in it (Match blocks, other Includes, manually-added hosts).
        let expandedManaged = (managedPath as NSString).expandingTildeInPath
        let expandedConfig = ((configPath ?? ConfigPathStore.defaultSuggestion) as NSString).expandingTildeInPath
        guard expandedManaged != expandedConfig else {
            pendingError = "Managed file path can't be your main ~/.ssh/config."
            return
        }
        do {
            let entries = try context.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.createdAt)]))
                .map { RenderableHost(host: $0.host, properties: $0.properties) }
            try exporter.write(entries, toPath: managedPath)
            try includeManager.ensureInclude(managedPath: managedPath, configPath: configPath ?? ConfigPathStore.defaultSuggestion)
        } catch {
            pendingError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Adds hosts from ~/.ssh/config that aren't already in the store (by
    /// alias). Group-aware: hosts sharing a `HostName` across ≥2 distinct
    /// users import as one profile group (members keep their original
    /// aliases); everything else imports as a standalone host. Additive
    /// only — never deletes or renames an existing alias.
    @discardableResult
    func importFromConfig() -> (added: Int, skipped: Int) {
        let path = configPath ?? ConfigPathStore.defaultSuggestion
        let existing = Set((try? context.fetch(FetchDescriptor<HostEntry>()))?.map(\.host) ?? [])
        var added = 0, skipped = 0
        for group in importer.groups(inConfigAt: path) {
            let isGroup = group.groupName != nil
            for (index, member) in group.members.enumerated() {
                if existing.contains(member.alias) { skipped += 1; continue }
                let entry = HostEntry(host: member.alias, properties: member.properties, rawBlock: nil)
                entry.displayName = group.displayName
                entry.groupName = group.groupName
                entry.isDefaultProfile = isGroup && index == 0
                context.insert(entry)
                added += 1
            }
        }
        do {
            try context.save()
            exportNow()
            return (added, skipped)
        } catch {
            context.rollback()
            pendingError = error.localizedDescription
            return (0, 0)
        }
    }

    var managedFileActive: Bool {
        let path = configPath ?? ConfigPathStore.defaultSuggestion
        return includeManager.hasInclude(managedPath: managedPath, configPath: path)
            && FileManager.default.fileExists(atPath: (managedPath as NSString).expandingTildeInPath)
    }

    @discardableResult
    func linkInclude() -> String? {
        do { try includeManager.ensureInclude(managedPath: managedPath,
                                              configPath: configPath ?? ConfigPathStore.defaultSuggestion); return nil }
        catch { return error.localizedDescription }
    }

    func connect(_ entry: HostEntry, with terminal: Terminal? = nil) {
        guard HostValidation.isSafeToLaunch(entry.host) else {
            pendingError = "'\(entry.host)' isn't a safe alias to connect."
            return
        }
        guard let url = connectURL(for: entry) else {
            pendingError = "Couldn't build a connection URL for '\(entry.host)'."
            return
        }
        do {
            try terminalLauncher.open(url, with: terminal ?? preferredTerminal) { [weak self] msg in
                self?.pendingError = msg
            }
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// ssh://<alias> when the managed file is active; otherwise a direct
    /// ssh://[user@]hostname[:port] built from the entry's properties.
    private func connectURL(for entry: HostEntry) -> URL? {
        if managedFileActive {
            return URL(string: "ssh://\(entry.host)")
        }
        let host = entry.properties.first("HostName") ?? entry.host
        var s = "ssh://"
        if let user = entry.properties.first("User"),
           let enc = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) {
            s += "\(enc)@"
        }
        s += host
        if let port = entry.properties.first("Port") { s += ":\(port)" }
        return URL(string: s)
    }

    func copyCommand(_ entry: HostEntry) {
        NSPasteboard.general.clearContents()
        let command: String
        if HostValidation.isSafeToLaunch(entry.host) {
            command = entry.sshCommand
        } else {
            // Unsafe aliases (e.g. imported from a crafted config) get
            // shell-quoted so pasting the copied text can't execute anything
            // beyond `ssh` with that literal argument.
            let escaped = entry.host.replacingOccurrences(of: "'", with: "'\\''")
            command = "ssh '\(escaped)'"
        }
        NSPasteboard.general.setString(command, forType: .string)
    }

    // MARK: - Connection profiles

    /// Maps entries into `HostGroupView`s (user/identity read from `properties`).
    func groups(from hosts: [HostEntry]) -> [HostGroupView] {
        HostGrouping.groups(from: hosts.map { e in
            HostRow(alias: e.host, groupName: e.groupName,
                    user: e.properties.first("User"),
                    identityFile: e.properties.first("IdentityFile"),
                    isDefault: e.isDefaultProfile, isConnectable: e.isConnectable,
                    displayName: e.displayName)
        })
    }

    func entry(forAlias alias: String, in hosts: [HostEntry]) -> HostEntry? {
        hosts.first { $0.host == alias }
    }

    // MARK: - Workspaces

    /// All workspaces, oldest-created first. Empty until the user creates one
    /// (workspace membership is app-only — never written to ssh config).
    var workspaces: [Workspace] {
        (try? context.fetch(FetchDescriptor<Workspace>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]))) ?? []
    }

    /// Move a workspace one slot up or down in the sidebar order. App-only.
    func moveWorkspace(_ ws: Workspace, up: Bool) -> String? {
        var order = workspaces.map(\.id)
        guard let i = order.firstIndex(of: ws.id) else { return nil }
        let j = up ? i - 1 : i + 1
        guard order.indices.contains(j) else { return nil }
        order.swapAt(i, j)
        return reorderWorkspaces(order)
    }

    /// Reorder workspaces to match `orderedIDs`. Assigns each a fresh
    /// `sortOrder` = its index. App-only; no export.
    func reorderWorkspaces(_ orderedIDs: [UUID]) -> String? {
        let byID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let snapshot = workspaces.map { ($0, $0.sortOrder) }
        for (index, id) in orderedIDs.enumerated() { byID[id]?.sortOrder = index }
        if let err = saveOrRollback() {
            for (ws, order) in snapshot { ws.sortOrder = order }
            return err
        }
        return nil
    }

    /// Whether the app should show workspace UI at all (sections, picker).
    var isWorkspaceMode: Bool { !workspaces.isEmpty }

    /// Groups `hosts` into `WorkspaceSection`s (Default first, then each
    /// workspace in creation order).
    func sections(from hosts: [HostEntry]) -> [WorkspaceSection] {
        let rows = hosts.map { e in
            HostRow(alias: e.host, groupName: e.groupName,
                    user: e.properties.first("User"), identityFile: e.properties.first("IdentityFile"),
                    isDefault: e.isDefaultProfile, isConnectable: e.isConnectable,
                    displayName: e.displayName)
        }
        var widByAlias: [String: UUID] = [:]
        for e in hosts { if let w = e.workspaceID { widByAlias[e.host] = w } }
        let refs = workspaces.map { WorkspaceRef(id: $0.id, name: $0.name) }
        return WorkspaceSectioning.sections(rows: rows, workspaceIDByAlias: widByAlias, workspaces: refs)
    }

    /// Creates a new workspace named `name`. Returns an error message, or nil
    /// on success. Never touches ssh config — workspaces are app-only.
    func createWorkspace(name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Workspace name is required." }
        if workspaces.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            return "A workspace named '\(n)' already exists."
        }
        let nextOrder = (workspaces.map(\.sortOrder).max() ?? -1) + 1
        context.insert(Workspace(name: n, sortOrder: nextOrder))
        return saveOrRollback()
    }

    /// Renames `ws` to `name`. Returns an error message, or nil on success.
    func renameWorkspace(_ ws: Workspace, to name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Workspace name is required." }
        if workspaces.contains(where: { $0.id != ws.id && $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            return "A workspace named '\(n)' already exists."
        }
        let old = ws.name
        ws.name = n
        if let e = saveOrRollback() { ws.name = old; return e }
        return nil
    }

    /// Deletes `ws`, reassigning any of its hosts back to Default
    /// (`workspaceID = nil`) first — hosts themselves are never deleted.
    /// Returns an error message, or nil on success.
    func deleteWorkspace(_ ws: Workspace) -> String? {
        let id = ws.id
        let affected = (try? context.fetch(FetchDescriptor<HostEntry>()))?.filter { $0.workspaceID == id } ?? []
        let snapshot = affected.map { ($0, $0.workspaceID) }
        for e in affected { e.workspaceID = nil }        // reassign to Default (never delete hosts)
        context.delete(ws)
        if let err = saveOrRollback() {
            for (e, w) in snapshot { e.workspaceID = w }
            return err
        }
        return nil
    }

    /// Move a whole logical host (all members of the group whose default alias
    /// is `groupDefaultAlias`) to a workspace (nil = Default).
    func move(groupDefaultAlias alias: String, toWorkspace id: UUID?) -> String? {
        let all = (try? context.fetch(FetchDescriptor<HostEntry>())) ?? []
        guard let anchor = all.first(where: { $0.host == alias }) else { return nil }
        let key = anchor.groupName ?? anchor.host
        let members = all.filter { ($0.groupName ?? $0.host) == key }
        let snapshot = members.map { ($0, $0.workspaceID) }
        for m in members { m.workspaceID = id }
        if let err = saveOrRollback() {
            for (m, w) in snapshot { m.workspaceID = w }
            return err
        }
        return nil
    }

    /// Saves the context, rolling back and stashing `pendingError` on failure.
    /// Returns an error message, or nil on success.
    private func saveOrRollback() -> String? {
        do { try context.save(); return nil }
        catch { context.rollback(); pendingError = error.localizedDescription; return error.localizedDescription }
    }

    /// Applies a `HostFormModel` from the new host form: reconciles it against
    /// the edited group's current members (nil `groupID` = create), inserts,
    /// updates, or deletes `HostEntry`s per the resulting plan, then exports.
    /// Returns an error message, or nil on success.
    func saveHostForm(_ form: HostFormModel, editingGroup groupID: String?) -> String? {
        if let message = form.validationError() { return message }
        let all = (try? context.fetch(FetchDescriptor<HostEntry>())) ?? []
        // Members of the group being edited (by groupName, or the single alias).
        let members = all.filter { entry in
            guard let groupID else { return false }
            return entry.groupName == groupID || entry.host == groupID
        }
        // Pass the FULL set of store aliases — the reconciler already excludes
        // this group's own aliases internally via `existing`, so subtracting
        // them here would let this group collide with its own former aliases
        // in ways the reconciler doesn't expect.
        let plan = HostFormReconciler.plan(
            form,
            existing: members.map { ($0.host, $0.properties.first("User")) },
            allAliases: Set(all.map(\.host)))

        let byAlias = Dictionary(uniqueKeysWithValues: all.map { ($0.host, $0) })
        // Snapshot for rollback of dirty in-memory fields (SwiftData's
        // rollback() discards pending inserts/deletes but doesn't reliably
        // revert property changes on already-persisted objects).
        let snapshot = members.map { ($0, $0.host, $0.groupName, $0.isDefaultProfile, $0.displayName, $0.properties, $0.updatedAt, $0.workspaceID) }

        for alias in plan.deleteAliases { if let e = byAlias[alias] { context.delete(e) } }
        for u in plan.upserts {
            let entry = byAlias[u.alias] ?? {
                let e = HostEntry(host: u.alias, properties: u.properties, rawBlock: nil)
                context.insert(e)
                return e
            }()
            entry.host = u.alias
            entry.properties = u.properties
            entry.groupName = u.groupName
            entry.isDefaultProfile = u.isDefault
            entry.displayName = form.displayName.trimmingCharacters(in: .whitespaces)
            entry.updatedAt = .now
            entry.workspaceID = form.workspaceID
        }
        do {
            try context.save()
            exportNow()
            return nil
        } catch {
            context.rollback()
            for (e, host, group, isDefault, name, properties, updatedAt, workspaceID) in snapshot {
                e.host = host
                e.groupName = group
                e.isDefaultProfile = isDefault
                e.displayName = name
                e.properties = properties
                e.updatedAt = updatedAt
                e.workspaceID = workspaceID
            }
            return error.localizedDescription
        }
    }

    /// Creates a sibling profile under `base`'s group (sharing `groupName`,
    /// defaulting it to `base.host` and marking `base` the default when it had
    /// no group yet). Returns an error message, or nil on success.
    func addProfile(to base: HostEntry, label: String, user: String,
                    identityFile: String?, allHosts: [HostEntry]) -> String? {
        let group = base.groupName ?? base.host
        let profile = ProfileFactory.make(
            baseProperties: base.properties, baseAlias: base.host, label: label,
            user: user, identityFile: identityFile,
            existingAliases: Set(allHosts.map(\.host)))
        // SwiftData's rollback() discards pending inserts/deletes but does NOT
        // reliably revert property changes on already-persisted objects, so we
        // restore the base's fields ourselves on failure.
        let priorGroup = base.groupName
        let priorDefault = base.isDefaultProfile
        if base.groupName == nil {          // first profile turns the host into a group
            base.groupName = group
            base.isDefaultProfile = true
        }
        let entry = HostEntry(host: profile.alias, properties: profile.properties, rawBlock: nil)
        entry.groupName = group
        context.insert(entry)
        do {
            try context.save()
            exportNow()
            return nil
        } catch {
            context.rollback()
            base.groupName = priorGroup
            base.isDefaultProfile = priorDefault
            return error.localizedDescription
        }
    }

    /// Deletes `entry`'s alias; if it was the default, promotes the earliest
    /// remaining member, and if it was the last member the group dissolves
    /// (the remaining single member clears its `groupName`). Returns an error
    /// message, or nil on success.
    func removeProfile(_ entry: HostEntry, groupMembers: [HostEntry]) -> String? {
        let wasDefault = entry.isDefaultProfile
        let remaining = groupMembers.filter { $0.persistentModelID != entry.persistentModelID }
        // Snapshot the fields we're about to mutate so we can restore them if
        // the save fails (rollback() re-inserts the deleted entry but won't
        // revert these property changes on the surviving members).
        let snapshot = remaining.map { ($0, $0.groupName, $0.isDefaultProfile) }
        context.delete(entry)
        if remaining.count == 1 {
            remaining[0].groupName = nil          // group dissolves back to a lone host
            remaining[0].isDefaultProfile = false
        } else if wasDefault, let promote = remaining.first {
            promote.isDefaultProfile = true
        }
        do {
            try context.save()
            exportNow()
            return nil
        } catch {
            context.rollback()
            for (member, group, isDefault) in snapshot {
                member.groupName = group
                member.isDefaultProfile = isDefault
            }
            return error.localizedDescription
        }
    }

    /// Clears `groupName`/`isDefaultProfile` on every member, saves, and
    /// re-exports. Returns an error message, or nil on success.
    func ungroup(_ members: [HostEntry]) -> String? {
        let snapshot = members.map { ($0, $0.groupName, $0.isDefaultProfile) }
        for m in members { m.groupName = nil; m.isDefaultProfile = false }
        do {
            try context.save()
            exportNow()
            return nil
        } catch {
            context.rollback()
            for (member, group, isDefault) in snapshot {
                member.groupName = group
                member.isDefaultProfile = isDefault
            }
            return error.localizedDescription
        }
    }

    /// Convenience: ungroups the entire group that `entry` belongs to (looked
    /// up by `groupName` within `allHosts`). No-op (returns nil) if `entry`
    /// isn't currently grouped.
    func ungroupOne(_ entry: HostEntry, allHosts: [HostEntry]) -> String? {
        guard let group = entry.groupName else { return nil }
        return ungroup(allHosts.filter { $0.groupName == group })
    }

    func rawConfigText() -> String {
        guard let path = configPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "No config file found."
        }
        return text
    }
}
