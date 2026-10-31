import Foundation

/// Renders the store into the app-owned managed include file. The file is 100%
/// app-authored (no foreign segments to preserve), so this is a straight
/// render of every host block, not the segment-preserving writer path.
public struct ConfigExporter {
    public static let managedHeader = """
    # Managed by Sesh — do not edit by hand.
    # Your hosts live in the Sesh app; this file is regenerated on every change.
    """

    private let writer = SSHConfigWriter()

    public init() {}

    public func render(_ hosts: [RenderableHost]) -> String {
        let blocks = hosts.map { writer.render(host: $0.host, properties: $0.properties) }
        return ([Self.managedHeader] + blocks).joined(separator: "\n\n") + "\n"
    }

    /// Writes `hosts` to `path`. Refuses a host with a line break anywhere
    /// (it would inject a config line however it got into the store), and
    /// refuses to replace a file that isn't Sesh's, so a mistyped managed
    /// path can't overwrite something else.
    public func write(_ hosts: [RenderableHost], toPath path: String) throws {
        for host in hosts {
            let texts = [host.host] + host.properties.flatMap { [$0.key] + $0.values }
            if texts.contains(where: SSHOptionRules.hasLineBreak) {
                throw ConfigExportError("Host '\(host.host)' has a line break in it, so it wasn't written.")
            }
        }
        let expanded = (path as NSString).expandingTildeInPath
        if let existing = FileManager.default.contents(atPath: expanded), !existing.isEmpty,
           !existing.starts(with: Data(Self.managedMarker.utf8)) {
            throw ConfigExportError("\(path) already exists and isn't Sesh's file, so Sesh won't overwrite it. Choose another managed file path.")
        }
        try writer.write(render(hosts), toPath: path)
    }

    /// How every managed file Sesh has written begins.
    static let managedMarker = "# Managed by Sesh"
}

public struct ConfigExportError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
