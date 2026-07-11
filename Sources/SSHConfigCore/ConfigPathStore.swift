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

    /// Trim + expand ~; require absolute path with an existing parent directory.
    public static func validate(_ raw: String) -> PathValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure("Config path is required.") }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failure("Config path must be absolute (start with / or ~).")
        }
        let dir = (expanded as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return .failure("Directory does not exist: \(dir)")
        }
        return .success(expanded)
    }
}

/// Validation outcome (String payloads on both sides, so Result<_, Error> doesn't fit).
public enum PathValidation: Equatable {
    case success(String)
    case failure(String)
}
