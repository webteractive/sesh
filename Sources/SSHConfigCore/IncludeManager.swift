import Foundation

/// Links the managed file into ~/.ssh/config with a single idempotent Include
/// line, never touching existing blocks.
public struct IncludeManager {
    private let backups = BackupManager()

    public init() {}

    public func includeLine(managedPath: String) -> String { "Include \(managedPath)" }

    /// Decodes raw config bytes for searching only — never for rewriting.
    /// Mirrors `SSHConfigParser.parseFile`'s UTF-8 → isoLatin1 fallback:
    /// isoLatin1 decodes any byte sequence, so this only returns nil for a
    /// file that couldn't be read at all (e.g. missing).
    private func decodedForSearch(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func containsIncludeLine(_ text: String, line: String) -> Bool {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == line }
    }

    public func hasInclude(managedPath: String, configPath: String) -> Bool {
        let expanded = (configPath as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
              let text = decodedForSearch(data) else { return false }
        return containsIncludeLine(text, line: includeLine(managedPath: managedPath))
    }

    /// Returns true if it added the line, false if it was already present.
    ///
    /// Byte-preserving and encoding-agnostic: the include line is only ever
    /// prepended to the file's original, untouched bytes — never decoded to
    /// a `String` and re-encoded. That matters because a non-UTF-8 config
    /// (e.g. legacy latin-1) previously decoded to `nil` via `try?
    /// String(contentsOfFile:encoding: .utf8)`, which the old code coalesced
    /// to `""`, making the "already present?" check pass on an empty string
    /// and writing ONLY the Include line — destroying the user's config. By
    /// working on raw `Data` throughout, a decode failure can no longer turn
    /// "unreadable as UTF-8" into "safe to overwrite".
    @discardableResult
    public func ensureInclude(managedPath: String, configPath: String) throws -> Bool {
        let expanded = (configPath as NSString).expandingTildeInPath
        let line = includeLine(managedPath: managedPath)
        let fm = FileManager.default

        let exists = fm.fileExists(atPath: expanded)
        let originalData = exists ? ((try? Data(contentsOf: URL(fileURLWithPath: expanded))) ?? Data()) : Data()

        // Only treat the include as "already present" if the file both
        // exists and decodes (UTF-8 or isoLatin1 — the latter accepts any
        // byte sequence, so this is effectively "file exists and is
        // non-empty"). If it exists but somehow decodes as neither, fall
        // through to the prepend path below rather than risk treating it as
        // present and silently skipping the include.
        if exists, let text = decodedForSearch(originalData), containsIncludeLine(text, line: line) {
            return false
        }

        if exists {
            try backups.backup(configPath: expanded)   // backup before editing
        }

        // Include at the top so managed aliases resolve regardless of any
        // `Host *` defaults later in the user's file. Prepend to the
        // ORIGINAL bytes rather than any decoded representation, so the
        // user's exact bytes/encoding survive untouched.
        let prefix = originalData.isEmpty ? line + "\n" : line + "\n\n"
        let newData = Data(prefix.utf8) + originalData

        try SSHConfigWriter().writeData(newData, toPath: expanded)
        return true
    }
}
