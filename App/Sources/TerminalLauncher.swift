import AppKit
import Foundation
import SSHConfigCore

/// Executes LaunchPlans. Detection and launching live here (AppKit); the
/// registry data itself is in Core.
@MainActor
struct TerminalLauncher {
    enum LaunchError: LocalizedError {
        case notInstalled(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled(let name): "\(name) is not installed."
            }
        }
    }

    /// A throwaway ssh:// URL used only to probe which installed apps register
    /// the scheme — its host is irrelevant, nothing is ever opened with it.
    private static let sshProbeURL = URL(string: "ssh://probe")!

    /// The picker's contents, derived from what's installed: System Default,
    /// then every app that registers the `ssh://` scheme (deduped by bundle id,
    /// ordered by `TerminalRegistry`). No terminal is hardcoded — installing a
    /// new ssh://-handling terminal makes it appear automatically.
    func detectInstalled() -> [Terminal] {
        var seen = Set<String>()
        var discovered: [Terminal] = []
        for url in NSWorkspace.shared.urlsForApplications(toOpen: Self.sshProbeURL) {
            guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
            let fallback = FileManager.default.displayName(atPath: url.path)
            discovered.append(Terminal(id: id,
                                       name: TerminalRegistry.displayName(forBundleId: id, fallback: fallback),
                                       launchPlan: .sshURL))
        }
        return [TerminalRegistry.systemDefault] + TerminalRegistry.sortForDisplay(discovered)
    }

    /// Opens an already-built ssh:// URL with the chosen handler. Async open
    /// failures are reported via onAsyncError on the main actor.
    func open(_ url: URL, with terminal: Terminal,
              onAsyncError: @escaping @MainActor @Sendable (String) -> Void) throws {
        switch terminal.launchPlan {
        case .systemDefault:
            NSWorkspace.shared.open(url)
        case .sshURL:
            guard let app = appURL(for: terminal.id) else {
                throw LaunchError.notInstalled(terminal.name)
            }
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                Task { @MainActor in onAsyncError("Couldn't open \(terminal.name): \(error.localizedDescription)") }
            }
        }
    }

    /// Resolves the app to launch for a bundle id, preferring the copy in
    /// `/Applications` when several are registered (dev builds in DerivedData
    /// or build folders otherwise shadow the real install).
    private func appURL(for bundleId: String) -> URL? {
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: Self.sshProbeURL)
            .filter { Bundle(url: $0)?.bundleIdentifier == bundleId }
        return candidates.first { $0.path.hasPrefix("/Applications/") }
            ?? candidates.first
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }
}
