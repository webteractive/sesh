import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Store-side view of a host block, decoupled from SwiftData.
public struct RenderableHost: Equatable, Sendable {
    public var host: String
    public var properties: [SSHProperty]

    public init(host: String, properties: [SSHProperty]) {
        self.host = host
        self.properties = properties
    }
}

public struct SSHConfigWriter {
    public init() {}

    public func render(host: String, properties: [SSHProperty]) -> String {
        var lines = ["Host \(host)"]
        for property in properties {
            for value in property.values {
                lines.append("    \(property.key) \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func renderFile(segments: [Segment], entries: [RenderableHost]) -> String {
        var chunks: [String] = []
        var written = Set<String>()

        for segment in segments {
            switch segment {
            case .prologue(let text), .comment(let text), .include(let text), .matchBlock(let text):
                chunks.append(text)
            case .hostBlock(let parsed):
                if written.contains(parsed.pattern) {
                    // Duplicate pattern segment — first occurrence already rendered it.
                    continue
                }
                if let entry = entries.first(where: { $0.host == parsed.pattern }) {
                    chunks.append(render(host: entry.host, properties: entry.properties))
                    written.insert(entry.host)
                }
                // else: dropped — the store is authoritative for host blocks.
            }
        }
        for entry in entries where !written.contains(entry.host) {
            chunks.append(render(host: entry.host, properties: entry.properties))
        }
        guard !chunks.isEmpty else { return "" }
        return chunks.joined(separator: "\n\n") + "\n"
    }

    public func write(_ content: String, toPath path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        let fm = FileManager.default

        // If the destination is a symlink (e.g. a dotfile manager linking
        // ~/.ssh/config to a managed repo), write through it to the real
        // target rather than replacing the link itself with a plain file.
        // `attributesOfItem` uses lstat and reports the symlink's own type,
        // not the type of whatever it points to.
        var destination = expanded
        if let attrs = try? fm.attributesOfItem(atPath: expanded),
           (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            destination = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        }

        let dir = (destination as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        guard let data = content.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }

        let tmpPath = destination + ".tmp-" + UUID().uuidString
        // Create with mode 0600 at the open(2) syscall so the file never
        // exists on disk at a looser mode, not even transiently.
        let fd = open(tmpPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmpPath])
        }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? fm.removeItem(atPath: tmpPath)
            throw error
        }

        let renameResult = tmpPath.withCString { tmpCString in
            destination.withCString { destCString in
                rename(tmpCString, destCString)
            }
        }
        guard renameResult == 0 else {
            let errnoValue = errno
            try? fm.removeItem(atPath: tmpPath)
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: destination,
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errnoValue)),
            ])
        }
    }
}
