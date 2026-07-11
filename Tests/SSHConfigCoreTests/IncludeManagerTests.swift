import Testing
import Foundation
@testable import SSHConfigCore

private func tempDir() -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@Test func ensureIncludeAddsLineOnceAndIsIdempotent() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try "Host existing\n    User me\n".write(toFile: config, atomically: true, encoding: .utf8)
    let mgr = IncludeManager()

    let added1 = try mgr.ensureInclude(managedPath: "~/.ssh/sesh.conf", configPath: config)
    #expect(added1 == true)
    let text = try String(contentsOfFile: config, encoding: .utf8)
    #expect(text.hasPrefix("Include ~/.ssh/sesh.conf"))
    #expect(text.contains("Host existing"))          // original content preserved
    #expect(text.contains("    User me"))

    let added2 = try mgr.ensureInclude(managedPath: "~/.ssh/sesh.conf", configPath: config)
    #expect(added2 == false)                          // idempotent
    let text2 = try String(contentsOfFile: config, encoding: .utf8)
    #expect(text2.components(separatedBy: "Include ~/.ssh/sesh.conf").count == 2) // exactly one occurrence
}

@Test func ensureIncludeBacksUpBeforeEditing() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try "Host a\n".write(toFile: config, atomically: true, encoding: .utf8)
    _ = try IncludeManager().ensureInclude(managedPath: "~/.ssh/sesh.conf", configPath: config)
    #expect(BackupManager().backupPaths(configPath: config).count == 1)
}

@Test func ensureIncludeCreatesConfigWhenAbsent() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"    // does not exist yet
    let added = try IncludeManager().ensureInclude(managedPath: "~/.ssh/sesh.conf", configPath: config)
    #expect(added == true)
    let attrs = try FileManager.default.attributesOfItem(atPath: config)
    #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    #expect(try String(contentsOfFile: config, encoding: .utf8).contains("Include ~/.ssh/sesh.conf"))
}

@Test func hasIncludeDetectsPresence() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    let mgr = IncludeManager()
    try "Host a\n".write(toFile: config, atomically: true, encoding: .utf8)
    #expect(mgr.hasInclude(managedPath: "~/.ssh/sesh.conf", configPath: config) == false)
    _ = try mgr.ensureInclude(managedPath: "~/.ssh/sesh.conf", configPath: config)
    #expect(mgr.hasInclude(managedPath: "~/.ssh/sesh.conf", configPath: config) == true)
}

@Test func ensureIncludeIdempotentWithCRLFConfig() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try "Include ~/.ssh/sesh.conf\r\nHost a\r\n".write(toFile: config, atomically: true, encoding: .utf8)
    let mgr = IncludeManager()

    let added = try mgr.ensureInclude(managedPath: "~/.ssh/sesh.conf", configPath: config)
    #expect(added == false)                           // already present despite trailing \r
    let text = try String(contentsOfFile: config, encoding: .utf8)
    #expect(text.components(separatedBy: "Include ~/.ssh/sesh.conf").count == 2) // exactly one occurrence
}

/// A non-UTF-8 byte (e.g. latin-1) previously made `try? String(contentsOfFile:
/// encoding: .utf8)` return nil, which the old code coalesced to "", making
/// the "already present?" check pass on an empty string and writing ONLY the
/// Include line — destroying the user's config. ensureInclude must instead
/// preserve the original bytes verbatim and only prepend the Include line.
@Test func ensureIncludePreservesLatin1Config() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    // 0xE9 is not valid UTF-8 on its own, but decodes fine as latin-1 (é).
    var raw = Data("# caf".utf8)
    raw.append(0xE9)
    raw.append(contentsOf: Data("\nHost a\n    User me\n".utf8))
    try raw.write(to: URL(fileURLWithPath: config))
    let mgr = IncludeManager()

    let added1 = try mgr.ensureInclude(managedPath: "~/.ssh/sesh.conf", configPath: config)
    #expect(added1 == true)

    let after1 = try Data(contentsOf: URL(fileURLWithPath: config))
    #expect(after1.contains(0xE9))                    // original byte preserved
    let text1 = String(data: after1, encoding: .isoLatin1) ?? ""
    #expect(text1.contains("Host a"))
    #expect(text1.components(separatedBy: "Include ~/.ssh/sesh.conf").count == 2) // exactly one occurrence

    let added2 = try mgr.ensureInclude(managedPath: "~/.ssh/sesh.conf", configPath: config)
    #expect(added2 == false)                          // idempotent, no duplicate

    let after2 = try Data(contentsOf: URL(fileURLWithPath: config))
    #expect(after2.contains(0xE9))                    // still preserved
    let text2 = String(data: after2, encoding: .isoLatin1) ?? ""
    #expect(text2.components(separatedBy: "Include ~/.ssh/sesh.conf").count == 2) // still exactly one
}
