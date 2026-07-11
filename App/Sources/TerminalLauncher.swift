import AppKit
import Foundation
import SSHConfigCore

/// Executes LaunchPlans. Detection and launching live here (AppKit); the
/// registry data itself is in Core.
@MainActor
struct TerminalLauncher {
    enum LaunchError: LocalizedError {
        case badHost(String)
        case notInstalled(String)

        var errorDescription: String? {
            switch self {
            case .badHost(let host): "'\(host)' isn't a safe host alias to launch (letters, numbers, dots, underscores, and hyphens only)."
            case .notInstalled(let name): "\(name) is not installed (or its CLI is missing)."
            }
        }
    }

    static let zettyCLICandidates = [
        "/opt/homebrew/bin/zetty",
        "/usr/local/bin/zetty",
        NSHomeDirectory() + "/.local/bin/zetty",
    ]

    func detectInstalled() -> [Terminal] {
        TerminalRegistry.known.filter { terminal in
            switch terminal.launchPlan {
            case .systemDefault:
                true
            case .zettyCLI:
                appURL(for: terminal.id) != nil && zettyCLIPath() != nil
            case .sshURL, .openArgs:
                appURL(for: terminal.id) != nil
            }
        }
    }

    /// - Parameter onAsyncError: called (on the main actor) if launching
    ///   succeeds synchronously but fails later, asynchronously — e.g.
    ///   NSWorkspace's completion handler reports an error, or the detached
    ///   zetty task can't create/address a pane. Synchronous failures
    ///   (badHost/notInstalled) are reported via `throw` instead.
    func launch(_ terminal: Terminal, host: String, onAsyncError: @escaping @MainActor @Sendable (String) -> Void) throws {
        guard HostValidation.isSafeToLaunch(host) else {
            throw LaunchError.badHost(host)
        }
        guard let url = URL(string: "ssh://\(host)") else {
            throw LaunchError.badHost(host)
        }
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
                Task { @MainActor in
                    onAsyncError("Couldn't open \(terminal.name): \(error.localizedDescription)")
                }
            }
        case .openArgs:
            guard let app = appURL(for: terminal.id),
                  let args = TerminalRegistry.arguments(for: terminal.launchPlan, host: host) else {
                throw LaunchError.notInstalled(terminal.name)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = args
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                guard let error else { return }
                Task { @MainActor in
                    onAsyncError("Couldn't open \(terminal.name): \(error.localizedDescription)")
                }
            }
        case .zettyCLI:
            guard let cli = zettyCLIPath() else {
                throw LaunchError.notInstalled("Zetty CLI")
            }
            // Open Zetty's project-less scratch terminal and run ssh there.
            // `zetty scratch` prints "opened" (not a pane id) and focuses the
            // new scratch pane, so we resolve that pane's id from status --json
            // before sending. zetty needs ~1–2 s for the shell to come up.
            Task.detached {
                do {
                    _ = try Self.run(cli, ["scratch"])
                } catch {
                    await MainActor.run { onAsyncError("Couldn't open Zetty scratch: \(error.localizedDescription)") }
                    return
                }
                try? await Task.sleep(for: .seconds(1.5))
                let sendArgs: [String]
                if let pane = Self.scratchPaneId(cli) {
                    sendArgs = ["send", "--pane", pane, "ssh -- \(host)", "--enter"]
                } else {
                    // Couldn't resolve the scratch pane id — fall back to the
                    // focused pane (the scratch we just opened is focused).
                    sendArgs = ["send", "ssh -- \(host)", "--enter"]
                }
                do {
                    _ = try Self.run(cli, sendArgs)
                } catch {
                    await MainActor.run { onAsyncError("Couldn't send to Zetty scratch: \(error.localizedDescription)") }
                }
            }
        }
    }

    private func appURL(for bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    func zettyCLIPath() -> String? {
        Self.zettyCLICandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The focused pane of Zetty's "scratch" project (the one `zetty scratch`
    /// just opened), read from `status --json`. Falls back to the project's
    /// last pane, then nil if there's no scratch section.
    nonisolated private static func scratchPaneId(_ cli: String) -> String? {
        guard let out = try? run(cli, ["status", "--json"]),
              let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [[String: Any]] else { return nil }

        for project in projects where (project["name"] as? String)?.lowercased() == "scratch" {
            let panes = (project["tabs"] as? [[String: Any]] ?? [])
                .flatMap { ($0["panes"] as? [[String: Any]]) ?? [] }
            if let focused = panes.first(where: { ($0["isFocused"] as? Bool) == true }),
               let id = focused["id"] as? String {
                return id
            }
            if let id = panes.last?["id"] as? String {
                return id
            }
        }
        return nil
    }

    nonisolated private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
