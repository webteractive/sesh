import AppKit
import Foundation
import Observation
import SwiftData
import SSHConfigCore

enum SyncMode: String, CaseIterable, Identifiable {
    case fromFile = "Sync From File"
    case toFile = "Sync To File"
    case both = "Sync Both"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: HostEntry.self)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }()

    private let pathStore = ConfigPathStore()
    private let engine = SyncEngine()
    private let detector = ConflictDetector()
    let resolver = ConflictResolver()

    private let terminalLauncher = TerminalLauncher()
    var installedTerminals: [Terminal] = []

    static let preferredTerminalKey = "preferredTerminalId"

    var preferredTerminalId: String {
        get { UserDefaults.standard.string(forKey: Self.preferredTerminalKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.preferredTerminalKey) }
    }

    /// Detected terminals the user can actually pick — System Default is a
    /// silent last-resort, never an offered option.
    var selectableTerminals: [Terminal] {
        installedTerminals.filter { $0.id != TerminalRegistry.systemDefaultId }
    }

    /// Resolved terminal used by Connect: the explicit pick if still installed,
    /// else Zetty if installed, else the first detected terminal, else the
    /// invisible system-default fallback (so Connect never dead-ends).
    var preferredTerminal: Terminal {
        if let stored = installedTerminals.first(where: { $0.id == preferredTerminalId }),
           stored.id != TerminalRegistry.systemDefaultId {
            return stored
        }
        if let zetty = installedTerminals.first(where: { $0.id == "dev.more.zetty" }) {
            return zetty
        }
        return selectableTerminals.first ?? TerminalRegistry.known[0]
    }

    var pendingError: String?
    var syncItems: [SyncItem]?
    var conflicts: [Conflict] = []
    var showSyncSheet = false
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

    /// Returns an error message, or nil on success (mirrors SetConfigPathAction:
    /// store path, backup if the file exists, initial import).
    func saveConfigPath(_ raw: String) -> String? {
        switch ConfigPathStore.validate(raw) {
        case .failure(let message):
            return message
        case .success(let expanded):
            pathStore.path = expanded
            if FileManager.default.fileExists(atPath: expanded) {
                do {
                    try BackupManager().backup(configPath: expanded)
                    _ = try engine.syncFromFile(path: expanded, context: context)
                } catch {
                    pendingError = "Path saved, but backup or import failed: \(error.localizedDescription)"
                }
            }
            showFirstRun = false
            return nil
        }
    }

    func runSync(_ mode: SyncMode) {
        guard let path = configPath else { showFirstRun = true; return }
        do {
            switch mode {
            case .fromFile: syncItems = try engine.syncFromFile(path: path, context: context)
            case .toFile:  try engine.syncToFile(path: path, context: context); syncItems = []
            case .both:    syncItems = try engine.syncBoth(path: path, context: context)
            }
            conflicts = try detector.detect(path: path, context: context)
            showSyncSheet = true
        } catch {
            pendingError = error.localizedDescription
            // syncBoth's fromFile phase may have already persisted store changes
            // before toFile threw; refresh conflicts against what's actually on
            // disk/in the store and drop stale results so the UI doesn't show a
            // sync outcome that didn't fully happen.
            refreshConflicts()
            syncItems = nil
        }
    }

    /// Fire-and-forget store→file sync after every mutation (Laravel's
    /// rescue()-wrapped after() hooks): failures warn, never roll back.
    func autoSyncToFile() {
        guard let path = configPath else { return }
        do { try engine.syncToFile(path: path, context: context) }
        catch { pendingError = "Saved, but writing the config file failed: \(error.localizedDescription)" }
    }

    func refreshConflicts() {
        guard let path = configPath else { return }
        conflicts = (try? detector.detect(path: path, context: context)) ?? []
    }

    /// Connect via a specific terminal, or the preferred one when nil.
    func connect(_ host: String, with terminal: Terminal? = nil) {
        do {
            try terminalLauncher.launch(terminal ?? preferredTerminal, host: host) { [weak self] msg in
                self?.pendingError = msg
            }
        } catch {
            pendingError = error.localizedDescription
        }
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
                    isDefault: e.isDefaultProfile, isConnectable: e.isConnectable)
        })
    }

    func entry(forAlias alias: String, in hosts: [HostEntry]) -> HostEntry? {
        hosts.first { $0.host == alias }
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
            autoSyncToFile()
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
            autoSyncToFile()
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
    /// auto-syncs. Returns an error message, or nil on success.
    func ungroup(_ members: [HostEntry]) -> String? {
        let snapshot = members.map { ($0, $0.groupName, $0.isDefaultProfile) }
        for m in members { m.groupName = nil; m.isDefaultProfile = false }
        do {
            try context.save()
            autoSyncToFile()
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
