import Testing
import Foundation
@testable import SSHConfigCore

private let web = SeshArchive.SSHHost(alias: "web", properties: [SSHProperty(key: "HostName", values: ["example.com"])],
                                      displayName: "Web", workspace: "Clients")

private func profile(_ alias: String, default isDefault: Bool = false) -> SeshArchive.SSHHost {
    SeshArchive.SSHHost(alias: alias, properties: [SSHProperty(key: "User", values: [alias])],
                        groupName: "db", isDefaultProfile: isDefault)
}

@Test func archiveRoundTripsThroughJSON() throws {
    let archive = SeshArchive(
        sshHosts: [web, profile("db", default: true), profile("db-ro")],
        hostsEntries: [.init(HostsLine(ip: "10.0.0.5", hostnames: ["api.test"], note: "staging", isEnabled: false))],
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let decoded = try SeshArchive.decode(archive.encoded())
    #expect(decoded == archive)
    #expect(decoded.sshGroups.map { $0.map(\.alias) } == [["web"], ["db", "db-ro"]])
}

@Test func decodeRejectsForeignAndNewerFiles() throws {
    #expect(throws: SeshArchiveError.unreadable) { try SeshArchive.decode(Data("not json".utf8)) }
    #expect(throws: SeshArchiveError.unreadable) { try SeshArchive.decode(Data(#"{"hosts": []}"#.utf8)) }
    #expect(throws: SeshArchiveError.newerVersion(99)) {
        try SeshArchive.decode(Data(#"{"version": 99, "whatever": true}"#.utf8))
    }
}

@Test func decodeRejectsLinesThatWouldInjectConfig() throws {
    func file(_ hosts: [SeshArchive.SSHHost], _ entries: [HostsLine] = []) throws -> Data {
        try SeshArchive(sshHosts: hosts, hostsEntries: entries.map(SeshArchive.HostsEntry.init)).encoded()
    }
    let newlineValue = SeshArchive.SSHHost(alias: "x", properties: [
        SSHProperty(key: "HostName", values: ["a.test\nHost *\n    ProxyCommand sh"])])
    let badKey = SeshArchive.SSHHost(alias: "x", properties: [SSHProperty(key: "Host Name", values: ["a"])])
    let badAlias = SeshArchive.SSHHost(alias: "x\nHost y", properties: [])
    let blockKeys = ["Match", "host", "Include"].map {
        SeshArchive.SSHHost(alias: "x", properties: [SSHProperty(key: $0, values: ["exec \"sh -c id\""])])
    }
    for host in [newlineValue, badKey, badAlias] + blockKeys {
        #expect(throws: SeshArchiveError.self) { try SeshArchive.decode(file([host])) }
    }
    #expect(throws: SeshArchiveError.self) {
        try SeshArchive.decode(file([], [HostsLine(ip: "999.1.1.1", hostnames: ["a.test"])]))
    }
}

@Test func riskyOptionsFlagsLocalCodeAndLoosenedChecks() {
    let host = SeshArchive.SSHHost(alias: "x", properties: [
        SSHProperty(key: "HostName", values: ["a"]),
        SSHProperty(key: "proxycommand", values: ["nc %h %p"]),
        SSHProperty(key: "PKCS11Provider", values: ["/tmp/x.dylib"]),
        SSHProperty(key: "StrictHostKeyChecking", values: ["no"]),
        SSHProperty(key: "ForwardAgent", values: ["yes"]),
    ])
    #expect(host.riskyOptions == ["proxycommand", "PKCS11Provider", "StrictHostKeyChecking", "ForwardAgent"])
    #expect(web.riskyOptions.isEmpty)
}

@Test func patternAndMultiAliasesCantTravel() {
    for alias in ["*", "*.example.com", "!prod", "web?", "a b", "x\ty", "\"q\"", "a,b"] {
        #expect(SeshArchive.SSHHost(alias: alias, properties: []).problem != nil, "\(alias)")
    }
    #expect(SeshArchive.SSHHost(alias: "web-1.example_com", properties: []).problem == nil)
}

@Test func planSkipsTakenAndRepeatedAliases() {
    let plan = SeshArchive.planSSHImport([web, web, profile("db", default: true), profile("db-ro")],
                                         existingAliases: ["web"], existingGroups: [])
    #expect(plan.added.map(\.alias) == ["db", "db-ro"])
    #expect(plan.skipped == 2)
}

@Test func planJoiningAnExistingGroupNeverStealsItsDefault() {
    let plan = SeshArchive.planSSHImport([profile("db", default: true), profile("db-ro")],
                                         existingAliases: ["db-admin"], existingGroups: ["db"])
    #expect(plan.added.map(\.isDefaultProfile) == [false, false])
    #expect(plan.added.allSatisfy { $0.groupName == "db" })
}

@Test func planRepairsNewGroupsLeftShortByTheSkip() {
    // Default skipped: the first added profile takes over.
    let promoted = SeshArchive.planSSHImport([profile("db", default: true), profile("db-ro"), profile("db-rw")],
                                             existingAliases: ["db"], existingGroups: [])
    #expect(promoted.added.map(\.isDefaultProfile) == [true, false])
    // One profile left: it becomes a plain host.
    let lone = SeshArchive.planSSHImport([profile("db", default: true), profile("db-ro")],
                                         existingAliases: ["db"], existingGroups: [])
    #expect(lone.added.count == 1)
    #expect(lone.added[0].groupName == nil)
    #expect(lone.added[0].isDefaultProfile == false)
}

@Test func sshSectionsFollowTheSidebarOrder() {
    func host(_ alias: String, _ workspace: String?) -> SeshArchive.SSHHost {
        SeshArchive.SSHHost(alias: alias, properties: [], workspace: workspace)
    }
    let archive = SeshArchive(sshHosts: [host("a", "Zeta"), host("b", nil), host("c", "clients"), host("d", "Home"),
                                         host("e", "Alpha"), host("f", "Clients")], hostsEntries: [])
    let sections = archive.sshSections(workspaceOrder: ["Home", "Clients", "Empty"])
    #expect(sections.map(\.workspace) == [nil, "Home", "Clients", "Alpha", "Zeta"])
    #expect(sections.map { $0.groups.map { $0[0].alias } } == [["b"], ["d"], ["c", "f"], ["e"], ["a"]])
    // A logical host follows its default profile, and stays in one piece.
    var member = profile("db-ro"); member.workspace = "Home"
    let grouped = SeshArchive(sshHosts: [profile("db", default: true), member], hostsEntries: [])
    #expect(grouped.sshSections(workspaceOrder: ["Home"]).map(\.workspace) == [nil])
}

@Test func selectingKeepsTickedGroupsWholeAndTickedEntries() {
    let entries = ["a.test", "b.test", "c.test"].map {
        SeshArchive.HostsEntry(HostsLine(ip: "1.2.3.4", hostnames: [$0]))
    }
    let archive = SeshArchive(sshHosts: [web, profile("db", default: true), profile("db-ro")], hostsEntries: entries)
    let picked = archive.selecting(sshGroups: ["db"], hostsEntries: [0, 2])
    #expect(picked.sshHosts.map(\.alias) == ["db", "db-ro"])
    #expect(picked.hostsEntries.map { $0.hostnames[0] } == ["a.test", "c.test"])
}

@Test func planKeepsImportedKeysApartFromTheStores() {
    func member(_ alias: String, _ group: String, default isDefault: Bool = false) -> SeshArchive.SSHHost {
        SeshArchive.SSHHost(alias: alias, properties: [], groupName: group, isDefaultProfile: isDefault)
    }
    // The store has a plain host "prod"; the file's group "prod" doesn't contain it.
    let plan = SeshArchive.planSSHImport([member("prod-b", "prod", default: true), member("prod-c", "prod")],
                                         existingAliases: ["prod", "prod-2"], existingGroups: [])
    #expect(plan.added.map(\.groupName) == ["prod-3", "prod-3"])
    // The store has a group "db"; a plain host "db" in the file would join it by key.
    let plain = SeshArchive.planSSHImport([SeshArchive.SSHHost(alias: "db", properties: [])],
                                          existingAliases: ["db-ro", "db-rw"], existingGroups: ["db"])
    #expect(plain.added.isEmpty && plain.skipped == 1)
}

@Test func risksFlagHostsThatTakeOverOtherNames() {
    func host(_ alias: String, _ hostName: String?) -> SeshArchive.SSHHost {
        SeshArchive.SSHHost(alias: alias, properties: hostName.map { [SSHProperty(key: "HostName", values: [$0])] } ?? [])
    }
    #expect(SeshArchive.risks(of: [host("github.com", "evil.example")], configAliases: []) == ["sends github.com to evil.example"])
    #expect(SeshArchive.risks(of: [host("github.com", "GitHub.com")], configAliases: []).isEmpty)
    #expect(SeshArchive.risks(of: [host("web", "10.0.0.5")], configAliases: []).isEmpty)
    #expect(SeshArchive.risks(of: [host("10.0.0.5", "evil.example")], configAliases: []).isEmpty)
    #expect(SeshArchive.risks(of: [host("Work", "1.2.3.4")], configAliases: ["work"]) == ["replaces Work from your ~/.ssh/config"])
    let agent = SeshArchive.SSHHost(alias: "x", properties: [SSHProperty(key: "ForwardAgent", values: ["yes"])])
    #expect(SeshArchive.risks(of: [agent], configAliases: []) == ["sets ForwardAgent"])
}

@Test func presentMatchesWhatThePlanSkips() {
    let plain = [SeshArchive.SSHHost(alias: "db", properties: [])]
    #expect(SeshArchive.isPresent(plain, existingAliases: ["db-ro"], existingGroups: ["db"]))
    #expect(!SeshArchive.isPresent(plain, existingAliases: ["db-ro"], existingGroups: []))
    let group = [profile("db", default: true), profile("db-ro")]
    #expect(!SeshArchive.isPresent(group, existingAliases: ["db"], existingGroups: ["db"]))
    #expect(SeshArchive.isPresent(group, existingAliases: ["db", "db-ro"], existingGroups: []))
}
