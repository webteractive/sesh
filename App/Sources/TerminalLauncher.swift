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

    func detectInstalled() -> [Terminal] {
        TerminalRegistry.known.filter { terminal in
            switch terminal.launchPlan {
            case .systemDefault: true
            case .sshURL: appURL(for: terminal.id) != nil
            }
        }
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

    private func appURL(for bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }
}
