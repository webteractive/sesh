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
    case systemDefault           // NSWorkspace.open(ssh://host) — whatever handles the scheme
    case sshURL                  // open ssh://host WITH this specific app
    case openArgs([String])     // launch the app with argv; "%h" is replaced by the host alias
    case zettyCLI                // zetty new-tab → send "ssh host" --enter
}

public enum TerminalRegistry {
    public static let systemDefaultId = "system-default"

    public static let known: [Terminal] = [
        Terminal(id: systemDefaultId, name: "System Default", launchPlan: .systemDefault),
        Terminal(id: "com.apple.Terminal", name: "Terminal", launchPlan: .sshURL),
        Terminal(id: "com.googlecode.iterm2", name: "iTerm2", launchPlan: .sshURL),
        Terminal(id: "dev.warp.Warp-Stable", name: "Warp", launchPlan: .sshURL),
        Terminal(id: "com.mitchellh.ghostty", name: "Ghostty", launchPlan: .openArgs(["-e", "ssh", "--", "%h"])),
        Terminal(id: "org.alacritty", name: "Alacritty", launchPlan: .openArgs(["-e", "ssh", "--", "%h"])),
        Terminal(id: "net.kovidgoyal.kitty", name: "kitty", launchPlan: .openArgs(["ssh", "--", "%h"])),
        Terminal(id: "com.github.wez.wezterm", name: "WezTerm", launchPlan: .openArgs(["start", "--", "ssh", "--", "%h"])),
        Terminal(id: "dev.more.zetty", name: "Zetty", launchPlan: .zettyCLI),
    ]

    public static func terminal(withId id: String) -> Terminal? {
        known.first { $0.id == id }
    }

    /// Concrete argv for a host — only .openArgs plans expand; others are
    /// handled wholesale by the launcher.
    public static func arguments(for plan: LaunchPlan, host: String) -> [String]? {
        guard case .openArgs(let template) = plan else { return nil }
        return template.map { $0 == "%h" ? host : $0 }
    }
}
