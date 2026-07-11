import Testing
@testable import SSHConfigCore

private func row(_ alias: String, group: String? = nil, user: String? = nil,
                 identity: String? = nil, isDefault: Bool = false,
                 connectable: Bool = true) -> HostRow {
    HostRow(alias: alias, groupName: group, user: user, identityFile: identity,
            isDefault: isDefault, isConnectable: connectable)
}

@Test func ungroupedRowsBecomeSingletonGroups() {
    let g = HostGrouping.groups(from: [row("web", user: "admin"), row("db", user: "root")])
    #expect(g.count == 2)
    #expect(g.map(\.title) == ["web", "db"])
    #expect(g.allSatisfy { $0.members.count == 1 })
    #expect(g[0].defaultMember.alias == "web")          // lone member is the default
    #expect(!g[0].isMultiProfile)
}

@Test func sameGroupNameFolds_defaultFirstThenByUser() {
    let g = HostGrouping.groups(from: [
        row("web-deploy", group: "web", user: "deploy"),
        row("web", group: "web", user: "admin", isDefault: true),
        row("web-ci", group: "web", user: "ci"),
    ])
    #expect(g.count == 1)
    let m = g[0]
    #expect(m.title == "web")
    #expect(m.isMultiProfile)
    #expect(m.members.map(\.alias) == ["web", "web-ci", "web-deploy"]) // default, then user asc
    #expect(m.defaultMember.alias == "web")
    #expect(m.members[1].label == "ci")   // label falls back to user
}

@Test func groupOrderFollowsFirstMemberInputOrder() {
    let g = HostGrouping.groups(from: [
        row("b1", group: "beta", user: "x", isDefault: true),
        row("a1", group: "alpha", user: "y", isDefault: true),
        row("b2", group: "beta", user: "z"),
    ])
    #expect(g.map(\.title) == ["beta", "alpha"])   // group appears when first seen
}

@Test func labelFallsBackToAliasWhenNoUser() {
    let g = HostGrouping.groups(from: [row("gateway")])
    #expect(g[0].members[0].label == "gateway")
}

@Test func nonConnectableFlagPreserved() {
    let g = HostGrouping.groups(from: [row("*.internal", connectable: false)])
    #expect(g[0].members[0].isConnectable == false)
}

@Test func groupWithNoExplicitDefaultUsesFirstByUser() {
    let g = HostGrouping.groups(from: [
        row("s-b", group: "s", user: "bob"),
        row("s-a", group: "s", user: "amy"),
    ])
    // no isDefault set → earliest by user sort is the default
    #expect(g[0].defaultMember.user == "amy")
    #expect(g[0].members.map(\.user) == ["amy", "bob"])
}

@Test func singletonIdDoesNotCollideWithRealGroupName() {
    let g = HostGrouping.groups(from: [
        row("web"),
        row("web-a", group: "single:web", user: "a"),
        row("web-b", group: "single:web", user: "b"),
    ])
    #expect(g.count == 2)
    #expect(Set(g.map(\.id)).count == g.count)
    let singleton = g.first { $0.title == "web" }
    let realGroup = g.first { $0.title == "single:web" }
    #expect(singleton?.members.map(\.alias) == ["web"])
    #expect(realGroup?.members.map(\.alias).sorted() == ["web-a", "web-b"])
}
