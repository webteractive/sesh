import Testing
@testable import SSHConfigCore

private func row(_ user: String, port: String = "", key: String = "", extras: [SSHProperty] = []) -> CredentialRow {
    CredentialRow(user: user, port: port, identityFile: key, extras: extras)
}
private func form(_ name: String, host: String, _ rows: [CredentialRow]) -> HostFormModel {
    HostFormModel(displayName: name, hostName: host, rows: rows)
}

@Test func validation() {
    #expect(form("", host: "h", [row("u")]).validationError() != nil)          // empty name
    #expect(form("  ", host: "h", [row("u")]).validationError() != nil)         // blank name
    #expect(form("!!!", host: "h", [row("u")]).validationError() != nil)        // name sanitizes to empty
    #expect(form("web", host: "", [row("u")]).validationError() != nil)         // empty host
    #expect(form("web", host: "h", []).validationError() != nil)                // no rows
    #expect(form("web", host: "h", [row("")]).validationError() != nil)         // row without user
    #expect(form("Prod Web", host: "10.0.0.5", [row("admin")]).validationError() == nil)
}

@Test func singleRowMakesLoneHost() {
    let p = HostFormReconciler.plan(
        form("Prod Web", host: "10.0.0.5", [row("admin", port: "2222", key: "~/.ssh/admin")]),
        existing: [], allAliases: [])
    #expect(p.deleteAliases.isEmpty)
    #expect(p.upserts.count == 1)
    let u = p.upserts[0]
    #expect(u.alias == "Prod-Web")           // sanitize(Name)
    #expect(u.groupName == nil)               // lone host
    #expect(u.isDefault == true)
    #expect(u.properties.first("HostName") == "10.0.0.5")
    #expect(u.properties.first("User") == "admin")
    #expect(u.properties.first("Port") == "2222")
    #expect(u.properties.first("IdentityFile") == "~/.ssh/admin")
}

@Test func multipleRowsFormGroup() {
    let p = HostFormReconciler.plan(
        form("web", host: "h", [row("admin"), row("deploy"), row("ci")]),
        existing: [], allAliases: [])
    #expect(p.upserts.map(\.alias) == ["web", "web-deploy", "web-ci"])
    #expect(p.upserts.allSatisfy { $0.groupName == "web" })     // group id = default alias
    #expect(p.upserts.map(\.isDefault) == [true, false, false])
    #expect(p.upserts[1].properties.first("User") == "deploy")
}

@Test func editKeepsUnchangedAliasesStableAndDiffs() {
    // existing group: web(admin,default), web-deploy(deploy). Edit: keep admin,
    // change deploy→ci (remove deploy row, add ci row).
    let p = HostFormReconciler.plan(
        form("web", host: "h", [row("admin"), row("ci")]),
        existing: [("web", "admin"), ("web-deploy", "deploy")],
        allAliases: ["web", "web-deploy"])
    // admin row keeps "web"; deploy removed; ci is new
    #expect(p.upserts.contains { $0.alias == "web" && $0.properties.first("User") == "admin" && $0.isDefault })
    #expect(p.upserts.contains { $0.alias == "web-ci" && $0.properties.first("User") == "ci" })
    #expect(p.deleteAliases == ["web-deploy"])
}

@Test func preservesRowExtras() {
    let p = HostFormReconciler.plan(
        form("web", host: "h", [row("admin", extras: [SSHProperty(key: "ProxyJump", values: ["bastion"])])]),
        existing: [], allAliases: [])
    #expect(p.upserts[0].properties.first("ProxyJump") == "bastion")
}

@Test func aliasCollisionsSuffixed() {
    let p = HostFormReconciler.plan(
        form("web", host: "h", [row("admin")]),
        existing: [], allAliases: ["web"])   // "web" taken by an unrelated host
    #expect(p.upserts[0].alias == "web-2")
}

@Test func editRecomputedBaseDoesNotChurnOtherMembers() {
    // existing group: web(admin,default), web-api(api). Edit form leaves both rows
    // unchanged — the recomputed base ("web") must not steal api's stable alias,
    // and api's unchanged user/alias pairing must not get a needless -2 suffix.
    let p = HostFormReconciler.plan(
        form("web", host: "h", [row("admin"), row("api")]),
        existing: [("web", "admin"), ("web-api", "api")],
        allAliases: ["web", "web-api"])
    #expect(p.upserts.contains { $0.alias == "web" && $0.properties.first("User") == "admin" && $0.isDefault })
    #expect(p.upserts.contains { $0.alias == "web-api" && $0.properties.first("User") == "api" && !$0.isDefault })
    #expect(p.deleteAliases.isEmpty)
    #expect(!p.upserts.contains { $0.alias.hasSuffix("-2") })
}

@Test func reorderingRowsMovesDefaultAndKeepsOthers() {
    // existing group: web(admin,default), web-deploy(deploy). Edit reorders rows so
    // deploy is now first (the new default). deploy's new base alias "web" collides
    // with admin's OLD alias — admin must be reassigned a stable non-base alias
    // rather than the plan producing two upserts that both claim "web".
    let p = HostFormReconciler.plan(
        form("web", host: "h", [row("deploy"), row("admin")]),
        existing: [("web", "admin"), ("web-deploy", "deploy")],
        allAliases: ["web", "web-deploy"])
    let users = Set(p.upserts.compactMap { $0.properties.first("User") })
    #expect(users == ["admin", "deploy"])
    #expect(p.upserts.filter(\.isDefault).count == 1)
    let defaultUpsert = p.upserts.first(where: \.isDefault)
    #expect(defaultUpsert?.properties.first("User") == "deploy")
    #expect(defaultUpsert?.alias == "web")
    #expect(p.upserts.first(where: { $0.properties.first("User") == "admin" })?.alias == "web-admin")
    #expect(p.upserts.allSatisfy { $0.groupName == "web" })
}
