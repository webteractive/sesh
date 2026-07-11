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

    let hosts = ConfigImporter().hosts(inConfigAt: config, managedPath: "~/.ssh/sesh.conf")
    #expect(hosts.map(\.alias) == ["web"])       // Include + Match not hosts
    #expect(hosts[0].properties.first("HostName") == "example.com")
    #expect(hosts[0].properties.first("User") == "admin")
}

@Test func missingFileImportsNothing() {
    #expect(ConfigImporter().hosts(inConfigAt: "/nope/config", managedPath: "~/.ssh/sesh.conf").isEmpty)
}
