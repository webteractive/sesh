import Foundation

/// Links the managed file into ~/.ssh/config with a single idempotent Include
/// line, never touching existing blocks.
public struct IncludeManager {
    private let backups = BackupManager()

    public init() {}

    public func includeLine(managedPath: String) -> String { "Include \(managedPath)" }

    public func hasInclude(managedPath: String, configPath: String) -> Bool {
        let expanded = (configPath as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else { return false }
        let line = includeLine(managedPath: managedPath)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == line }
    }

    /// Returns true if it added the line, false if it was already present.
    @discardableResult
    public func ensureInclude(managedPath: String, configPath: String) throws -> Bool {
        let expanded = (configPath as NSString).expandingTildeInPath
        let line = includeLine(managedPath: managedPath)

        let existing = (try? String(contentsOfFile: expanded, encoding: .utf8)) ?? ""
        if existing.split(separator: "\n", omittingEmptySubsequences: false)
            .contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) {
            return false
        }
        if FileManager.default.fileExists(atPath: expanded) {
            try backups.backup(configPath: expanded)   // backup before editing
        } else {
            let dir = (expanded as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: dir) {
                try FileManager.default.createDirectory(atPath: dir,
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        // Include at the top so managed aliases resolve regardless of any
        // `Host *` defaults later in the user's file.
        let body = existing.isEmpty ? line + "\n" : line + "\n\n" + existing
        try body.write(toFile: expanded, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expanded)
        return true
    }
}
