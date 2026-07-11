import Testing
import Foundation
@testable import SSHConfigCore

private let exporter = ConfigExporter()

@Test func renderEmitsManagedHeaderAndOneBlockPerHost() {
    let text = exporter.render([
        RenderableHost(host: "web", properties: [
            SSHProperty(key: "HostName", values: ["10.0.0.5"]),
            SSHProperty(key: "User", values: ["admin"]),
        ]),
        RenderableHost(host: "db", properties: [SSHProperty(key: "User", values: ["root"])]),
    ])
    #expect(text.hasPrefix(ConfigExporter.managedHeader))
    #expect(text.contains("Host web"))
    #expect(text.contains("    HostName 10.0.0.5"))
    #expect(text.contains("Host db"))
    // exactly two Host blocks (lines beginning "Host ")
    let hostLines = text.split(separator: "\n").filter { $0.hasPrefix("Host ") }
    #expect(hostLines.count == 2)
}

@Test func renderEmptyStillHasHeader() {
    let text = exporter.render([])
    #expect(text.hasPrefix(ConfigExporter.managedHeader))
    #expect(!text.contains("\nHost "))
}

@Test func writeIs0600() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/sesh.conf"
    try exporter.write([RenderableHost(host: "web", properties: [])], toPath: path)
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    #expect(try String(contentsOfFile: path, encoding: .utf8).contains("Host web"))
}
