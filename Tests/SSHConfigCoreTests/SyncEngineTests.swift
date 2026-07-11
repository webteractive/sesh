import Testing
import Foundation
import SwiftData
@testable import SSHConfigCore

private func tempConfig(_ content: String?) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/config"
    if let content { try content.write(toFile: path, atomically: true, encoding: .utf8) }
    return path
}

@MainActor @Test func fromFileCreatesAndUpdates() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "web",
                         properties: [SSHProperty(key: "User", values: ["old"])],
                         rawBlock: nil))
    try ctx.save()
    let path = try tempConfig("Host web\n    User root\n\nHost db\n    User admin\n")

    let items = try SyncEngine().syncFromFile(path: path, context: ctx)

    #expect(Set(items.map(\.id)) == ["webupdated", "dbcreated"])
    let all = try ctx.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.host)]))
    #expect(all.map(\.host) == ["db", "web"])
    #expect(all[1].properties.first("User") == "root") // file wins
    #expect(all[1].rawBlock?.contains("Host web") == true)
}

@MainActor @Test func fromFileNoChangesReportsNothing() throws {
    let ctx = try makeContext()
    let path = try tempConfig("Host web\n    User root\n")
    _ = try SyncEngine().syncFromFile(path: path, context: ctx)
    let again = try SyncEngine().syncFromFile(path: path, context: ctx)
    #expect(again.isEmpty)
}

@MainActor @Test func duplicateHostStanzasFirstOccurrenceWins() throws {
    let ctx = try makeContext()
    let path = try tempConfig("Host web\n    User a\n\nHost web\n    User b\n")

    let items = try SyncEngine().syncFromFile(path: path, context: ctx)

    #expect(Set(items.map(\.id)) == ["webcreated"])
    let all = try ctx.fetch(FetchDescriptor<HostEntry>())
    #expect(all.count == 1)
    #expect(all.first?.properties.first("User") == "a")
}

@MainActor @Test func fromFileMissingFileReturnsEmpty() throws {
    let ctx = try makeContext()
    let items = try SyncEngine().syncFromFile(path: "/nonexistent/config", context: ctx)
    #expect(items.isEmpty)
}

@MainActor @Test func toFileWritesStoreAndBacksUp() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "web",
                         properties: [SSHProperty(key: "HostName", values: ["example.com"])],
                         rawBlock: nil))
    try ctx.save()
    let path = try tempConfig("# keep me\nCompression yes\n\nHost stale\n    User x\n")

    try SyncEngine().syncToFile(path: path, context: ctx)

    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.contains("# keep me"))          // prologue preserved
    #expect(text.contains("Host web"))           // store host written
    #expect(!text.contains("Host stale"))        // file-only host dropped (Laravel parity)
    #expect(BackupManager().backupPaths(configPath: path).count == 1)
}

@MainActor @Test func toFileCreatesMissingFileWithoutBackup() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "web", properties: [], rawBlock: nil))
    try ctx.save()
    let path = try tempConfig(nil) // directory exists, file doesn't

    try SyncEngine().syncToFile(path: path, context: ctx)

    #expect(FileManager.default.fileExists(atPath: path))
    #expect(BackupManager().backupPaths(configPath: path).isEmpty)
}

@MainActor @Test func toFileWithLatin1CommentPreservesSegments() throws {
    let ctx = try makeContext()
    try ctx.save()

    // Latin-1-only byte (0xE9 = 'é') in the prologue comment, followed by a
    // Match block. If parseFile silently treated this file as unreadable and
    // returned [], syncToFile would rewrite the file with only store hosts
    // (none, here) and destroy the Match block entirely.
    var bytes = Array("# caf".utf8)
    bytes.append(0xE9)
    bytes.append(contentsOf: Array(" note\n\nMatch host *.internal\n    ProxyJump bastion\n".utf8))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/config"
    try Data(bytes).write(to: URL(fileURLWithPath: path))

    try SyncEngine().syncToFile(path: path, context: ctx)

    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.contains("Match host *.internal"))
    #expect(text.contains("ProxyJump bastion"))
}

@MainActor @Test func bothFileWinsAndStoreOnlyAppended() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "web",
                         properties: [SSHProperty(key: "User", values: ["stale"])],
                         rawBlock: nil))
    ctx.insert(HostEntry(host: "storeonly",
                         properties: [SSHProperty(key: "User", values: ["me"])],
                         rawBlock: nil))
    try ctx.save()
    let path = try tempConfig("Host web\n    User root\n")

    let items = try SyncEngine().syncBoth(path: path, context: ctx)

    #expect(Set(items.map(\.id)) == ["webupdated", "storeonlyaddedToFile"])
    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.contains("Host storeonly"))
    let web = try ctx.fetch(FetchDescriptor<HostEntry>()).first { $0.host == "web" }
    #expect(web?.properties.first("User") == "root") // file won
}
