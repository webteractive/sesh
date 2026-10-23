import Foundation

public struct BackupManager {
    public let keepCount: Int

    public init(keepCount: Int = 20) {
        self.keepCount = keepCount
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Copies the config to `<config>.backup.<timestamp>` and prunes old backups.
    /// With `directory`, the backup goes to `<directory>/<basename>.backup.<timestamp>`
    /// instead — for files whose own directory isn't writable (e.g. /etc/hosts).
    @discardableResult
    public func backup(configPath: String, now: Date = .now, into directory: String? = nil) throws -> String {
        let expanded = (configPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: expanded])
        }
        if let directory, !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let base = backupBase(for: expanded, in: directory)
        let stamp = Self.formatter.string(from: now)
        var backupPath = base + ".backup." + stamp
        var suffix = 2
        // Two backups requested within the same second would otherwise collide
        // on the timestamp; append -2, -3, … until a free name is found instead
        // of clobbering the earlier backup's contents.
        while FileManager.default.fileExists(atPath: backupPath) {
            backupPath = base + ".backup." + stamp + "-\(suffix)"
            suffix += 1
        }
        // copyItem copies a symlinked config AS a symlink, making the "backup"
        // track the live target's content instead of snapshotting it. Resolve
        // to the real file first (same pattern as SSHConfigWriter.write).
        let source = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        try FileManager.default.copyItem(atPath: source, toPath: backupPath)
        try prune(configPath: expanded, in: directory)
        return backupPath
    }

    /// All backup paths for a config, newest first. Pass the same `directory`
    /// given to `backup(configPath:now:into:)` to list backups kept there.
    public func backupPaths(configPath: String, in directory: String? = nil) -> [String] {
        let expanded = (configPath as NSString).expandingTildeInPath
        let dir = directory ?? (expanded as NSString).deletingLastPathComponent
        let prefix = (expanded as NSString).lastPathComponent + ".backup."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) }
            .sorted(by: >) // timestamp format sorts lexically
            .map { dir + "/" + $0 }
    }

    /// `<directory>/<basename>` when backing up elsewhere, else the config path itself.
    private func backupBase(for expanded: String, in directory: String?) -> String {
        guard let directory else { return expanded }
        return (directory as NSString).appendingPathComponent((expanded as NSString).lastPathComponent)
    }

    private func prune(configPath: String, in directory: String?) throws {
        let paths = backupPaths(configPath: configPath, in: directory)
        for path in paths.dropFirst(keepCount) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}
