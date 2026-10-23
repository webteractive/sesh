import Foundation
import SwiftData
import SSHConfigCore

enum HostsEditRequest: Equatable {
    case create
    case edit(UUID)
}

/// /etc/hosts management. Every change is written to the file FIRST and only
/// committed to the store once the write lands, so a cancelled password
/// prompt or a failed write leaves both exactly as they were and the UI can
/// never claim a state the file doesn't have.
extension AppModel {
    private enum HostsWriteOutcome {
        case written
        case cancelled
        case failed(String)
    }

    /// An entry's id paired with the line it should render to after a change.
    private struct HostsPlanItem {
        var id: UUID
        var line: HostsLine
    }

    /// Hosts-file entries in block order.
    var hostsEntries: [HostsFileEntry] {
        (try? context.fetch(FetchDescriptor<HostsFileEntry>(sortBy: HostsFileEntry.blockOrder))) ?? []
    }

    static var hostsBackupDirectory: String {
        URL.applicationSupportDirectory.appending(path: "Sesh/hosts-backups", directoryHint: .isDirectory).path
    }

    /// Creates (nil `existing`) or updates an entry. Returns an error message
    /// for the form to show inline, or nil on success.
    func saveHostsEntry(_ existing: HostsFileEntry?, ip: String, hostnames: [String],
                        note: String?, isEnabled: Bool) -> String? {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        let names = hostnames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let note = note?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let message = HostsFile.validate(ip: ip, hostnames: names, note: note) { return message }

        let entries = hostsEntries
        let target = existing ?? HostsFileEntry(ip: ip, hostnames: names, note: note, isEnabled: isEnabled,
                                                sortOrder: nextHostsSortOrder(after: entries))
        let proposed = HostsLine(ip: ip, hostnames: names, note: note, isEnabled: isEnabled)
        var plan = entries.map { HostsPlanItem(id: $0.id, line: $0.line) }
        if let i = plan.firstIndex(where: { $0.id == target.id }) {
            plan[i].line = proposed
        } else {
            plan.append(HostsPlanItem(id: target.id, line: proposed))
        }
        let disabled = isEnabled ? disableConflicts(enabling: target.id, in: &plan) : []

        switch writeHostsFile(plan.map(\.line)) {
        case .cancelled: hostsRevision += 1; return "Cancelled — /etc/hosts wasn't changed."
        case .failed(let message): hostsRevision += 1; return message
        case .written:
            target.ip = ip
            target.hostnames = names
            target.note = note
            target.isEnabled = isEnabled
            target.updatedAt = .now
            if existing == nil { context.insert(target) }
            markDisabled(disabled, in: entries)
            return commitHostsChange()
        }
    }

    /// Enables or disables one entry. Enabling disables any other enabled
    /// entry sharing a hostname, in the same write.
    func setHostsEntry(_ entry: HostsFileEntry, enabled: Bool) {
        let entries = hostsEntries
        var plan = entries.map { HostsPlanItem(id: $0.id, line: $0.line) }
        guard let i = plan.firstIndex(where: { $0.id == entry.id }) else { return }
        plan[i].line.isEnabled = enabled
        let disabled = enabled ? disableConflicts(enabling: entry.id, in: &plan) : []
        guard report(writeHostsFile(plan.map(\.line))) else { return }
        entry.isEnabled = enabled
        entry.updatedAt = .now
        markDisabled(disabled, in: entries)
        if let message = commitHostsChange() { pendingError = message }
    }

    /// Adds a disabled copy right after the store's last entry — disabled so
    /// it can never conflict with the original.
    func duplicateHostsEntry(_ entry: HostsFileEntry) {
        let entries = hostsEntries
        let copy = HostsFileEntry(ip: entry.ip, hostnames: entry.hostnames, note: entry.note, isEnabled: false,
                                  sortOrder: nextHostsSortOrder(after: entries))
        guard report(writeHostsFile(entries.map(\.line) + [copy.line])) else { return }
        context.insert(copy)
        if let message = commitHostsChange() { pendingError = message }
    }

    func deleteHostsEntries(_ ids: Set<UUID>) {
        let entries = hostsEntries
        let kept = entries.filter { !ids.contains($0.id) }
        guard kept.count != entries.count, report(writeHostsFile(kept.map(\.line))) else { return }
        for entry in entries where ids.contains(entry.id) { context.delete(entry) }
        if let message = commitHostsChange() { pendingError = message }
    }

    /// Rewrites Sesh's block from the store (the out-of-sync banner's action).
    func reapplyHostsFile() {
        _ = report(writeHostsFile(hostsEntries.map(\.line)))
        refreshHostsFileState()
    }

    /// Moves mapping lines found outside Sesh's block (and outside system
    /// entries and other tools' blocks) into the store and the block, in one
    /// backed-up write, without changing what any hostname resolves to (see
    /// `HostsFile.mergeImport`). Lines already in the store are still moved
    /// out but not duplicated. With an empty store (a reset or a new Mac) the
    /// lines already in Sesh's block are adopted too, so they aren't wiped.
    /// Returns nil on cancel or failure.
    @discardableResult
    func importFromHostsFile() -> (added: Int, skipped: Int)? {
        let entries = hostsEntries
        let candidates: [HostsLine]
        do {
            let text = try hostsWriter.read()
            let orphaned = entries.isEmpty ? (try HostsFile.managedLines(in: text) ?? []) : []
            candidates = try HostsFile.importCandidates(in: text).lines + orphaned
        } catch {
            pendingError = hostsErrorMessage(error)
            return nil
        }
        guard !candidates.isEmpty else { return (0, 0) }

        let merge = HostsFile.mergeImport(existing: entries.map { (id: $0.id, line: $0.line) },
                                          candidates: candidates)
        let kept = entries.map { entry -> HostsLine in
            var line = entry.line
            if merge.enable.contains(entry.id) { line.isEnabled = true }
            if merge.disable.contains(entry.id) { line.isEnabled = false }
            return line
        }
        let outcome = writeHostsFile(kept + merge.added) {
            try HostsFile.importCandidates(in: $0).remaining
        }
        guard report(outcome) else { return nil }
        for entry in entries where merge.enable.contains(entry.id) || merge.disable.contains(entry.id) {
            entry.isEnabled = merge.enable.contains(entry.id)
            entry.updatedAt = .now
        }
        var order = nextHostsSortOrder(after: entries)
        for line in merge.added {
            context.insert(HostsFileEntry(ip: line.ip, hostnames: line.hostnames, note: line.note,
                                          isEnabled: line.isEnabled, sortOrder: order))
            order += 1
        }
        if let message = commitHostsChange() { pendingError = message; return nil }
        return (merge.added.count, merge.skipped)
    }

    /// Runs the import and reports the result through the shared alert.
    func importFromHostsFileAndReport() {
        guard let result = importFromHostsFile(), pendingError == nil else { return }
        pendingError = "Imported \(result.added) entr\(result.added == 1 ? "y" : "ies") (\(result.skipped) already present)."
    }

    /// Re-reads /etc/hosts (no root needed) to refresh the out-of-sync flag
    /// and the hostnames set outside Sesh's block.
    func refreshHostsFileState() {
        guard let text = try? hostsWriter.read() else { return }
        let lines = hostsEntries.map(\.line)
        do {
            if let managed = try HostsFile.managedLines(in: text) {
                hostsOutOfSync = managed != lines
            } else {
                hostsOutOfSync = !lines.isEmpty
            }
        } catch {
            hostsOutOfSync = true   // damaged block
        }
        hostsExternalHostnames = (try? HostsFile.enabledHostnamesOutsideBlock(in: text)) ?? []
    }

    /// An enabled entry sharing a hostname with an enabled line outside
    /// Sesh's block — that earlier line usually wins.
    func isOverridden(_ entry: HostsFileEntry) -> Bool {
        entry.isEnabled && entry.hostnames.contains { hostsExternalHostnames.contains($0.lowercased()) }
    }

    // MARK: - Private

    /// The sort order that places a new entry after every existing one.
    private func nextHostsSortOrder(after entries: [HostsFileEntry]) -> Int {
        (entries.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Disables, within `plan`, every other enabled item sharing a hostname
    /// with `id`. Returns the ids it disabled.
    private func disableConflicts(enabling id: UUID, in plan: inout [HostsPlanItem]) -> Set<UUID> {
        let ids = HostsFile.idsToDisable(enabling: id, entries: plan.map {
            (id: $0.id, hostnames: $0.line.hostnames, isEnabled: $0.line.isEnabled)
        })
        for i in plan.indices where ids.contains(plan[i].id) { plan[i].line.isEnabled = false }
        return ids
    }

    private func markDisabled(_ ids: Set<UUID>, in entries: [HostsFileEntry]) {
        for entry in entries where ids.contains(entry.id) {
            entry.isEnabled = false
            entry.updatedAt = .now
        }
    }

    /// Renders `lines` into Sesh's block of the current file (optionally
    /// transformed first, for import) and writes it as root, backing up
    /// first. An unchanged file is not rewritten, so no prompt appears.
    private func writeHostsFile(_ lines: [HostsLine],
                                transform: (String) throws -> String = { $0 }) -> HostsWriteOutcome {
        do {
            let current = try hostsWriter.read()
            let updated = try HostsFile.replacingBlock(in: transform(current), with: lines)
            guard updated != current else { return .written }
            try BackupManager().backup(configPath: HostsFileWriter.hostsPath, into: Self.hostsBackupDirectory)
            try hostsWriter.write(updated)
            return .written
        } catch HostsWriteError.cancelled {
            return .cancelled
        } catch {
            return .failed(hostsErrorMessage(error))
        }
    }

    /// True when written; surfaces failures through `pendingError` and
    /// treats a cancelled prompt as a quiet no-op.
    private func report(_ outcome: HostsWriteOutcome) -> Bool {
        switch outcome {
        case .written: return true
        case .cancelled: hostsRevision += 1; return false
        case .failed(let message): hostsRevision += 1; pendingError = message; return false
        }
    }

    /// Saves the store after a write landed. A failed save leaves the file
    /// ahead of the store; the refresh then shows the out-of-sync banner.
    private func commitHostsChange() -> String? {
        defer { refreshHostsFileState() }
        do {
            try context.save()
            return nil
        } catch {
            context.rollback()
            return error.localizedDescription
        }
    }

    private func hostsErrorMessage(_ error: Error) -> String {
        switch error {
        case HostsWriteError.failed(let message): message
        case HostsFileError.damagedBlock:
            "Sesh's section in /etc/hosts is damaged (a start or end marker is missing). Fix or remove it by hand, then try again."
        case HostsFileError.notUTF8: "/etc/hosts isn't UTF-8 text, so Sesh won't rewrite it."
        default: error.localizedDescription
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
