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
    @discardableResult
    public func backup(configPath: String, now: Date = .now) throws -> String {
        let expanded = (configPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: expanded])
        }
        let stamp = Self.formatter.string(from: now)
        var backupPath = expanded + ".backup." + stamp
        var suffix = 2
        // Two backups requested within the same second would otherwise collide
        // on the timestamp; append -2, -3, … until a free name is found instead
        // of clobbering the earlier backup's contents.
        while FileManager.default.fileExists(atPath: backupPath) {
            backupPath = expanded + ".backup." + stamp + "-\(suffix)"
            suffix += 1
        }
        // copyItem copies a symlinked config AS a symlink, making the "backup"
        // track the live target's content instead of snapshotting it. Resolve
        // to the real file first (same pattern as SSHConfigWriter.write).
        let source = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        try FileManager.default.copyItem(atPath: source, toPath: backupPath)
        try prune(configPath: expanded)
        return backupPath
    }

    /// All backup paths for a config, newest first.
    public func backupPaths(configPath: String) -> [String] {
        let expanded = (configPath as NSString).expandingTildeInPath
        let dir = (expanded as NSString).deletingLastPathComponent
        let prefix = (expanded as NSString).lastPathComponent + ".backup."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) }
            .sorted(by: >) // timestamp format sorts lexically
            .map { dir + "/" + $0 }
    }

    private func prune(configPath: String) throws {
        let paths = backupPaths(configPath: configPath)
        for path in paths.dropFirst(keepCount) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}
