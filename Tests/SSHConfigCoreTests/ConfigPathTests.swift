import Testing
import Foundation
@testable import SSHConfigCore

@Test func storesAndClearsPath() {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let store = ConfigPathStore(defaults: defaults)
    #expect(store.path == nil)
    store.path = "/tmp/config"
    #expect(store.path == "/tmp/config")
    store.path = nil
    #expect(store.path == nil)
}

@Test func validateExpandsTildeAndChecksDirectory() {
    let home = NSHomeDirectory()
    switch ConfigPathStore.validate("~/.ssh/config") {
    case .success(let expanded): #expect(expanded == home + "/.ssh/config")
    case .failure(let msg): Issue.record("unexpected failure: \(msg)")
    }

    if case .success = ConfigPathStore.validate("relative/path") {
        Issue.record("relative paths must fail")
    }
    if case .success = ConfigPathStore.validate("/nonexistent-dir-xyz/config") {
        Issue.record("missing parent directory must fail")
    }
    if case .success = ConfigPathStore.validate("   ") {
        Issue.record("blank must fail")
    }
}

@Test func configPathStaysInsideDotSSH() {
    let home = NSHomeDirectory()
    for outside in ["~/.zshenv", "~/.ssh/../.zshenv", home + "/.sshx/config", "/etc/ssh/ssh_config"] {
        if case .success = ConfigPathStore.validate(outside) { Issue.record("\(outside) must fail") }
    }
    if case .success = ConfigPathStore.validate("~/.ssh/config\nMatch exec x") {
        Issue.record("a line break must fail")
    }
}

@Test func managedPathCantBreakTheIncludeLine() {
    let config = "~/.ssh/config"
    #expect(ConfigPathStore.validateManaged(" ~/.ssh/sesh.conf ", configPath: config) == .success("~/.ssh/sesh.conf"))
    for bad in ["", "~/.ssh/a\nMatch exec \"x\"", "~/.ssh/my file.conf", "~/.zshenv", "~/.ssh/config",
                "~/.ssh/./config"] {
        if case .success = ConfigPathStore.validateManaged(bad, configPath: config) {
            Issue.record("\(bad.debugDescription) must fail")
        }
    }
}

@Test func configPathIsNeverAPrivateKey() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }
    try "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n"
        .write(toFile: home + "/.ssh/id_ed25519", atomically: true, encoding: .utf8)
    try "Host web\n    HostName 1.2.3.4\n".write(toFile: home + "/.ssh/config", atomically: true, encoding: .utf8)
    if case .success = ConfigPathStore.validate(home + "/.ssh/id_ed25519", home: home) {
        Issue.record("a private key must fail")
    }
    #expect(ConfigPathStore.validate(home + "/.ssh/config", home: home) == .success(home + "/.ssh/config"))
}
