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

    public func write(_ hosts: [RenderableHost], toPath path: String) throws {
        try writer.write(render(hosts), toPath: path)
    }
}
