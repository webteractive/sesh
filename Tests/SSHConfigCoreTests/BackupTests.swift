import Testing
import Foundation
@testable import SSHConfigCore

@Test func backupCopiesWithTimestampName() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try "Host web\n".write(toFile: config, atomically: true, encoding: .utf8)

    let fixed = Date(timeIntervalSince1970: 1_780_000_000)
    let backupPath = try BackupManager().backup(configPath: config, now: fixed)

    #expect(backupPath.hasPrefix(config + ".backup."))
    let stamp = backupPath.replacingOccurrences(of: config + ".backup.", with: "")
    #expect(stamp.wholeMatch(of: #/\d{4}-\d{2}-\d{2}_\d{6}/#) != nil)
    #expect(try String(contentsOfFile: backupPath, encoding: .utf8) == "Host web\n")
}

@Test func backupThrowsWhenConfigMissing() {
    #expect(throws: (any Error).self) {
        try BackupManager().backup(configPath: "/nonexistent/config")
    }
}

@Test func backupOfSymlinkedConfigSnapshotsContent() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let realPath = dir + "/real-config"
    let linkPath = dir + "/config"
    try "original\n".write(toFile: realPath, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realPath)

    let backupPath = try BackupManager().backup(configPath: linkPath)

    // Mutate the live target: a real content snapshot must not follow it.
    try "mutated\n".write(toFile: realPath, atomically: true, encoding: .utf8)

    let attrs = try FileManager.default.attributesOfItem(atPath: backupPath)
    #expect((attrs[.type] as? FileAttributeType) != .typeSymbolicLink)
    #expect(try String(contentsOfFile: backupPath, encoding: .utf8) == "original\n")
}

@Test func sameSecondBackupsDoNotOverwrite() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    let manager = BackupManager()
    let fixed = Date(timeIntervalSince1970: 1_780_000_000)

    try "first\n".write(toFile: config, atomically: true, encoding: .utf8)
    let firstBackup = try manager.backup(configPath: config, now: fixed)

    try "second\n".write(toFile: config, atomically: true, encoding: .utf8)
    let secondBackup = try manager.backup(configPath: config, now: fixed)

    #expect(firstBackup != secondBackup)
    let paths = manager.backupPaths(configPath: config)
    #expect(paths.count == 2)
    #expect(try String(contentsOfFile: firstBackup, encoding: .utf8) == "first\n")
    #expect(try String(contentsOfFile: secondBackup, encoding: .utf8) == "second\n")
}

@Test func prunesToKeepCount() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try "x\n".write(toFile: config, atomically: true, encoding: .utf8)

    let manager = BackupManager(keepCount: 3)
    for i in 0..<5 {
        _ = try manager.backup(configPath: config, now: Date(timeIntervalSince1970: 1_780_000_000 + Double(i)))
    }
    let remaining = manager.backupPaths(configPath: config)
    #expect(remaining.count == 3)
    // Newest three survive: the two oldest stamps (…_000000 offsets 0 and 1) are gone.
    let stamps = remaining.map { String($0.suffix(17)) }.sorted()
    #expect(stamps == stamps.sorted())
    #expect(!remaining.isEmpty && remaining == remaining.sorted(by: >)) // newest first
}
