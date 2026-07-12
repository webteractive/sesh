import Foundation
import SwiftData

@Model
public final class HostEntry {
    @Attribute(.unique) public var host: String
    public var properties: [SSHProperty]
    public var rawBlock: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// App-only grouping: entries sharing a non-nil groupName are one logical
    /// host (never read from / written to the config file).
    public var groupName: String? = nil
    /// The profile chosen on a plain (non-picked) connect for its group.
    public var isDefaultProfile: Bool = false
    /// Human label from the New Host form; shown in the UI, never written to
    /// the ssh config. Nil for entries created before this field / by import.
    public var displayName: String? = nil
    /// App-only workspace membership (nil = Default). Never written to ssh config.
    public var workspaceID: UUID? = nil

    public init(host: String, properties: [SSHProperty], rawBlock: String?) {
        self.host = host
        self.properties = properties
        self.rawBlock = rawBlock
        self.createdAt = .now
        self.updatedAt = .now
        self.groupName = nil
        self.isDefaultProfile = false
    }

    public var sshCommand: String { "ssh \(host)" }

    public var port: String { properties.first("Port") ?? "22" }

    /// A host is directly connectable only when its pattern is a single
    /// literal alias (no wildcards, negation, or multiple patterns).
    public var isConnectable: Bool {
        !host.isEmpty && !host.contains(where: { "*?! ".contains($0) })
    }
}
