/// A terminal emulator the app knows how to open an ssh session in.
public struct Terminal: Equatable, Identifiable, Sendable {
    public let id: String        // bundle id, or TerminalRegistry.systemDefaultId
    public let name: String
    public let launchPlan: LaunchPlan

    public init(id: String, name: String, launchPlan: LaunchPlan) {
        self.id = id
        self.name = name
        self.launchPlan = launchPlan
    }
}

public enum LaunchPlan: Equatable, Sendable {
    case systemDefault   // NSWorkspace.open(ssh://…) — whatever handles the scheme
    case sshURL          // open ssh://… WITH this specific ssh://-registering app
}

/// Display metadata for the terminal picker. The *membership* of the list is
/// discovered at runtime (App layer asks LaunchServices which installed apps
/// register the `ssh://` scheme) — this enum only decides how those apps are
/// named and ordered, so no bundle id has to be hardcoded to detect a terminal.
public enum TerminalRegistry {
    public static let systemDefaultId = "system-default"

    /// The synthetic "let macOS decide" entry, always offered and pinned first.
    public static let systemDefault = Terminal(
        id: systemDefaultId, name: "System Default", launchPlan: .systemDefault)

    /// Well-known terminals sort to the top in this order; anything else
    /// discovered follows, alphabetically by name.
    static let preferredOrder = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.webteractive.zetty",
    ]

    /// Prettier names for apps whose bundle display name reads badly in a menu
    /// (e.g. the "zetty.app" bundle → "Zetty").
    static let nameOverrides = [
        "co.webteractive.zetty": "Zetty",
        "dev.warp.Warp-Stable": "Warp",
    ]

    /// The menu name for a discovered app: an override when we have one, else
    /// the app's own display name.
    public static func displayName(forBundleId id: String, fallback: String) -> String {
        nameOverrides[id] ?? fallback
    }

    /// Orders discovered `.sshURL` terminals: known ones first (in
    /// `preferredOrder`), the rest alphabetically. Callers prepend
    /// `systemDefault` themselves.
    public static func sortForDisplay(_ terminals: [Terminal]) -> [Terminal] {
        terminals.sorted { a, b in
            switch (preferredOrder.firstIndex(of: a.id), preferredOrder.firstIndex(of: b.id)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}
