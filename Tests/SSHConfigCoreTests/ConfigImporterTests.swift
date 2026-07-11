import Testing
import Foundation
@testable import SSHConfigCore

@Test func importsHostsSkippingManagedIncludeAndMatch() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try """
    Include ~/.ssh/sesh.conf

    Host web
        HostName example.com
        User admin

    Match host *.internal
        ProxyJump bastion
    """.write(toFile: config, atomically: true, encoding: .utf8)

    let hosts = ConfigImporter().hosts(inConfigAt: config)
    #expect(hosts.map(\.alias) == ["web"])       // Include + Match not hosts
    #expect(hosts[0].properties.first("HostName") == "example.com")
    #expect(hosts[0].properties.first("User") == "admin")
}

@Test func missingFileImportsNothing() {
    #expect(ConfigImporter().hosts(inConfigAt: "/nope/config").isEmpty)
}

@Test func groupsSameHostNameDifferingUsers() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try """
    Host WebSolutionsTools
        HostName 143.198.192.77
        User forge
        IdentityFile ~/.ssh/web

    Host WebSolutionsToolsCoopit
        HostName 143.198.192.77
        User coopit
        IdentityFile ~/.ssh/web

    Host solo
        HostName 10.0.0.9
        User root
    """.write(toFile: config, atomically: true, encoding: .utf8)

    let groups = ConfigImporter().groups(inConfigAt: config)
    let tools = groups.first { $0.members.contains { $0.alias == "WebSolutionsTools" } }!
    #expect(tools.groupName == "WebSolutionsTools")                 // first member's alias
    #expect(tools.members.map(\.alias) == ["WebSolutionsTools", "WebSolutionsToolsCoopit"])
    #expect(tools.displayName == "WebSolutionsTools")               // common prefix
    let solo = groups.first { $0.members.first?.alias == "solo" }!
    #expect(solo.groupName == nil)
    #expect(solo.displayName == "solo")
}

@Test func sameHostNameSameUserStaysSeparate() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try """
    Host sds
        HostName 104.248.237.163
        User forge

    Host jobs.example.co
        HostName 104.248.237.163
        User forge
    """.write(toFile: config, atomically: true, encoding: .utf8)

    let groups = ConfigImporter().groups(inConfigAt: config)
    #expect(groups.count == 2)
    #expect(groups.allSatisfy { $0.groupName == nil })            // both singletons
    #expect(Set(groups.map(\.displayName)) == ["sds", "jobs.example.co"])
}

@Test func wildcardHostIsSingleton() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try "Host *.internal\n    User admin\n".write(toFile: config, atomically: true, encoding: .utf8)
    let groups = ConfigImporter().groups(inConfigAt: config)
    #expect(groups.count == 1)
    #expect(groups[0].groupName == nil)
    #expect(groups[0].displayName == "*.internal")
}

@Test func commonPrefix() {
    #expect(ConfigImporter.commonAliasPrefix(["WebSolutionsTools", "WebSolutionsToolsCoopit"]) == "WebSolutionsTools")
    #expect(ConfigImporter.commonAliasPrefix(["prod-web", "prod-db"]) == "prod")      // trims trailing '-'
    #expect(ConfigImporter.commonAliasPrefix(["alpha", "beta"]) == "")                 // no common prefix
    #expect(ConfigImporter.commonAliasPrefix(["only"]) == "only")
}
