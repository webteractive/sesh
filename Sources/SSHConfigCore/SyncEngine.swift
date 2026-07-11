import Foundation
import SwiftData

public enum SyncAction: String, Sendable {
    case created, updated, addedToFile
}

public struct SyncItem: Equatable, Identifiable, Sendable {
    public var host: String
    public var action: SyncAction
    public var id: String { host + action.rawValue }

    public init(host: String, action: SyncAction) {
        self.host = host
        self.action = action
    }
}

public struct SyncEngine {
    private let parser = SSHConfigParser()
    private let writer = SSHConfigWriter()
    private let backups = BackupManager()

    public init() {}

    /// File → store. Upserts every parsed host; the file wins on differences.
    @MainActor
    public func syncFromFile(path: String, context: ModelContext) throws -> [SyncItem] {
        let fileHosts = parser.hosts(in: try parser.parseFile(at: path))
        guard !fileHosts.isEmpty else { return [] }
        let existing = try context.fetch(FetchDescriptor<HostEntry>())
        var byHost = Dictionary(uniqueKeysWithValues: existing.map { ($0.host, $0) })
        var items: [SyncItem] = []
        var seenPatterns = Set<String>()

        for fileHost in fileHosts {
            // ssh_config(5) and SSHConfigWriter both honor the first occurrence of a
            // repeated Host pattern within a single file; skip later duplicates so the
            // store doesn't end up mirroring the last stanza instead.
            guard seenPatterns.insert(fileHost.pattern).inserted else { continue }
            if let entry = byHost[fileHost.pattern] {
                if entry.properties.normalized != fileHost.properties.normalized {
                    entry.properties = fileHost.properties
                    entry.rawBlock = fileHost.rawBlock
                    entry.updatedAt = .now
                    items.append(SyncItem(host: fileHost.pattern, action: .updated))
                } else if entry.rawBlock != fileHost.rawBlock {
                    entry.rawBlock = fileHost.rawBlock
                }
            } else {
                let entry = HostEntry(host: fileHost.pattern,
                                      properties: fileHost.properties,
                                      rawBlock: fileHost.rawBlock)
                context.insert(entry)
                byHost[fileHost.pattern] = entry
                items.append(SyncItem(host: fileHost.pattern, action: .created))
            }
        }
        try context.save()
        return items
    }

    /// Store → file. Backs up first (when the file exists), preserves non-host
    /// segments, drops file hosts missing from the store, appends store-only hosts.
    @MainActor
    public func syncToFile(path: String, context: ModelContext) throws {
        let expanded = (path as NSString).expandingTildeInPath
        let entries = try context
            .fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.createdAt)]))
            .map { RenderableHost(host: $0.host, properties: $0.properties) }
        let segments = try parser.parseFile(at: expanded)
        if FileManager.default.fileExists(atPath: expanded) {
            try backups.backup(configPath: expanded)
        }
        try writer.write(writer.renderFile(segments: segments, entries: entries), toPath: expanded)
    }

    /// Both directions, Laravel semantics: file wins on shared hosts, then the
    /// merged store is written back (store-only hosts reported as addedToFile).
    @MainActor
    public func syncBoth(path: String, context: ModelContext) throws -> [SyncItem] {
        let filePatterns = Set(parser.hosts(in: try parser.parseFile(at: path)).map(\.pattern))
        var items = try syncFromFile(path: path, context: context)
        let all = try context.fetch(FetchDescriptor<HostEntry>())
        for entry in all where !filePatterns.contains(entry.host) {
            items.append(SyncItem(host: entry.host, action: .addedToFile))
        }
        try syncToFile(path: path, context: context)
        return items
    }
}
