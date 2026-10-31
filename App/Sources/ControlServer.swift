import AppKit
import Foundation
import SSHConfigCore

/// Serves `sesh` CLI requests on `ControlProtocol.socketPath`. Connections
/// are accepted and read on background threads; each request then runs on
/// the main actor, like a click in the UI, and its answer is written back.
@MainActor
final class ControlServer {
    /// Runs a command; returns its result and any warnings to pass on.
    typealias Handler = @MainActor (ControlCommand) async throws -> (result: any Encodable, warnings: [String])

    private var listener: Int32 = -1
    private nonisolated static let maxConnections = 8

    /// Starts listening. A failure only costs the CLI, so it's logged, not shown.
    func start(handler: @escaping Handler) {
        guard listener < 0 else { return }
        let path = ControlProtocol.socketPath
        do {
            // Owner-only: it holds the socket, the store, and /etc/hosts backups.
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            listener = try ControlSocket.listen(path: path)
        } catch {
            NSLog("Sesh: the command-line socket couldn't start: \(error)")
            return
        }
        let fd = listener
        Thread.detachNewThread {
            // A few connections at once is plenty; a flood of slow ones
            // waits for a free slot instead of starting a thread each.
            let slots = DispatchSemaphore(value: Self.maxConnections)
            while true {
                slots.wait()
                let client = accept(fd, nil, nil)
                if client < 0 {
                    slots.signal()
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                Thread.detachNewThread {
                    Self.serve(client, handler: handler)
                    slots.signal()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: nil) { _ in unlink(path) }
    }

    private nonisolated static func serve(_ fd: Int32, handler: @escaping Handler) {
        defer { close(fd) }
        guard ControlSocket.peerIsCurrentUser(fd) else { return }
        ControlSocket.setTimeout(fd, seconds: 30)
        guard let request = try? ControlSocket.readAll(fd) else { return }
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            reply.data = await respond(to: request, handler: handler)
            done.signal()
        }
        done.wait()
        try? ControlSocket.writeAll(fd, reply.data)
    }

    private static func respond(to data: Data, handler: Handler) async -> Data {
        let encoder = ControlProtocol.encoder()
        func failure(_ error: ControlFailure) -> Data {
            (try? encoder.encode(ControlResponse<Int>(error: error))) ?? Data()
        }
        let decoder = ControlProtocol.decoder()
        guard let probe = try? decoder.decode(ControlVersionProbe.self, from: data) else {
            return failure(ControlFailure(.invalid, "That isn't a Sesh request."))
        }
        guard probe.version == ControlProtocol.version,
              let request = try? decoder.decode(ControlRequest.self, from: data) else {
            return failure(ControlFailure(.unsupported,
                "This copy of Sesh (\(AppModel.appVersion)) doesn't understand that request. Use the sesh command that comes with it: \(Bundle.main.bundlePath)/Contents/Helpers/sesh"))
        }
        do {
            let reply = try await handler(request.command)
            return try encoder.encode(ControlResponse(result: AnyEncodable(reply.result), warnings: reply.warnings))
        } catch let error as ControlFailure {
            return failure(error)
        } catch {
            return failure(ControlFailure(.failed, error.localizedDescription))
        }
    }

    /// Carries a response from the main actor back to the connection's thread,
    /// which waits on a semaphore until it's set.
    private final class Reply: @unchecked Sendable {
        var data = Data()
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable

    init(_ value: any Encodable) { self.value = value }

    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
