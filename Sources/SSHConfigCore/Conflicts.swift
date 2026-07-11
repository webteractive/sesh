import Foundation
import SwiftData

public struct Conflict: Equatable, Identifiable, Sendable {
    public enum Source: String, Sendable {
        case both   // exists in both but properties differ
        case store  // store-only
        case file   // file-only
    }

    public var host: String
    public var source: Source
    public var fileProperties: [SSHProperty]?
    public var storeProperties: [SSHProperty]?
    public var id: String { host + source.rawValue }

    public init(host: String, source: Source,
                fileProperties: [SSHProperty]?, storeProperties: [SSHProperty]?) {
        self.host = host
        self.source = source
        self.fileProperties = fileProperties
        self.storeProperties = storeProperties
    }
}

public struct ConflictDetector {
    private let parser = SSHConfigParser()

    public init() {}

    @MainActor
    public func detect(path: String, context: ModelContext) throws -> [Conflict] {
        let fileHosts = parser.hosts(in: try parser.parseFile(at: path))
        let filePatterns = Set(fileHosts.map(\.pattern))
        let storeEntries = try context.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.host)]))
        let storeByHost = Dictionary(uniqueKeysWithValues: storeEntries.map { ($0.host, $0) })
        var conflicts: [Conflict] = []
        var seenPatterns = Set<String>()

        for fileHost in fileHosts {
            // ssh_config(5) and SSHConfigWriter both honor the first occurrence of a
            // repeated Host pattern within a single file; skip later duplicates so
            // they don't produce a second Conflict with the same Identifiable id.
            guard seenPatterns.insert(fileHost.pattern).inserted else { continue }
            if let entry = storeByHost[fileHost.pattern] {
                if entry.properties.normalized != fileHost.properties.normalized {
                    conflicts.append(Conflict(host: fileHost.pattern, source: .both,
                                              fileProperties: fileHost.properties,
                                              storeProperties: entry.properties))
                }
            } else {
                conflicts.append(Conflict(host: fileHost.pattern, source: .file,
                                          fileProperties: fileHost.properties,
                                          storeProperties: nil))
            }
        }
        for entry in storeEntries where !filePatterns.contains(entry.host) {
            conflicts.append(Conflict(host: entry.host, source: .store,
                                      fileProperties: nil,
                                      storeProperties: entry.properties))
        }
        return conflicts
    }
}

public struct ConflictResolver {
    public init() {}

    public enum ResolverError: LocalizedError {
        case hostNotFound(String)
        case hostAlreadyExists(String)
        public var errorDescription: String? {
            switch self {
            case .hostNotFound(let host): return "Host '\(host)' not found."
            case .hostAlreadyExists(let host): return "A host named '\(host)' already exists."
            }
        }
    }

    /// Laravel's ResolveSshConfigConflictAction: rename in place, or keep both
    /// by duplicating under the new name.
    @MainActor
    public func rename(host: String, to newHost: String, updateExisting: Bool,
                       context: ModelContext) throws {
        let all = try context.fetch(FetchDescriptor<HostEntry>())
        guard let existing = all.first(where: { $0.host == host }) else {
            throw ResolverError.hostNotFound(host)
        }
        // HostEntry.host is @Attribute(.unique); SwiftData silently upserts on
        // collision instead of failing, so guard explicitly before renaming or
        // duplicating into a name another entry already owns. Renaming a host
        // to its own current name remains a no-op success.
        if all.contains(where: { $0 !== existing && $0.host == newHost }) {
            throw ResolverError.hostAlreadyExists(newHost)
        }
        if updateExisting {
            existing.host = newHost
            existing.updatedAt = .now
        } else {
            context.insert(HostEntry(host: newHost,
                                     properties: existing.properties,
                                     rawBlock: existing.rawBlock))
        }
        try context.save()
    }

    /// Overwrite (or create) the store entry with the file's version.
    @MainActor
    public func acceptFileVersion(_ conflict: Conflict, context: ModelContext) throws {
        guard let fileProps = conflict.fileProperties else { return }
        let all = try context.fetch(FetchDescriptor<HostEntry>())
        if let existing = all.first(where: { $0.host == conflict.host }) {
            existing.properties = fileProps
            existing.updatedAt = .now
        } else {
            context.insert(HostEntry(host: conflict.host, properties: fileProps, rawBlock: nil))
        }
        try context.save()
    }
}
