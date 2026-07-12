import Testing
import Foundation
@testable import SSHConfigCore

private func row(_ alias: String, group: String? = nil, user: String? = "u",
                 isDefault: Bool = true) -> HostRow {
    HostRow(alias: alias, groupName: group, user: user, identityFile: nil,
            isDefault: isDefault, isConnectable: true, displayName: alias)
}

@Test func noWorkspacesYieldsSingleDefaultSection() {
    let s = WorkspaceSectioning.sections(
        rows: [row("a"), row("b")], workspaceIDByAlias: [:], workspaces: [])
    #expect(s.count == 1)
    #expect(s[0].workspace == nil)
    #expect(s[0].title == "Default")
    #expect(s[0].groups.count == 2)
}

@Test func hostsSplitAcrossDefaultAndWorkspaces() {
    let w1 = WorkspaceRef(id: UUID(), name: "Prod")
    let w2 = WorkspaceRef(id: UUID(), name: "Staging")
    let s = WorkspaceSectioning.sections(
        rows: [row("a"), row("b"), row("c")],
        workspaceIDByAlias: ["b": w1.id, "c": w2.id],
        workspaces: [w1, w2])
    #expect(s.map(\.title) == ["Default", "Prod", "Staging"])   // Default first, then input order
    #expect(s[0].groups.map(\.title) == ["a"])
    #expect(s[1].groups.map(\.title) == ["b"])
    #expect(s[2].groups.map(\.title) == ["c"])
}

@Test func defaultSectionOmittedWhenEmpty() {
    let w1 = WorkspaceRef(id: UUID(), name: "Prod")
    let s = WorkspaceSectioning.sections(
        rows: [row("a")], workspaceIDByAlias: ["a": w1.id], workspaces: [w1])
    #expect(s.map(\.title) == ["Prod"])                          // no Default (nothing in it)
    #expect(s[0].groups.map(\.title) == ["a"])
}

@Test func emptyWorkspaceStillYieldsSection() {
    let w1 = WorkspaceRef(id: UUID(), name: "Empty")
    let s = WorkspaceSectioning.sections(
        rows: [row("a")], workspaceIDByAlias: [:], workspaces: [w1])
    #expect(s.map(\.title) == ["Default", "Empty"])
    #expect(s[1].groups.isEmpty)
}

@Test func unknownWorkspaceIDFallsToDefault() {
    let w1 = WorkspaceRef(id: UUID(), name: "Prod")
    let s = WorkspaceSectioning.sections(
        rows: [row("a")], workspaceIDByAlias: ["a": UUID()],     // id not in `workspaces`
        workspaces: [w1])
    #expect(s.first(where: { $0.workspace == nil })?.groups.map(\.title) == ["a"])
}

@Test func groupingStillAppliesWithinSection() {
    let s = WorkspaceSectioning.sections(
        rows: [row("web", group: "web", isDefault: true),
               row("web-deploy", group: "web", user: "deploy", isDefault: false)],
        workspaceIDByAlias: [:], workspaces: [])
    #expect(s[0].groups.count == 1)                              // one profile group
    #expect(s[0].groups[0].members.count == 2)
}
