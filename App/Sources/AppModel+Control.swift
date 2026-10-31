import Foundation
import SwiftData
import SSHConfigCore

/// Carries out `sesh` CLI requests (see `ControlProtocol`) with the same
/// model operations the windows use, so the CLI can do anything the UI can
/// and the UI shows each change as it lands.
extension AppModel {
    func handle(_ command: ControlCommand) async throws -> any Encodable {
        switch command {
        case .status: return statusInfo()

        case .listHosts: return sidebarGroups().map { hostInfo($0) }
        case .showHost(let ref): return hostInfo(try hostMembers(ref))
        case .addHost(let spec): return try addHost(spec)
        case .editHost(let ref, let changes): return try editHost(ref, changes)
        case .duplicateHost(let ref): return try duplicateHost(ref)
        case .deleteHosts(let refs): return try deleteHosts(refs)
        case .moveHosts(let refs, let workspace): return try moveHosts(refs, to: workspace)
        case .connect(let alias, let terminal): return try connect(alias, terminal: terminal)

        case .addProfile(let host, let label, let user, let identityFile):
            return try addProfile(host, label: label, user: user, identityFile: identityFile)
        case .editProfile(let alias, let changes): return try editProfile(alias, changes)
        case .removeProfile(let alias): return try removeProfile(alias)
        case .ungroup(let host): return try ungroup(host)

        case .listWorkspaces: return workspaceInfos()
        case .createWorkspace(let name): return try createWorkspaceCommand(name)
        case .renameWorkspace(let ref, let name): return try renameWorkspaceCommand(ref, to: name)
        case .deleteWorkspace(let ref): return try deleteWorkspaceCommand(ref)
        case .moveWorkspace(let ref, let placement): return try moveWorkspaceCommand(ref, placement)

        case .listHostsEntries:
            refreshHostsFileState()
            return hostsEntryInfos()
        case .showHostsEntry(let ref):
            refreshHostsFileState()
            return hostsEntryInfo(try hostsEntry(ref))
        case .addHostsEntry(let ip, let hostnames, let note, let enabled):
            return try addHostsEntry(ip: ip, hostnames: hostnames, note: note, enabled: enabled)
        case .addHostsText(let text): return try addHostsText(text)
        case .editHostsEntry(let ref, let changes): return try editHostsEntry(ref, changes)
        case .setHostsEntries(let refs, let enabled): return try setHostsEntries(refs, enabled: enabled)
        case .duplicateHostsEntry(let ref): return try duplicateHostsEntry(ref)
        case .deleteHostsEntries(let refs): return try deleteHostsEntries(refs)
        case .reapplyHostsFile:
            try hostsWrite { reapplyHostsFile() }
            return hostsFileStatusInfo()
        case .hostsFileStatus:
            refreshHostsFileState()
            return hostsFileStatusInfo()
        case .importHostsFile: return try importHostsFileCommand()
        case .readHostsFile:
            do {
                return TextResult(path: HostsFileWriter.hostsPath, text: try hostsWriter.read())
            } catch {
                throw ControlFailure(.failed, "Couldn't read /etc/hosts: \(error.localizedDescription)")
            }

        case .exportArchive(let includeConfigOnly):
            let stored = currentArchive()
            let configOnly = includeConfigOnly ? configOnlyHosts(besides: stored) : []
            var archive = stored
            archive.sshHosts += configOnly
            return ExportInfo(archive: archive, configOnly: Array(Set(configOnly.map(\.groupKey))).sorted())
        case .previewImport(let archive): return importPreview(archive)
        case .importArchive(let archive): return try importArchiveCommand(archive)

        case .configStatus: return configStatusInfo()
        case .importConfig:
            let result = try capturingErrors { importFromConfig() }
            return ActionResult("Imported \(plural(result.added, "host")) from \(configPath ?? ConfigPathStore.defaultSuggestion) (\(result.skipped) already present).",
                                added: result.added, skipped: result.skipped)
        case .linkInclude:
            if let message = linkInclude() { throw ControlFailure(.failed, message) }
            exportNow()
            return configStatusInfo()
        case .setConfigPath(let path): return try setConfigPath(path)
        case .setManagedPath(let path): return try setManagedPath(path)
        case .readConfig:
            let path = configPath ?? ConfigPathStore.defaultSuggestion
            return TextResult(path: path, text: try readText(path, missing: "No ssh config at \(path)."))
        case .readManagedFile:
            return TextResult(path: managedPath, text: try readText(managedPath,
                missing: "\(managedPath) hasn't been written yet. It appears once Sesh has a host."))

        case .showSettings: return settingsInfo()
        case .setTerminal(let ref): return try setTerminal(ref)
        case .setAppearance(let value):
            guard ["system", "light", "dark"].contains(value) else {
                throw ControlFailure(.invalid, "Appearance is system, light, or dark.")
            }
            appearancePreference = value
            return settingsInfo()
        case .resetSettings:
            resetPreferences()
            return settingsInfo()

        case .checkForUpdates: return await checkForUpdatesCommand()
        case .installUpdate: return await installUpdateCommand()
        }
    }

    // MARK: - SSH hosts

    private var allHosts: [HostEntry] {
        (try? context.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
    }

    /// Logical hosts in the sidebar's order (most recently updated first),
    /// default profile first within each.
    private func sidebarGroups() -> [[HostEntry]] {
        let hosts = allHosts
        let byAlias = Dictionary(uniqueKeysWithValues: hosts.map { ($0.host, $0) })
        return groups(from: hosts).map { group in group.members.compactMap { byAlias[$0.alias] } }
    }

    /// The members of the logical host `ref` names, default first.
    private func hostMembers(_ ref: String) throws -> [HostEntry] {
        let hosts = allHosts
        let candidates = hosts.map {
            ControlRefs.HostCandidate(alias: $0.host, groupKey: $0.groupName ?? $0.host, displayName: $0.displayName)
        }
        let key = try ControlRefs.hostKey(ref, in: candidates).get()
        let members = hosts.filter { ($0.groupName ?? $0.host) == key }
        return HostFormModel.members(of: members[0], allHosts: hosts)
    }

    /// The members of the logical host whose aliases include `alias`.
    private func hostMembers(containing alias: String) throws -> [HostEntry] {
        guard let entry = allHosts.first(where: { $0.host == alias }) else {
            throw ControlFailure(.notFound, "No host with alias '\(alias)'.")
        }
        return try hostMembers(entry.groupName ?? entry.host)
    }

    /// The alias `ref` names exactly, or the one alias it matches ignoring case.
    private func aliasEntry(_ ref: String) -> HostEntry? {
        let hosts = allHosts
        if let exact = hosts.first(where: { $0.host == ref }) { return exact }
        let loose = hosts.filter { $0.host.caseInsensitiveCompare(ref) == .orderedSame }
        return loose.count == 1 ? loose[0] : nil
    }

    private func profile(_ alias: String) throws -> HostEntry {
        guard let entry = aliasEntry(alias) else {
            throw ControlFailure(.notFound, "No profile with alias '\(alias)'. Aliases are listed by: sesh hosts show <host>")
        }
        return entry
    }

    private func hostInfo(_ members: [HostEntry]) -> HostInfo {
        let lead = members.first(where: \.isDefaultProfile) ?? members[0]
        let names = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
        let view = groups(from: members).first
        return HostInfo(
            key: lead.groupName ?? lead.host,
            name: view?.title ?? lead.host,
            hostname: lead.properties.first("HostName"),
            workspace: lead.workspaceID.flatMap { names[$0] },
            profiles: members.map { entry in
                ProfileInfo(alias: entry.host,
                            label: view?.members.first { $0.alias == entry.host }?.label ?? entry.host,
                            user: entry.properties.first("User"), port: entry.properties.first("Port"),
                            identityFile: entry.properties.first("IdentityFile"),
                            isDefault: members.count == 1 || entry.isDefaultProfile,
                            isConnectable: entry.isConnectable, sshCommand: entry.sshCommand,
                            options: entry.properties)
            })
    }

    private func addHost(_ spec: HostSpec) throws -> HostInfo {
        try validate(options: spec.options)
        var row = CredentialRow(user: spec.user, port: spec.port ?? "", identityFile: spec.identityFile ?? "",
                                extras: spec.options)
        row.port = try validPort(spec.port ?? "")
        var form = HostFormModel(displayName: spec.name, hostName: spec.hostname, rows: [row])
        if let workspace = spec.workspace { form.workspaceID = try workspaceID(workspace) }
        let before = sshAliases
        try save(form, editingGroup: nil)
        guard let alias = sshAliases.subtracting(before).first else {
            throw ControlFailure(.failed, "The host was saved but couldn't be found again.")
        }
        return hostInfo(try hostMembers(containing: alias))
    }

    private func editHost(_ ref: String, _ changes: HostChanges) throws -> HostInfo {
        guard !changes.isEmpty else { throw ControlFailure(.invalid, "Nothing to change. See: sesh hosts edit --help") }
        let members = try hostMembers(ref)
        var form = HostFormModel(editing: members[0], allHosts: allHosts)
        if let name = changes.name { form.displayName = name }
        if let hostname = changes.hostname { form.hostName = hostname }
        if let workspace = changes.workspace { form.workspaceID = workspace.isEmpty ? nil : try workspaceID(workspace) }
        try apply(changes.profile, to: &form.rows[0])
        return try saveEdit(form, members: members)
    }

    private func editProfile(_ alias: String, _ changes: ProfileChanges) throws -> HostInfo {
        guard !changes.isEmpty else { throw ControlFailure(.invalid, "Nothing to change. See: sesh profiles edit --help") }
        let entry = try profile(alias)
        let hosts = allHosts
        let members = HostFormModel.members(of: entry, allHosts: hosts)
        var form = HostFormModel(editing: entry, allHosts: hosts)
        guard let index = members.firstIndex(where: { $0 === entry }) else {
            throw ControlFailure(.failed, "Couldn't find '\(alias)' in its host.")
        }
        try apply(changes, to: &form.rows[index])
        return try saveEdit(form, members: members)
    }

    /// Saves an edit of `members`' group and returns the host as it ended up
    /// (a rename or a changed user can change its aliases).
    private func saveEdit(_ form: HostFormModel, members: [HostEntry]) throws -> HostInfo {
        let others = sshAliases.subtracting(members.map(\.host))
        try save(form, editingGroup: members[0].groupName ?? members[0].host)
        guard let alias = sshAliases.subtracting(others).first else {
            throw ControlFailure(.failed, "The host was saved but couldn't be found again.")
        }
        return hostInfo(try hostMembers(containing: alias))
    }

    private func save(_ form: HostFormModel, editingGroup group: String?) throws {
        if let message = try capturingErrors({ saveHostForm(form, editingGroup: group) }) {
            throw ControlFailure(.invalid, message)
        }
    }

    private func apply(_ changes: ProfileChanges, to row: inout CredentialRow) throws {
        try validate(options: changes.setOptions)
        if let user = changes.user {
            guard !user.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ControlFailure(.invalid, "A profile needs a user.")
            }
            row.user = user
        }
        if let port = changes.port { row.port = try validPort(port) }
        if let identityFile = changes.identityFile { row.identityFile = identityFile }
        let removed = Set(changes.removeOptions.map { $0.lowercased() } + changes.setOptions.map { $0.key.lowercased() })
        row.extras.removeAll { removed.contains($0.key.lowercased()) }
        row.extras += changes.setOptions
    }

    private func validate(options: [SSHProperty]) throws {
        for option in options {
            if HostFormData.coreKeys.contains(option.key.lowercased()) {
                throw ControlFailure(.invalid, "Set \(option.key) with its own flag, not as an option.")
            }
            if let problem = SSHOptionRules.problem(key: option.key, values: option.values) {
                throw ControlFailure(.invalid, problem)
            }
        }
    }

    private func validPort(_ port: String) throws -> String {
        let port = port.trimmingCharacters(in: .whitespaces)
        guard port.isEmpty || Int(port).map({ (1...65535).contains($0) }) == true else {
            throw ControlFailure(.invalid, "Port must be between 1 and 65535.")
        }
        return port
    }

    private func duplicateHost(_ ref: String) throws -> HostInfo {
        let source = try aliasEntry(ref) ?? hostMembers(ref)[0]
        do {
            return hostInfo([try duplicateHost(source)])
        } catch {
            throw ControlFailure(.failed, error.localizedDescription)
        }
    }

    private func deleteHosts(_ refs: [String]) throws -> ActionResult {
        let groups = try refs.map { try hostMembers($0) }
        let keys = Set(groups.map { $0[0].groupName ?? $0[0].host })
        do {
            let count = try deleteHosts(groupKeys: keys)
            return ActionResult("Deleted \(plural(keys.count, "host")) (\(plural(count, "alias", "aliases"))).", changed: keys.count)
        } catch {
            throw ControlFailure(.failed, error.localizedDescription)
        }
    }

    private func moveHosts(_ refs: [String], to workspace: String?) throws -> ActionResult {
        let id = try workspace.map { try workspaceID($0) }
        let groups = try refs.map { try hostMembers($0) }
        for members in groups {
            if let message = try capturingErrors({ move(groupDefaultAlias: members[0].host, toWorkspace: id) }) {
                throw ControlFailure(.failed, message)
            }
        }
        let name = id.flatMap { id in workspaces.first { $0.id == id }?.name } ?? "Default"
        return ActionResult("Moved \(plural(groups.count, "host")) to \(name).", changed: groups.count)
    }

    private func connect(_ ref: String, terminal ref2: String?) throws -> ActionResult {
        let entry = try aliasEntry(ref) ?? hostMembers(ref)[0]
        guard entry.isConnectable else {
            throw ControlFailure(.invalid, "'\(entry.host)' is a pattern, not a host you can open. Use: ssh <name>")
        }
        let terminal = try ref2.map { try self.terminal($0) } ?? preferredTerminal
        try capturingErrors { connect(entry, with: terminal) }
        return ActionResult("Opening \(entry.host) in \(terminal.name).")
    }

    // MARK: - Profiles

    private func addProfile(_ ref: String, label: String, user: String, identityFile: String?) throws -> HostInfo {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { throw ControlFailure(.invalid, "A profile needs a label.") }
        guard !user.trimmingCharacters(in: .whitespaces).isEmpty else { throw ControlFailure(.invalid, "A profile needs a user.") }
        guard ![label, user, identityFile ?? ""].contains(where: SSHOptionRules.hasLineBreak) else {
            throw ControlFailure(.invalid, "The label, user, and identity file can't contain line breaks.")
        }
        let base = try hostMembers(ref)[0]
        let identity = identityFile?.trimmingCharacters(in: .whitespaces)
        if let message = try capturingErrors({
            addProfile(to: base, label: label, user: user, identityFile: identity?.isEmpty == false ? identity : nil,
                       allHosts: allHosts)
        }) {
            throw ControlFailure(.failed, message)
        }
        return hostInfo(try hostMembers(containing: base.host))
    }

    private func removeProfile(_ alias: String) throws -> HostInfo {
        let entry = try profile(alias)
        let members = HostFormModel.members(of: entry, allHosts: allHosts)
        guard members.count > 1, let survivor = members.first(where: { $0 !== entry }) else {
            throw ControlFailure(.invalid, "'\(alias)' is the host's only profile. Delete the host instead: sesh hosts delete \(alias)")
        }
        if let message = try capturingErrors({ removeProfile(entry, groupMembers: members) }) {
            throw ControlFailure(.failed, message)
        }
        return hostInfo(try hostMembers(containing: survivor.host))
    }

    private func ungroup(_ ref: String) throws -> [HostInfo] {
        let members = try hostMembers(ref)
        guard members.count > 1 else { throw ControlFailure(.invalid, "'\(ref)' has only one profile.") }
        if let message = try capturingErrors({ ungroup(members) }) { throw ControlFailure(.failed, message) }
        return try members.map { hostInfo(try hostMembers(containing: $0.host)) }
    }

    // MARK: - Workspaces

    private func workspaceID(_ ref: String) throws -> UUID {
        try ControlRefs.workspaceID(ref, in: workspaces.map { (id: $0.id, name: $0.name) }).get()
    }

    private func workspace(_ ref: String) throws -> Workspace {
        let id = try workspaceID(ref)
        return workspaces.first { $0.id == id }!
    }

    private func workspaceInfos() -> [WorkspaceInfo] {
        let counts = Dictionary(grouping: sidebarGroups(), by: { $0[0].workspaceID }).mapValues(\.count)
        return workspaces.enumerated().map { index, ws in
            WorkspaceInfo(id: ws.id, name: ws.name, position: index + 1, hostCount: counts[ws.id] ?? 0)
        }
    }

    private func createWorkspaceCommand(_ name: String) throws -> [WorkspaceInfo] {
        try checkWorkspaceNameFree(name, besides: nil)
        if let message = try capturingErrors({ createWorkspace(name: name) }) { throw ControlFailure(.invalid, message) }
        return workspaceInfos()
    }

    private func renameWorkspaceCommand(_ ref: String, to name: String) throws -> [WorkspaceInfo] {
        let ws = try workspace(ref)
        try checkWorkspaceNameFree(name, besides: ws.id)
        if let message = try capturingErrors({ renameWorkspace(ws, to: name) }) { throw ControlFailure(.invalid, message) }
        return workspaceInfos()
    }

    private func checkWorkspaceNameFree(_ name: String, besides id: UUID?) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        if workspaces.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ControlFailure(.conflict, "A workspace named '\(name)' already exists.")
        }
    }

    private func deleteWorkspaceCommand(_ ref: String) throws -> ActionResult {
        let ws = try workspace(ref)
        let name = ws.name
        let moved = workspaceInfos().first { $0.id == ws.id }?.hostCount ?? 0
        if let message = try capturingErrors({ deleteWorkspace(ws) }) { throw ControlFailure(.failed, message) }
        return ActionResult("Deleted workspace \(name); its \(plural(moved, "host")) moved to Default.", changed: moved)
    }

    private func moveWorkspaceCommand(_ ref: String, _ placement: WorkspacePlacement) throws -> [WorkspaceInfo] {
        let ws = try workspace(ref)
        let message: String?
        switch placement {
        case .up: message = try capturingErrors { moveWorkspace(ws, up: true) }
        case .down: message = try capturingErrors { moveWorkspace(ws, up: false) }
        case .onto(let target):
            let targetID = try workspaceID(target)
            message = try capturingErrors { reorderWorkspace(ws.id, onto: targetID) }
        }
        if let message { throw ControlFailure(.failed, message) }
        return workspaceInfos()
    }

    // MARK: - /etc/hosts

    private func hostsEntry(_ ref: String) throws -> HostsFileEntry {
        let entries = hostsEntries
        let id = try ControlRefs.hostsEntryID(ref, in: entries.map { (id: $0.id, hostnames: $0.hostnames) }).get()
        return entries.first { $0.id == id }!
    }

    private func hostsEntryInfos() -> [HostsEntryInfo] {
        hostsEntries.enumerated().map { hostsEntryInfo($1, position: $0 + 1) }
    }

    private func hostsEntryInfo(_ entry: HostsFileEntry, position: Int? = nil) -> HostsEntryInfo {
        HostsEntryInfo(id: entry.id, ip: entry.ip, hostnames: entry.hostnames, note: entry.note,
                       isEnabled: entry.isEnabled, isOverridden: isOverridden(entry),
                       position: position ?? (hostsEntries.firstIndex { $0.id == entry.id } ?? 0) + 1)
    }

    private func hostsFileStatusInfo() -> HostsFileStatusInfo {
        let infos = hostsEntryInfos()
        return HostsFileStatusInfo(path: HostsFileWriter.hostsPath, inSync: !hostsOutOfSync, entryCount: infos.count,
                                   enabledCount: infos.filter(\.isEnabled).count,
                                   overridden: infos.filter(\.isOverridden))
    }

    /// Runs a hosts-file write, turning a dismissed password prompt and a
    /// failure (both reported quietly to the UI) into errors.
    private func hostsWrite(_ body: () -> Void) throws {
        let revision = hostsRevision
        try capturingErrors(body)
        if hostsRevision != revision { throw cancelledHostsWrite }
    }

    /// Maps a message from the hosts-file model calls to the right failure.
    private func hostsFailure(_ message: String) -> ControlFailure {
        message.hasPrefix("Cancelled") ? cancelledHostsWrite : ControlFailure(.failed, message)
    }

    private var cancelledHostsWrite: ControlFailure {
        ControlFailure(.cancelled, "The administrator password prompt was cancelled. /etc/hosts wasn't changed.")
    }

    private func addHostsEntry(ip: String, hostnames: [String], note: String?, enabled: Bool) throws -> HostsEntryInfo {
        if let message = HostsFile.validate(ip: ip, hostnames: hostnames, note: note) {
            throw ControlFailure(.invalid, message)
        }
        let before = Set(hostsEntries.map(\.id))
        if let message = try capturingErrors({
            saveHostsEntry(nil, ip: ip, hostnames: hostnames, note: note, isEnabled: enabled)
        }) {
            throw hostsFailure(message)
        }
        guard let entry = hostsEntries.first(where: { !before.contains($0.id) }) else {
            throw ControlFailure(.failed, "The entry was saved but couldn't be found again.")
        }
        return hostsEntryInfo(entry)
    }

    private func addHostsText(_ text: String) throws -> ActionResult {
        let parsed = HostsFile.parseBulk(text)
        if !parsed.invalid.isEmpty {
            let lines = parsed.invalid.map { "line \($0.number): \($0.text)" }.joined(separator: "; ")
            throw ControlFailure(.invalid, "Some lines aren't IP hostname… entries (\(lines)). Nothing was added.")
        }
        guard !parsed.lines.isEmpty else { throw ControlFailure(.invalid, "No entries in the text.") }
        let preview = previewHostsMerge(parsed.lines)
        if let message = try capturingErrors({ addHostsEntries(parsed.lines) }) { throw hostsFailure(message) }
        return ActionResult("Added \(plural(preview.added.count, "entry", "entries")) (\(preview.skipped) already present).",
                            added: preview.added.count, skipped: preview.skipped)
    }

    private func editHostsEntry(_ ref: String, _ changes: HostsEntryChanges) throws -> HostsEntryInfo {
        guard !changes.isEmpty else { throw ControlFailure(.invalid, "Nothing to change. See: sesh hosts-file edit --help") }
        let entry = try hostsEntry(ref)
        let ip = changes.ip ?? entry.ip
        let hostnames = changes.hostnames ?? entry.hostnames
        let note = changes.note.map { $0.isEmpty ? nil : $0 } ?? entry.note
        if let message = HostsFile.validate(ip: ip, hostnames: hostnames, note: note) {
            throw ControlFailure(.invalid, message)
        }
        if let message = try capturingErrors({
            saveHostsEntry(entry, ip: ip, hostnames: hostnames, note: note, isEnabled: entry.isEnabled)
        }) {
            throw hostsFailure(message)
        }
        return hostsEntryInfo(entry)
    }

    private func setHostsEntries(_ refs: [String], enabled: Bool) throws -> [HostsEntryInfo] {
        let entries = try refs.map { try hostsEntry($0) }
        if enabled, let clash = HostsFile.sharedHostname(in: entries.map(\.hostnames)) {
            throw ControlFailure(.invalid, "Two of those entries map \(clash), and only one can be on. Enable one of them.")
        }
        // One write for all of them, so one password prompt.
        let revision = hostsRevision
        if let message = try capturingErrors({ setHostsEntries(entries, enabled: enabled) }) {
            throw hostsFailure(message)
        }
        if hostsRevision != revision { throw cancelledHostsWrite }
        return hostsEntryInfos()
    }

    private func duplicateHostsEntry(_ ref: String) throws -> HostsEntryInfo {
        let entry = try hostsEntry(ref)
        let before = Set(hostsEntries.map(\.id))
        try hostsWrite { duplicateHostsEntry(entry) }
        guard let copy = hostsEntries.first(where: { !before.contains($0.id) }) else {
            throw ControlFailure(.failed, "The copy was saved but couldn't be found again.")
        }
        return hostsEntryInfo(copy)
    }

    private func deleteHostsEntries(_ refs: [String]) throws -> ActionResult {
        let ids = Set(try refs.map { try hostsEntry($0).id })
        try hostsWrite { deleteHostsEntries(ids) }
        return ActionResult("Deleted \(plural(ids.count, "entry", "entries")).", changed: ids.count)
    }

    private func importHostsFileCommand() throws -> ActionResult {
        let revision = hostsRevision
        let result = try capturingErrors { importFromHostsFile() }
        guard let result, hostsRevision == revision else { throw cancelledHostsWrite }
        return ActionResult("Imported \(plural(result.added, "entry", "entries")) from /etc/hosts (\(result.skipped) already present).",
                            added: result.added, skipped: result.skipped)
    }

    // MARK: - Export and import

    private func importPreview(_ archive: SeshArchive) -> ImportPreview {
        let mappings = hostsMappingKeys
        return ImportPreview(
            existingHosts: presentSSHGroups(in: archive).sorted(),
            existingHostsEntries: archive.hostsEntries.indices.filter { mappings.contains(archive.hostsEntries[$0].line.mappingKey) },
            configAliases: configAliases.sorted())
    }

    private func importArchiveCommand(_ archive: SeshArchive) throws -> ActionResult {
        // The CLI already checked the file; check again, since this is where it lands.
        do {
            _ = try SeshArchive.decode(archive.encoded())
        } catch SeshArchiveError.invalid(let reason) {
            throw ControlFailure(.invalid, reason)
        } catch {
            throw ControlFailure(.invalid, "That isn't a Sesh export.")
        }
        switch try capturingErrors({ importArchive(archive) }) {
        case .success(let summary): return ActionResult(summary)
        case .failure(let failure): throw hostsFailure(failure.message)
        }
    }

    // MARK: - ~/.ssh/config

    private func configStatusInfo() -> ConfigStatusInfo {
        ConfigStatusInfo(configPath: configPath, managedPath: managedPath, isLinked: managedFileActive)
    }

    private func setConfigPath(_ path: String) throws -> ConfigStatusInfo {
        if expandedPath(path) == expandedPath(managedPath) {
            throw ControlFailure(.invalid, "The config path can't be Sesh's managed file.")
        }
        if let message = saveConfigPath(path) { throw ControlFailure(.invalid, message) }
        return configStatusInfo()
    }

    /// Moves Sesh's managed file: writes it at the new path and points the
    /// Include there. The old file is left where it was.
    private func setManagedPath(_ path: String) throws -> ConfigStatusInfo {
        let trimmed: String
        switch ConfigPathStore.validateManaged(path, configPath: configPath ?? ConfigPathStore.defaultSuggestion) {
        case .failure(let message): throw ControlFailure(.invalid, message)
        case .success(let valid): trimmed = valid
        }
        // Keep the old path unless the file is written there, so exports
        // never head for a file the Include doesn't point at.
        let previous = managedPath
        managedPath = trimmed
        if let problem = writeManagedFile() {
            managedPath = previous
            throw ControlFailure(.failed, "Couldn't move the managed file to \(trimmed): \(problem)")
        }
        return configStatusInfo()
    }

    private func expandedPath(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    private func readText(_ path: String, missing: String) throws -> String {
        let expanded = expandedPath(path)
        guard FileManager.default.fileExists(atPath: expanded) else { throw ControlFailure(.notFound, missing) }
        do {
            return try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw ControlFailure(.failed, "Couldn't read \(path): \(error.localizedDescription)")
        }
    }

    // MARK: - Settings

    private func terminalInfo(_ terminal: Terminal) -> TerminalInfo {
        TerminalInfo(id: terminal.id, name: terminal.name, isSelected: terminal.id == preferredTerminal.id)
    }

    private func settingsInfo() -> SettingsInfo {
        refreshTerminals()
        return SettingsInfo(terminal: terminalInfo(preferredTerminal), terminals: selectableTerminals.map(terminalInfo),
                            appearance: appearancePreference, config: configStatusInfo())
    }

    /// The installed terminal `ref` names, by bundle id or by name.
    private func terminal(_ ref: String) throws -> Terminal {
        refreshTerminals()
        if let match = selectableTerminals.first(where: {
            $0.id.caseInsensitiveCompare(ref) == .orderedSame || $0.name.caseInsensitiveCompare(ref) == .orderedSame
        }) {
            return match
        }
        let names = selectableTerminals.map(\.name).joined(separator: ", ")
        throw ControlFailure(.notFound, "No installed terminal named '\(ref)'. Installed: \(names.isEmpty ? "none" : names).")
    }

    private func setTerminal(_ ref: String) throws -> SettingsInfo {
        preferredTerminalId = try terminal(ref).id
        return settingsInfo()
    }

    // MARK: - Updates

    private func checkForUpdatesCommand() async -> UpdateInfo {
        if !isInstallingUpdate { checkForUpdates(explicit: true) }
        let deadline = Date.now.addingTimeInterval(30)
        while updatePhase == .checking, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return updateInfo()
    }

    private func installUpdateCommand() async -> UpdateInfo {
        if availableUpdate == nil, !isInstallingUpdate { _ = await checkForUpdatesCommand() }
        guard let update = availableUpdate else { return updateInfo() }
        guard update.isInstallable else { return updateInfo() }
        installUpdate()
        return UpdateInfo(state: .installing, currentVersion: Self.appVersion, latestVersion: update.version,
                          isInstallable: true, releasePage: update.releasePage.absoluteString,
                          message: "Downloading \(update.version). Sesh restarts when it's installed.")
    }

    private func updateInfo() -> UpdateInfo {
        let current = Self.appVersion
        switch updatePhase {
        case .available(let update):
            return UpdateInfo(state: .available, currentVersion: current, latestVersion: update.version,
                              isInstallable: update.isInstallable, releasePage: update.releasePage.absoluteString,
                              message: update.isInstallable ? nil : "This release has no disk image to install; download it from the release page.")
        case .failed(let message):
            return UpdateInfo(state: .failed, currentVersion: current, message: message)
        case .downloading, .verifying, .preparing, .relaunching:
            return UpdateInfo(state: .installing, currentVersion: current)
        case .idle, .checking, .upToDate:
            return UpdateInfo(state: .upToDate, currentVersion: current)
        }
    }

    // MARK: - Status

    private func statusInfo() -> StatusInfo {
        refreshHostsFileState()
        let groups = sidebarGroups()
        return StatusInfo(appVersion: Self.appVersion, appPath: Bundle.main.bundlePath,
                          protocolVersion: ControlProtocol.version, hostCount: groups.count,
                          profileCount: groups.reduce(0) { $0 + $1.count }, workspaceCount: workspaces.count,
                          config: configStatusInfo(), hostsFile: hostsFileStatusInfo(),
                          terminal: terminalInfo(preferredTerminal), availableUpdate: availableUpdate?.version)
    }

    // MARK: - Helpers

    /// Runs `body` and turns a message it leaves in `pendingError` (how the
    /// model reports to the window's alert) into a thrown failure, putting
    /// back whatever the window was already showing.
    @discardableResult
    private func capturingErrors<T>(_ body: () throws -> T) throws -> T {
        let shown = pendingError
        pendingError = nil
        let value: T
        do {
            value = try body()
        } catch {
            pendingError = shown
            throw error
        }
        let message = pendingError
        pendingError = shown
        if let message { throw ControlFailure(.failed, message) }
        return value
    }

    private func plural(_ count: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : pluralForm ?? singular + "s")"
    }
}
