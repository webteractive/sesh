import Foundation
import SwiftData

@Model
public final class Workspace {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
    }
}
