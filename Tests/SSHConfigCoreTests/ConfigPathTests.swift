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
