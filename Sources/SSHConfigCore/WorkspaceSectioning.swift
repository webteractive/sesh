import Foundation

public struct WorkspaceRef: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

public struct WorkspaceSection: Identifiable, Sendable {
    public let workspace: WorkspaceRef?      // nil = Default
    public let groups: [HostGroupView]
    public var id: String { workspace?.id.uuidString ?? "default" }
    public var title: String { workspace?.name ?? "Default" }
    public init(workspace: WorkspaceRef?, groups: [HostGroupView]) {
        self.workspace = workspace; self.groups = groups
    }
}

public enum WorkspaceSectioning {
    public static func sections(rows: [HostRow],
                                workspaceIDByAlias: [String: UUID],
                                workspaces: [WorkspaceRef]) -> [WorkspaceSection] {
        let known = Set(workspaces.map(\.id))
        // Bucket rows: nil / unknown id → Default.
        var defaultRows: [HostRow] = []
        var byWorkspace: [UUID: [HostRow]] = [:]
        for r in rows {
            if let wid = workspaceIDByAlias[r.alias], known.contains(wid) {
                byWorkspace[wid, default: []].append(r)
            } else {
                defaultRows.append(r)
            }
        }
        var result: [WorkspaceSection] = []
        if !defaultRows.isEmpty {
            result.append(WorkspaceSection(workspace: nil, groups: HostGrouping.groups(from: defaultRows)))
        }
        for ws in workspaces {
            result.append(WorkspaceSection(
                workspace: ws,
                groups: HostGrouping.groups(from: byWorkspace[ws.id] ?? [])))
        }
        return result
    }
}
