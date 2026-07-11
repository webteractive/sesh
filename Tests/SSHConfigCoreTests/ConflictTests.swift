import Testing
import Foundation
import SwiftData
@testable import SSHConfigCore

private func writeTemp(_ content: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/config"
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@MainActor @Test func detectsAllThreeConflictKinds() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "differs",
                         properties: [SSHProperty(key: "User", values: ["storeuser"])],
                         rawBlock: nil))
    ctx.insert(HostEntry(host: "storeonly", properties: [], rawBlock: nil))
    try ctx.save()
    let path = try writeTemp("""
    Host differs
        User fileuser

    Host fileonly
        User x
    """)

    let conflicts = try ConflictDetector().detect(path: path, context: ctx)
    let bySource = Dictionary(grouping: conflicts, by: \.source)

    #expect(bySource[.both]?.map(\.host) == ["differs"])
    #expect(bySource[.both]?[0].fileProperties?.first("User") == "fileuser")
    #expect(bySource[.both]?[0].storeProperties?.first("User") == "storeuser")
    #expect(bySource[.store]?.map(\.host) == ["storeonly"])
    #expect(bySource[.file]?.map(\.host) == ["fileonly"])
}

@MainActor @Test func duplicateFileStanzasProduceOneConflict() throws {
    let ctx = try makeContext()
    let path = try writeTemp("""
    Host dup
        User first

    Host dup
        User second
    """)

    let conflicts = try ConflictDetector().detect(path: path, context: ctx)

    #expect(conflicts.count == 1)
    #expect(conflicts[0].source == .file)
    #expect(conflicts[0].fileProperties?.first("User") == "first")
}

@MainActor @Test func identicalHostsProduceNoConflict() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "same",
                         properties: [SSHProperty(key: "User", values: ["root"])],
                         rawBlock: nil))
    try ctx.save()
    let path = try writeTemp("Host same\n    User root\n")
    #expect(try ConflictDetector().detect(path: path, context: ctx).isEmpty)
}

@MainActor @Test func renameUpdatesExistingEntry() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "old", properties: [], rawBlock: nil))
    try ctx.save()

    try ConflictResolver().rename(host: "old", to: "new", updateExisting: true, context: ctx)

    let hosts = try ctx.fetch(FetchDescriptor<HostEntry>()).map(\.host)
    #expect(hosts == ["new"])
}

@MainActor @Test func renameKeepBothDuplicates() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "old",
                         properties: [SSHProperty(key: "User", values: ["root"])],
                         rawBlock: nil))
    try ctx.save()

    try ConflictResolver().rename(host: "old", to: "new", updateExisting: false, context: ctx)

    let all = try ctx.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.host)]))
    #expect(all.map(\.host) == ["new", "old"])
    #expect(all[0].properties.first("User") == "root")
}

@MainActor @Test func renameMissingHostThrows() throws {
    let ctx = try makeContext()
    #expect(throws: (any Error).self) {
        try ConflictResolver().rename(host: "ghost", to: "x", updateExisting: true, context: ctx)
    }
}

@MainActor @Test func renameToExistingHostThrows() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "old",
                         properties: [SSHProperty(key: "User", values: ["root"])],
                         rawBlock: nil))
    ctx.insert(HostEntry(host: "taken",
                         properties: [SSHProperty(key: "User", values: ["admin"])],
                         rawBlock: nil))
    try ctx.save()

    #expect(throws: (any Error).self) {
        try ConflictResolver().rename(host: "old", to: "taken", updateExisting: true, context: ctx)
    }
    #expect(throws: (any Error).self) {
        try ConflictResolver().rename(host: "old", to: "taken", updateExisting: false, context: ctx)
    }

    let all = try ctx.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.host)]))
    #expect(all.map(\.host) == ["old", "taken"])
    #expect(all.first(where: { $0.host == "old" })?.properties.first("User") == "root")
    #expect(all.first(where: { $0.host == "taken" })?.properties.first("User") == "admin")
}

@MainActor @Test func renameToSameNameSucceeds() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "old",
                         properties: [SSHProperty(key: "User", values: ["root"])],
                         rawBlock: nil))
    try ctx.save()

    try ConflictResolver().rename(host: "old", to: "old", updateExisting: true, context: ctx)

    let all = try ctx.fetch(FetchDescriptor<HostEntry>())
    #expect(all.map(\.host) == ["old"])
    #expect(all[0].properties.first("User") == "root")
}

@MainActor @Test func acceptFileVersionUpsertsStore() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "differs",
                         properties: [SSHProperty(key: "User", values: ["storeuser"])],
                         rawBlock: nil))
    try ctx.save()
    let conflict = Conflict(host: "differs", source: .both,
                            fileProperties: [SSHProperty(key: "User", values: ["fileuser"])],
                            storeProperties: nil)

    try ConflictResolver().acceptFileVersion(conflict, context: ctx)

    let entry = try ctx.fetch(FetchDescriptor<HostEntry>()).first
    #expect(entry?.properties.first("User") == "fileuser")
}
