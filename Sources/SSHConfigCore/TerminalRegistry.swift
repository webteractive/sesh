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

public enum TerminalRegistry {
    public static let systemDefaultId = "system-default"

    public static let known: [Terminal] = [
        Terminal(id: systemDefaultId, name: "System Default", launchPlan: .systemDefault),
        Terminal(id: "com.apple.Terminal", name: "Terminal", launchPlan: .sshURL),
        Terminal(id: "com.googlecode.iterm2", name: "iTerm2", launchPlan: .sshURL),
        Terminal(id: "dev.warp.Warp-Stable", name: "Warp", launchPlan: .sshURL),
        Terminal(id: "dev.more.zetty", name: "Zetty", launchPlan: .sshURL),
    ]

    public static func terminal(withId id: String) -> Terminal? { known.first { $0.id == id } }
}
