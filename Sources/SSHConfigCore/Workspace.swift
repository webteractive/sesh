import Foundation
import SwiftData

@Model
public final class Workspace {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Manual sidebar order (lower = higher). Ties fall back to createdAt.
    public var sortOrder: Int = 0

    public init(name: String, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.sortOrder = sortOrder
    }
}
