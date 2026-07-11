import Testing
import Foundation
@testable import SSHConfigCore

private let parser = SSHConfigParser()
private let writer = SSHConfigWriter()

@Test func rendersHostBlockWithIndentedProperties() {
    let out = writer.render(host: "web", properties: [
        SSHProperty(key: "HostName", values: ["example.com"]),
        SSHProperty(key: "IdentityFile", values: ["~/.ssh/a", "~/.ssh/b"]),
    ])
    #expect(out == """
    Host web
        HostName example.com
        IdentityFile ~/.ssh/a
        IdentityFile ~/.ssh/b
    """)
}

@Test func rebuildPreservesNonHostSegmentsAndOrder() {
    let source = """
    # globals
    ServerAliveInterval 60

    Include ~/.ssh/config.d/*

    Host web
        HostName old.example.com

    Match host *.internal
        ProxyJump bastion
    """
    let segments = parser.parse(source)
    let out = writer.renderFile(segments: segments, entries: [
        RenderableHost(host: "web", properties: [SSHProperty(key: "HostName", values: ["new.example.com"])]),
        RenderableHost(host: "db", properties: [SSHProperty(key: "User", values: ["admin"])]),
    ])
    // Order: prologue, include, web (updated), match, then appended db.
    let expected = """
    # globals
    ServerAliveInterval 60

    Include ~/.ssh/config.d/*

    Host web
        HostName new.example.com

    Match host *.internal
        ProxyJump bastion

    Host db
        User admin

    """
    #expect(out == expected)
}

@Test func hostsMissingFromStoreAreDropped() {
    let segments = parser.parse("Host gone\n    User x\n\nHost kept\n    User y\n")
    let out = writer.renderFile(segments: segments, entries: [
        RenderableHost(host: "kept", properties: [SSHProperty(key: "User", values: ["y"])]),
    ])
    #expect(!out.contains("Host gone"))
    #expect(out.contains("Host kept"))
}

@Test func roundTripParseEqualityAndIdempotentSecondWrite() {
    let source = """
    # top comment
    Compression yes

    Host web staging-*
        HostName example.com
        Port=2222
        IdentityFile "~/my keys/id"

    Match all
        ForwardAgent yes
    """
    let segs1 = parser.parse(source)
    let entries = parser.hosts(in: segs1).map { RenderableHost(host: $0.pattern, properties: $0.properties) }
    let written1 = writer.renderFile(segments: segs1, entries: entries)
    let segs2 = parser.parse(written1)
    let entries2 = parser.hosts(in: segs2).map { RenderableHost(host: $0.pattern, properties: $0.properties) }
    #expect(parser.hosts(in: segs2) .map(\.pattern) == parser.hosts(in: segs1).map(\.pattern))
    #expect(parser.hosts(in: segs2).map(\.properties) == parser.hosts(in: segs1).map(\.properties))
    let written2 = writer.renderFile(segments: segs2, entries: entries2)
    #expect(written1 == written2) // byte-stable after first write
}

@Test func writeCreatesDirectoryAndSetsPermissions() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).path
    let path = dir + "/inner/config"
    try writer.write("Host web\n    User root\n", toPath: path)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir + "/inner")
    #expect((dirAttrs[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "Host web\n    User root\n")
}

@Test func overwriteKeepsStrictPermissions() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).path
    let path = dir + "/config"
    try writer.write("Host web\n    User root\n", toPath: path)
    try writer.write("Host web\n    User other\n", toPath: path)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "Host web\n    User other\n")
}

@Test func writeThroughSymlinkPreservesLink() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let realPath = dir + "/real-config"
    let linkPath = dir + "/config"
    try "Host web\n    User root\n".write(toFile: realPath, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realPath)

    try writer.write("Host web\n    User other\n", toPath: linkPath)

    let linkAttrs = try FileManager.default.attributesOfItem(atPath: linkPath)
    #expect((linkAttrs[.type] as? FileAttributeType) == .typeSymbolicLink)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkPath) == realPath)
    #expect(try String(contentsOfFile: realPath, encoding: .utf8) == "Host web\n    User other\n")
    let realAttrs = try FileManager.default.attributesOfItem(atPath: realPath)
    #expect((realAttrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
}

@Test func duplicatePatternHostSegmentsCollapse() {
    let segments = parser.parse("Host web\n    User a\n\nHost web\n    User b\n")
    let out = writer.renderFile(segments: segments, entries: [
        RenderableHost(host: "web", properties: [SSHProperty(key: "User", values: ["c"])]),
    ])
    #expect(out.components(separatedBy: "Host web").count == 2)
}
