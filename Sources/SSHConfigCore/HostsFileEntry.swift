import Foundation
import SwiftData

/// One /etc/hosts mapping managed by Sesh. The store is the source of truth;
/// Sesh's block in /etc/hosts is rendered from these in `sortOrder`.
@Model
public final class HostsFileEntry {
    @Attribute(.unique) public var id: UUID
    public var ip: String
    public var hostnames: [String]
    public var note: String?
    public var isEnabled: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(ip: String, hostnames: [String], note: String? = nil, isEnabled: Bool = true, sortOrder: Int = 0) {
        self.id = UUID()
        self.ip = ip
        self.hostnames = hostnames
        self.note = note
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// The order entries render in Sesh's block (and list in the UI).
    public static var blockOrder: [SortDescriptor<HostsFileEntry>] {
        [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
    }

    public var line: HostsLine {
        HostsLine(ip: ip, hostnames: hostnames, note: note, isEnabled: isEnabled)
    }
}
