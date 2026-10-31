import Darwin
import Foundation
import SSHConfigCore

/// Sends requests to the running Sesh app, starting it in the background
/// first when it isn't running.
enum Client {
    static func send<Result: Decodable>(_ command: ControlCommand, as: Result.Type = Result.self) throws -> Result {
        let request = try ControlProtocol.encoder().encode(ControlRequest(command))
        let reply: Data
        do {
            reply = try exchange(request)
        } catch ControlSocketError.unreachable {
            try launchApp()
            do {
                reply = try exchange(request)
            } catch ControlSocketError.unreachable {
                throw CLIError.unreachable("Sesh started but stopped answering. Try again.")
            }
        }
        let response: ControlResponse<Result>
        do {
            response = try ControlProtocol.decoder().decode(ControlResponse<Result>.self, from: reply)
        } catch {
            throw CLIError.unsupported("Sesh sent an answer this sesh doesn't understand. Use the sesh inside the running Sesh.app (see: sesh status).")
        }
        if let error = response.error { throw CLIError.app(error) }
        guard let result = response.result else { throw CLIError.unsupported("Sesh sent an empty answer.") }
        // On stderr, so stdout stays the result (or its JSON) alone.
        for warning in response.warnings ?? [] {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }
        return result
    }

    private static func exchange(_ request: Data) throws -> Data {
        do {
            return try ControlSocket.exchange(request, path: ControlProtocol.socketPath)
        } catch ControlSocketError.unreachable {
            throw ControlSocketError.unreachable
        } catch ControlSocketError.timedOut {
            throw CLIError.unreachable("Sesh didn't answer within 10 minutes. Is a dialog waiting in Sesh?")
        } catch {
            throw CLIError.unreachable("Couldn't talk to Sesh: \(error).")
        }
    }

    /// Opens Sesh without bringing it forward and waits for its socket.
    private static func launchApp() throws {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let app = AppBundle.enclosing {
            open.arguments = ["-g", app.path]
        } else {
            open.arguments = ["-g", "-b", "co.webteractive.sesh"]
        }
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            throw CLIError.unreachable("Sesh isn't running and couldn't be started: \(error.localizedDescription)")
        }
        guard open.terminationStatus == 0 else {
            throw CLIError.unreachable("Sesh isn't running and couldn't be started. Is Sesh.app installed?")
        }
        let deadline = Date.now.addingTimeInterval(15)
        while Date.now < deadline {
            if (try? ControlSocket.exchange(Data(), path: ControlProtocol.socketPath)) != nil { return }
            usleep(200_000)
        }
        throw CLIError.unreachable("Sesh didn't answer within 15 seconds. If an older Sesh (before the sesh command) is still running, quit it and run this again.")
    }
}

/// The Sesh.app this executable lives in (Sesh.app/Contents/Helpers/sesh),
/// following the symlink `sesh` is usually installed as.
enum AppBundle {
    static let enclosing: URL? = {
        var size = UInt32(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0, let real = realpath(buffer, nil) else { return nil }
        defer { free(real) }
        let app = URL(fileURLWithPath: String(cString: real))
            .deletingLastPathComponent()   // Helpers
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // Sesh.app
        return app.pathExtension == "app" ? app : nil
    }()

    /// "0.1.5 (ca8363f)", read from the enclosing app's Info.plist, so the
    /// CLI always reports the version of the app it shipped in.
    static var versionLine: String {
        guard let app = enclosing, let info = Bundle(url: app)?.infoDictionary,
              let version = info["CFBundleShortVersionString"] as? String else {
            return "development build (not inside Sesh.app)"
        }
        if let commit = info["SeshCommit"] as? String, !commit.isEmpty { return "\(version) (\(commit))" }
        return version
    }
}
