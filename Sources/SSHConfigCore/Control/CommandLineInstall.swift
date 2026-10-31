import Foundation

/// Putting `sesh` on the PATH: a symlink in /usr/local/bin to the copy inside
/// Sesh.app, so it updates with the app.
public enum CommandLineInstall {
    public static let linkPath = "/usr/local/bin/sesh"

    public enum State: Equatable, Sendable {
        /// The link points at this app's copy.
        case installed
        case notInstalled
        /// A link to another copy, e.g. a Sesh.app that has since moved.
        case linkedElsewhere(String)
        /// A real file is in the way; Sesh won't replace it.
        case blocked
    }

    public static func helperPath(inApp appPath: String) -> String {
        (appPath as NSString).appendingPathComponent("Contents/Helpers/sesh")
    }

    public static func state(link: String = linkPath, target: String) -> State {
        let files = FileManager.default
        if let destination = try? files.destinationOfSymbolicLink(atPath: link) {
            return destination == target ? .installed : .linkedElsewhere(destination)
        }
        return files.fileExists(atPath: link) ? .blocked : .notInstalled
    }

    /// AppleScript that, as root, creates the link's folder and points `link`
    /// at `target`, replacing an older link but never a real file (that
    /// fails with exit status 3). Both paths are passed quoted, never as code.
    public static func privilegedLinkScript(target: String, link: String = linkPath) -> String {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return """
        set t to quoted form of \(literal(target))
        set l to quoted form of \(literal(link))
        set d to quoted form of \(literal((link as NSString).deletingLastPathComponent))
        do shell script "/bin/mkdir -p " & d & " && { [ ! -e " & l & " ] || [ -L " & l & " ] || exit 3; } && \
        /bin/ln -sfn " & t & " " & l with administrator privileges
        """
    }
}
