import Foundation

/// Native analog of the Laravel settings table: the config path in UserDefaults.
public struct ConfigPathStore {
    public static let key = "sshConfigPath"
    public static let defaultSuggestion = "~/.ssh/config"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var path: String? {
        get { defaults.string(forKey: Self.key) }
        nonmutating set {
            if let newValue {
                defaults.set((newValue as NSString).expandingTildeInPath, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    /// Trim + expand ~; require absolute path inside ~/.ssh with an
    /// existing parent directory. Sesh reads this file and adds its Include
    /// line to it, so it's kept to where ssh's own config lives.
    public static func validate(_ raw: String, home: String = NSHomeDirectory()) -> PathValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure("Config path is required.") }
        guard !SSHOptionRules.hasLineBreak(trimmed) else { return .failure("Config path can't contain line breaks.") }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failure("Config path must be absolute (start with / or ~).")
        }
        guard isInSSHDirectory(expanded, home: home) else {
            return .failure("Config path must be inside ~/.ssh.")
        }
        // ~/.ssh also holds keys: Sesh would show this file and add a line
        // to it, so a private key is never accepted as the config.
        if let data = FileManager.default.contents(atPath: expanded),
           data.range(of: Data("PRIVATE KEY-----".utf8)) != nil {
            return .failure("That's a private key, not an ssh config.")
        }
        let dir = (expanded as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return .failure("Directory does not exist: \(dir)")
        }
        return .success(expanded)
    }

    /// Checks a managed file path: inside ~/.ssh, not the config itself, and
    /// free of spaces and line breaks, since it's written into the config's
    /// `Include` line. Returns the trimmed path or why it can't be used.
    public static func validateManaged(_ raw: String, configPath: String,
                                       home: String = NSHomeDirectory()) -> PathValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure("Managed file path is required.") }
        guard !trimmed.contains(where: \.isWhitespace), !SSHOptionRules.hasLineBreak(trimmed) else {
            return .failure("Managed file path can't contain spaces or line breaks.")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard isInSSHDirectory(expanded, home: home) else {
            return .failure("Managed file path must be inside ~/.ssh.")
        }
        guard (expanded as NSString).standardizingPath
                != ((configPath as NSString).expandingTildeInPath as NSString).standardizingPath else {
            return .failure("Managed file path can't be your main ~/.ssh/config.")
        }
        return .success(trimmed)
    }

    private static func isInSSHDirectory(_ expanded: String, home: String) -> Bool {
        let ssh = ((home as NSString).appendingPathComponent(".ssh") as NSString).standardizingPath + "/"
        return (expanded as NSString).standardizingPath.hasPrefix(ssh)
    }
}

/// Validation outcome (String payloads on both sides, so Result<_, Error> doesn't fit).
public enum PathValidation: Equatable {
    case success(String)
    case failure(String)
}
