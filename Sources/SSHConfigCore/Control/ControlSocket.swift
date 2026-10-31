import Darwin
import Foundation

public enum ControlSocketError: Error, Equatable {
    /// Nothing is listening at the path (the app isn't running).
    case unreachable
    /// The path doesn't fit in a socket address.
    case pathTooLong
    /// A request or response bigger than `ControlSocket.maxMessageSize`.
    case tooLarge
    /// The peer stopped sending or reading for longer than the timeout.
    case timedOut
    case io(Int32)
}

/// Minimal Unix-domain stream sockets: one message each way per connection,
/// framed by the sender half-closing its side.
public enum ControlSocket {
    /// Generous for a whole export, small enough that a stray client can't
    /// make the app buffer without bound.
    public static let maxMessageSize = 32 * 1024 * 1024

    /// Connects to `path`, sends `message`, and returns the reply, giving up
    /// after `timeout` seconds without one.
    public static func exchange(_ message: Data, path: String, timeout: Int = 600) throws -> Data {
        let fd = try makeSocket()
        defer { close(fd) }
        setTimeout(fd, seconds: timeout)
        let status = try withAddress(path) { connect(fd, $0, $1) }
        if status != 0 {
            if errno == ENOENT || errno == ECONNREFUSED { throw ControlSocketError.unreachable }
            throw ControlSocketError.io(errno)
        }
        try writeAll(fd, message)
        shutdown(fd, SHUT_WR)
        return try readAll(fd)
    }

    /// Binds and listens at `path`, replacing a stale socket there, readable
    /// and writable by the owner only.
    public static func listen(path: String) throws -> Int32 {
        let fd = try makeSocket()
        unlink(path)
        let bound = try withAddress(path) { bind(fd, $0, $1) }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw ControlSocketError.io(code)
        }
        return fd
    }

    /// Reads until the peer half-closes.
    public static func readAll(_ fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw ControlSocketError.timedOut }
                throw ControlSocketError.io(errno)
            }
            data.append(buffer, count: count)
            if data.count > maxMessageSize { throw ControlSocketError.tooLarge }
        }
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = write(fd, base + offset, raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ControlSocketError.io(errno)
                }
                offset += count
            }
        }
    }

    /// True when the process at the other end runs as this user. The socket's
    /// permissions already keep others out; this holds even if they're loosened.
    public static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// Gives up on a peer that stops sending or reading for `seconds`.
    public static func setTimeout(_ fd: Int32, seconds: Int) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, size)
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.io(errno) }
        // A peer that hangs up mid-write must not kill the process.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Calls `body` with a socket address for `path`. A path too long for one
    /// (a long home folder) is reached by its name from inside its directory,
    /// changing back afterwards; this runs once at app launch and once per
    /// CLI call, before either has other threads using relative paths.
    private static func withAddress(_ path: String,
                                    _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws -> Int32 {
        if path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) {
            return try withShortAddress(path, body)
        }
        let previous = open(".", O_RDONLY | O_DIRECTORY)
        guard previous >= 0 else { throw ControlSocketError.pathTooLong }
        defer { fchdir(previous); close(previous) }
        guard chdir((path as NSString).deletingLastPathComponent) == 0 else {
            if errno == ENOENT { throw ControlSocketError.unreachable }
            throw ControlSocketError.io(errno)
        }
        return try withShortAddress((path as NSString).lastPathComponent, body)
    }

    private static func withShortAddress(_ path: String,
                                         _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ControlSocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}
