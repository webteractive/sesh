import Foundation
import SSHConfigCore

enum HostsWriteError: Error {
    /// The user dismissed the administrator password prompt.
    case cancelled
    case failed(String)
}

/// Reads /etc/hosts directly (it's world-readable) and writes it as root via
/// the standard macOS administrator prompt. macOS caches that authorization
/// for a few minutes per app, so a burst of toggles asks once.
@MainActor
struct HostsFileWriter {
    static let hostsPath = "/etc/hosts"

    func read() throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.hostsPath))
        guard let text = String(data: data, encoding: .utf8) else { throw HostsFileError.notUTF8 }
        return text
    }

    /// Replaces /etc/hosts with `contents`, then flushes the DNS cache. The
    /// script (`HostsFile.privilegedWriteScript`) is fixed text plus the
    /// quoted paths of an app-generated temp file and the real hosts file —
    /// entry text never reaches the root shell.
    func write(_ contents: String) throws {
        let dir = URL.applicationSupportDirectory.appending(path: "Sesh", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appending(path: "hosts.pending-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: Data(contents.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HostsWriteError.failed("Couldn't stage the new hosts file.")
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        // /etc is a symlink to /private/etc; stage and rename in the real directory.
        let target = URL(fileURLWithPath: Self.hostsPath).resolvingSymlinksInPath().path
        let source = HostsFile.privilegedWriteScript(stagedPath: temp.path, targetPath: target, ownerUID: getuid())
        guard let script = NSAppleScript(source: source) else {
            throw HostsWriteError.failed("Couldn't prepare the hosts file update.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { throw HostsWriteError.cancelled }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            throw HostsWriteError.failed("Couldn't update /etc/hosts: \(message)")
        }
    }
}
