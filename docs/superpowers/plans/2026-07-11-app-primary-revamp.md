# App-Primary Revamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Invert Sesh to an app-primary model: the SwiftData store is authoritative, the app exports to an app-owned `~/.ssh/sesh.conf` (linked into `~/.ssh/config` via one `Include`), connects via `ssh://`, and the old file-sync/conflict system is removed.

**Architecture:** Add Core `ConfigExporter` + `IncludeManager` + `ConfigImporter` (pure, tested), simplify `TerminalRegistry`/`TerminalLauncher` to `ssh://`-scheme opening, rewrite `AppModel` to export-on-change + `ssh://` connect + relocated empty store, strip the sync/conflict UI, then delete `SyncEngine`/`Conflicts` and their tests. Build stays green after every task by adding before removing.

**Tech Stack:** Swift (language mode v5), SwiftUI (macOS 15), SwiftData, swift-testing, Tuist. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-11-app-primary-revamp-design.md` — read it first.

## Global Constraints

- Repo `/Users/glenbangkila/AI/sshconfig-swift`, main branch. Tests: `swift test`. App build: `tuist generate --no-open && tuist build Sesh` (scheme is **Sesh**). Bundle id `co.webteractive.sesh`.
- Core (`Sources/SSHConfigCore/**`) imports Foundation/SwiftData only — no SwiftUI/AppKit.
- Managed file default `~/.ssh/sesh.conf`; config default `~/.ssh/config`. The app **never** rewrites existing blocks in `~/.ssh/config` — only adds one idempotent `Include ~/.ssh/sesh.conf` line (backup first).
- Connect targets `ssh://<alias>` when the managed file is active, else `ssh://[user@]hostname[:port]`. `HostValidation.isSafeToLaunch` guards the alias/host.
- Store relocates to `~/Library/Application Support/Sesh/Sesh.store` (fresh empty start; old default store left untouched).
- **Pragmatic deviation from spec:** `HostEntry.rawBlock` is KEPT (unused optional) rather than removed — dropping it would churn ~10 call sites + tests for zero benefit on a fresh store. New entries pass `rawBlock: nil`.
- Git commits: NO `Co-Authored-By`, NO `Claude-Session:` lines, never push. Commits approved.

---

### Task 1: Core — `ConfigExporter`, `IncludeManager`, `ConfigImporter`

**Files:**
- Create: `Sources/SSHConfigCore/ConfigExporter.swift`
- Create: `Sources/SSHConfigCore/IncludeManager.swift`
- Create: `Sources/SSHConfigCore/ConfigImporter.swift`
- Test: `Tests/SSHConfigCoreTests/ConfigExporterTests.swift`
- Test: `Tests/SSHConfigCoreTests/IncludeManagerTests.swift`
- Test: `Tests/SSHConfigCoreTests/ConfigImporterTests.swift`

**Interfaces:**
- Consumes: `SSHConfigWriter` (`render(host:properties:)`, `write(_:toPath:)`), `RenderableHost`, `SSHProperty`, `SSHConfigParser` (`parseFile(at:)`, `hosts(in:)`), `BackupManager`, `ParsedHost`.
- Produces:
  - `struct ConfigExporter { init(); static let managedHeader: String; func render(_ hosts: [RenderableHost]) -> String; func write(_ hosts: [RenderableHost], toPath: String) throws }`
  - `struct IncludeManager { init(); func includeLine(managedPath: String) -> String; func hasInclude(managedPath: String, configPath: String) -> Bool; @discardableResult func ensureInclude(managedPath: String, configPath: String) throws -> Bool }`
  - `struct ImportedHost: Equatable, Sendable { let alias: String; let properties: [SSHProperty] }`
  - `struct ConfigImporter { init(); func hosts(inConfigAt path: String, managedPath: String) -> [ImportedHost] }`

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/ConfigExporterTests.swift`**

```swift
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
```

- [ ] **Step 2: Write failing tests — `Tests/SSHConfigCoreTests/IncludeManagerTests.swift`**

```swift
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
```

- [ ] **Step 3: Write failing tests — `Tests/SSHConfigCoreTests/ConfigImporterTests.swift`**

```swift
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
```

- [ ] **Step 4: Run to verify failure**

Run: `swift test --filter ConfigExporterTests`
Expected: FAIL — `cannot find 'ConfigExporter'`.

- [ ] **Step 5: Implement `Sources/SSHConfigCore/ConfigExporter.swift`**

```swift
import Foundation

/// Renders the store into the app-owned managed include file. The file is 100%
/// app-authored (no foreign segments to preserve), so this is a straight
/// render of every host block, not the segment-preserving writer path.
public struct ConfigExporter {
    public static let managedHeader = """
    # Managed by Sesh — do not edit by hand.
    # Your hosts live in the Sesh app; this file is regenerated on every change.
    """

    private let writer = SSHConfigWriter()

    public init() {}

    public func render(_ hosts: [RenderableHost]) -> String {
        let blocks = hosts.map { writer.render(host: $0.host, properties: $0.properties) }
        return ([Self.managedHeader] + blocks).joined(separator: "\n\n") + "\n"
    }

    public func write(_ hosts: [RenderableHost], toPath path: String) throws {
        try writer.write(render(hosts), toPath: path)
    }
}
```

- [ ] **Step 6: Implement `Sources/SSHConfigCore/IncludeManager.swift`**

```swift
import Foundation

/// Links the managed file into ~/.ssh/config with a single idempotent Include
/// line, never touching existing blocks.
public struct IncludeManager {
    private let backups = BackupManager()

    public init() {}

    public func includeLine(managedPath: String) -> String { "Include \(managedPath)" }

    public func hasInclude(managedPath: String, configPath: String) -> Bool {
        let expanded = (configPath as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else { return false }
        let line = includeLine(managedPath: managedPath)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == line }
    }

    /// Returns true if it added the line, false if it was already present.
    @discardableResult
    public func ensureInclude(managedPath: String, configPath: String) throws -> Bool {
        let expanded = (configPath as NSString).expandingTildeInPath
        let line = includeLine(managedPath: managedPath)

        let existing = (try? String(contentsOfFile: expanded, encoding: .utf8)) ?? ""
        if existing.split(separator: "\n", omittingEmptySubsequences: false)
            .contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) {
            return false
        }
        if FileManager.default.fileExists(atPath: expanded) {
            try backups.backup(configPath: expanded)   // backup before editing
        } else {
            let dir = (expanded as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: dir) {
                try FileManager.default.createDirectory(atPath: dir,
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        // Include at the top so managed aliases resolve regardless of any
        // `Host *` defaults later in the user's file.
        let body = existing.isEmpty ? line + "\n" : line + "\n\n" + existing
        try body.write(toFile: expanded, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expanded)
        return true
    }
}
```

- [ ] **Step 7: Implement `Sources/SSHConfigCore/ConfigImporter.swift`**

```swift
import Foundation

public struct ImportedHost: Equatable, Sendable {
    public let alias: String
    public let properties: [SSHProperty]
    public init(alias: String, properties: [SSHProperty]) {
        self.alias = alias
        self.properties = properties
    }
}

/// One-way, additive read of the user's ~/.ssh/config into importable hosts.
public struct ConfigImporter {
    private let parser = SSHConfigParser()

    public init() {}

    public func hosts(inConfigAt path: String, managedPath: String) -> [ImportedHost] {
        parser.hosts(in: parser.parseFile(at: path))
            .map { ImportedHost(alias: $0.pattern, properties: $0.properties) }
    }
}
```

(`parser.hosts(in:)` already yields only `Host` blocks — `Match`/`Include`/prologue segments are excluded by construction — so no extra filtering is needed to satisfy the test.)

- [ ] **Step 8: Run tests**

Run: `swift test`
Expected: all existing tests plus the new Exporter/Include/Importer tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): config exporter, include manager, and importer"
```

---

### Task 2: Core/App — simplify Terminal handling to ssh:// opening

**Files:**
- Modify: `Sources/SSHConfigCore/TerminalRegistry.swift`
- Modify: `Tests/SSHConfigCoreTests/TerminalRegistryTests.swift`
- Modify: `App/Sources/TerminalLauncher.swift`

**Interfaces:**
- Produces:
  - `TerminalRegistry.known: [Terminal]` limited to `systemDefault`, `com.apple.Terminal`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`; `LaunchPlan` reduced to `case systemDefault, sshURL`. `arguments(for:host:)` is removed.
  - `TerminalLauncher.open(_ url: URL, with terminal: Terminal, onAsyncError:)` opens an already-built `ssh://` URL (system default via `NSWorkspace.open(url)`, else `open([url], withApplicationAt:)`). `detectInstalled()` keeps filtering by installed bundle id. The old `launch(_:host:onAsyncError:)`, `.openArgs`/`.zettyCLI` handling, `zettyCLI*`, and `scratchPaneId` are deleted.

- [ ] **Step 1: Update `TerminalRegistry.swift`**

Reduce `LaunchPlan` and `known`, delete `arguments(for:)`:

```swift
public enum LaunchPlan: Equatable, Sendable {
    case systemDefault   // NSWorkspace.open(ssh://…) — whatever handles the scheme
    case sshURL          // open ssh://… WITH this specific ssh://-registering app
}

public enum TerminalRegistry {
    public static let systemDefaultId = "system-default"

    public static let known: [Terminal] = [
        Terminal(id: systemDefaultId, name: "System Default", launchPlan: .systemDefault),
        Terminal(id: "com.apple.Terminal", name: "Terminal", launchPlan: .sshURL),
        Terminal(id: "com.googlecode.iterm2", name: "iTerm2", launchPlan: .sshURL),
        Terminal(id: "dev.warp.Warp-Stable", name: "Warp", launchPlan: .sshURL),
    ]

    public static func terminal(withId id: String) -> Terminal? { known.first { $0.id == id } }
}
```

- [ ] **Step 2: Update `TerminalRegistryTests.swift`**

Replace the argv-substitution tests with:

```swift
import Testing
@testable import SSHConfigCore

@Test func knownTerminalsAreSshURLCapableWithSystemDefaultFirst() {
    let ids = TerminalRegistry.known.map(\.id)
    #expect(ids.first == TerminalRegistry.systemDefaultId)
    #expect(Set(ids).count == ids.count)
    #expect(ids == ["system-default", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"])
    // no argv terminals remain
    #expect(!ids.contains("dev.more.zetty"))
    #expect(!ids.contains("com.mitchellh.ghostty"))
}

@Test func lookupByIdAndMiss() {
    #expect(TerminalRegistry.terminal(withId: "com.apple.Terminal")?.name == "Terminal")
    #expect(TerminalRegistry.terminal(withId: "nope") == nil)
}

@Test func launchPlansAreUrlBased() {
    #expect(TerminalRegistry.terminal(withId: "system-default")?.launchPlan == .systemDefault)
    #expect(TerminalRegistry.terminal(withId: "com.apple.Terminal")?.launchPlan == .sshURL)
}
```

- [ ] **Step 3: Rewrite `App/Sources/TerminalLauncher.swift`**

```swift
import AppKit
import Foundation
import SSHConfigCore

@MainActor
struct TerminalLauncher {
    enum LaunchError: LocalizedError {
        case notInstalled(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled(let name): "\(name) is not installed."
            }
        }
    }

    func detectInstalled() -> [Terminal] {
        TerminalRegistry.known.filter { terminal in
            switch terminal.launchPlan {
            case .systemDefault: true
            case .sshURL: appURL(for: terminal.id) != nil
            }
        }
    }

    /// Opens an already-built ssh:// URL with the chosen handler. Async open
    /// failures are reported via onAsyncError on the main actor.
    func open(_ url: URL, with terminal: Terminal,
              onAsyncError: @escaping @MainActor @Sendable (String) -> Void) throws {
        switch terminal.launchPlan {
        case .systemDefault:
            NSWorkspace.shared.open(url)
        case .sshURL:
            guard let app = appURL(for: terminal.id) else {
                throw LaunchError.notInstalled(terminal.name)
            }
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                Task { @MainActor in onAsyncError("Couldn't open \(terminal.name): \(error.localizedDescription)") }
            }
        }
    }

    private func appURL(for bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }
}
```

- [ ] **Step 4: Build + test**

Run: `swift test && tuist generate --no-open && tuist build Sesh 2>&1 | tail -1`
Expected: Core tests pass; **app build FAILS** because `AppModel.connect` still calls the old `launch(_:host:...)`. That's expected — Task 3 fixes AppModel. (If you want a green checkpoint, do Step 5's commit after confirming `swift test` passes; the app target compiles green again at the end of Task 3.)

- [ ] **Step 5: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests App/Sources/TerminalLauncher.swift
git commit -m "refactor(core): reduce terminal handling to ssh:// scheme opening"
```

---

### Task 3: App — rewrite `AppModel` for app-primary export + ssh:// connect

**Files:**
- Modify: `App/Sources/AppModel.swift`

**Interfaces:**
- Consumes: `ConfigExporter`, `IncludeManager`, `ConfigImporter`/`ImportedHost` (Task 1), `TerminalLauncher.open` (Task 2), `HostEntry`, `HostValidation`, `ConfigPathStore`, `RenderableHost`.
- Produces (Tasks 4 relies on these): `AppModel.container` at the new URL; `configPath`, `managedPath`; `exportNow()`; `importFromConfig() -> (added: Int, skipped: Int)?` (nil-less; returns counts, sets pendingError on failure); `managedFileActive: Bool`; `linkInclude() -> String?`; `connect(_ entry: HostEntry, with terminal: Terminal? = nil)`; `installedTerminals`/`selectableTerminals`/`preferredTerminal`/`preferredTerminalId` (unchanged); `copyCommand`; `pendingError`, `showFirstRun`. Removed: `runSync`, `syncItems`, `conflicts`, `showSyncSheet`, `engine`, `detector`, `resolver`, `autoSyncToFile`, `SyncMode`, `refreshConflicts`.

- [ ] **Step 1: Relocate the container**

Replace the `static let container` body so it uses an explicit URL (creating the dir):

```swift
    static let container: ModelContainer = {
        do {
            let dir = URL.applicationSupportDirectory.appending(path: "Sesh", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let config = ModelConfiguration(url: dir.appending(path: "Sesh.store"))
            return try ModelContainer(for: HostEntry.self, configurations: config)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }()
```

- [ ] **Step 2: Swap services + managed path**

Remove `engine`/`detector`/`resolver`. Add:

```swift
    private let exporter = ConfigExporter()
    private let includeManager = IncludeManager()
    private let importer = ConfigImporter()

    static let managedPathKey = "managedConfigPath"
    var managedPath: String {
        get { UserDefaults.standard.string(forKey: Self.managedPathKey) ?? "~/.ssh/sesh.conf" }
        set { UserDefaults.standard.set(newValue, forKey: Self.managedPathKey) }
    }
```

Keep `SyncMode` deletion for Task 4 (it lives in this file — delete the enum and `runSync`, `syncItems`, `conflicts`, `showSyncSheet`, `refreshConflicts` now; Task 4 removes their UI users).

- [ ] **Step 3: Export, import, include, connect**

```swift
    /// Renders the whole store to the managed file and ensures the Include.
    /// Store is the source of truth, so failures only warn (file is rebuildable).
    func exportNow() {
        do {
            let entries = try context.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.createdAt)]))
                .map { RenderableHost(host: $0.host, properties: $0.properties) }
            try exporter.write(entries, toPath: managedPath)
            try includeManager.ensureInclude(managedPath: managedPath, configPath: configPath ?? ConfigPathStore.defaultSuggestion)
        } catch {
            pendingError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Adds hosts from ~/.ssh/config that aren't already in the store (by alias).
    @discardableResult
    func importFromConfig() -> (added: Int, skipped: Int) {
        let path = configPath ?? ConfigPathStore.defaultSuggestion
        let existing = Set((try? context.fetch(FetchDescriptor<HostEntry>()))?.map(\.host) ?? [])
        var added = 0, skipped = 0
        for host in importer.hosts(inConfigAt: path, managedPath: managedPath) {
            if existing.contains(host.alias) { skipped += 1; continue }
            context.insert(HostEntry(host: host.alias, properties: host.properties, rawBlock: nil))
            added += 1
        }
        do { try context.save(); exportNow() }
        catch { context.rollback(); pendingError = error.localizedDescription }
        return (added, skipped)
    }

    var managedFileActive: Bool {
        let path = configPath ?? ConfigPathStore.defaultSuggestion
        return includeManager.hasInclude(managedPath: managedPath, configPath: path)
            && FileManager.default.fileExists(atPath: (managedPath as NSString).expandingTildeInPath)
    }

    @discardableResult
    func linkInclude() -> String? {
        do { try includeManager.ensureInclude(managedPath: managedPath,
                                              configPath: configPath ?? ConfigPathStore.defaultSuggestion); return nil }
        catch { return error.localizedDescription }
    }

    func connect(_ entry: HostEntry, with terminal: Terminal? = nil) {
        guard HostValidation.isSafeToLaunch(entry.host) else {
            pendingError = "'\(entry.host)' isn't a safe alias to connect."
            return
        }
        guard let url = connectURL(for: entry) else {
            pendingError = "Couldn't build a connection URL for '\(entry.host)'."
            return
        }
        do {
            try launcher.open(url, with: terminal ?? preferredTerminal) { [weak self] msg in
                self?.pendingError = msg
            }
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// ssh://<alias> when the managed file is active; otherwise a direct
    /// ssh://[user@]hostname[:port] built from the entry's properties.
    private func connectURL(for entry: HostEntry) -> URL? {
        if managedFileActive {
            return URL(string: "ssh://\(entry.host)")
        }
        let host = entry.properties.first("HostName") ?? entry.host
        var s = "ssh://"
        if let user = entry.properties.first("User"),
           let enc = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) {
            s += "\(enc)@"
        }
        s += host
        if let port = entry.properties.first("Port") { s += ":\(port)" }
        return URL(string: s)
    }
```

Rename the existing `terminalLauncher` property usage to `launcher` (or keep `terminalLauncher` and use it — match the current name; the snippet uses `launcher`, adapt to the actual property name). Remove the old `connect(_ host: String, with:)` string-based method and `autoSyncToFile()`.

- [ ] **Step 4: Update `init`/`onLaunch`**

Keep `migrateLegacyPreferencesIfNeeded()` and `refreshTerminals()`. `onLaunch()` no longer decides sync; keep `showFirstRun = (configPath == nil)` OR change first-run to also cover "not yet linked". Minimal: leave `showFirstRun = (configPath == nil)`.

- [ ] **Step 5: Build + test**

Run: `tuist generate --no-open && tuist build Sesh 2>&1 | tail -1`
Expected: still FAILS — the views (MainWindow/SyncSheet/HostDetailView/MenuBarView/CommandPalette) reference removed symbols (`runSync`, `SyncMode`, `connect(host:)`, `autoSyncToFile`). Task 4 fixes them. `swift test` should pass (Core unaffected). Do not commit a broken app build alone — combine with Task 4, OR commit now and fix in Task 4 (the branch is mid-refactor; acceptable since tasks are sequential). Choose: **commit now** to checkpoint AppModel.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/AppModel.swift
git commit -m "feat(app): app-primary AppModel — export, import, ssh:// connect, relocated store"
```

---

### Task 4: App UI — remove sync/conflict, wire export/import/connect

**Files:**
- Delete: `App/Sources/Views/SyncSheet.swift`
- Modify: `App/Sources/Views/MainWindow.swift`
- Modify: `App/Sources/Views/SettingsSheet.swift`
- Modify: `App/Sources/Views/HostDetailView.swift`
- Modify: `App/Sources/Views/MenuBarView.swift`
- Modify: `App/Sources/Views/CommandPalette.swift`
- Modify: `App/Sources/Views/RawConfigView.swift`
- Modify: `App/Sources/Views/FirstRunSheet.swift`

**Interfaces:**
- Consumes: the new `AppModel` API (Task 3).

- [ ] **Step 1: Delete SyncSheet and its usages**

`rm App/Sources/Views/SyncSheet.swift`. In `MainWindow.swift`: remove the Sync `Menu` toolbar item, the `.sheet(isPresented: $model.showSyncSheet) { SyncSheet() }`, and any `SyncMode` references. Every `model.autoSyncToFile()` call becomes `model.exportNow()`. Every `model.connect(entry.host)` / `connect(alias)` becomes `model.connect(entry)` (or resolve the alias to its `HostEntry` and pass the entry) — connect is now entry-based. In `CommandPalette`/`MenuBarView`, the `onHost`/connect closures currently pass an alias string; change them to pass the resolved `HostEntry` to `model.connect(_:)` (they already resolve entries via `model.entry(forAlias:in:)`).

- [ ] **Step 2: Toolbar + Import action (MainWindow)**

Replace the Sync toolbar item with an **Import** button that calls `model.importFromConfig()` and surfaces the count (e.g. set a transient `pendingError`-style info, or a small alert "Imported N hosts (M already present)"). Keep Raw Config + Settings + New Host items.

- [ ] **Step 3: Settings (SettingsSheet)**

Add: managed-file path field (default `~/.ssh/sesh.conf`, bound to `model.managedPath`); an Include status row — if `model.managedFileActive` show "Linked into ~/.ssh/config ✓", else a **Link into ~/.ssh/config** button calling `model.linkInclude()`; keep the config-path field (used for import + include target) and the ssh:// Connect-with picker over `model.selectableTerminals`. Add an **Import from ~/.ssh/config** button here too.

- [ ] **Step 4: Connect routing (HostDetailView, MenuBarView, CommandPalette)**

Update all connect call sites to `model.connect(entry)` / `model.connect(entry, with: terminal)`. The per-terminal submenus now iterate `model.selectableTerminals` (ssh:// apps only). Copy stays `model.copyCommand(entry)`.

- [ ] **Step 5: Raw viewer + first run**

`RawConfigView`: show `model.managedPath`'s contents (the sesh.conf) instead of the main config; update the caption to the managed path. `FirstRunSheet`: reframe from "set path then sync" to "set your ~/.ssh/config path (for linking + import)"; on save, call `saveConfigPath` then `model.linkInclude()`; the empty store shows New Host / Import affordances (ContentUnavailableView already covers empty selection — ensure an empty host list reads sensibly).

- [ ] **Step 6: Build + test**

Run: `tuist generate --no-open && tuist build Sesh 2>&1 | tail -1 && swift test 2>&1 | tail -1`
Expected: BUILD SUCCEEDED; Core tests pass. Launch headlessly to confirm no crash.

- [ ] **Step 7: Commit**

```bash
git add App
git commit -m "feat(app): app-primary UI — export/import/link, ssh:// connect, drop sync UI"
```

---

### Task 5: Core cleanup — delete SyncEngine & Conflicts

**Files:**
- Delete: `Sources/SSHConfigCore/SyncEngine.swift`
- Delete: `Sources/SSHConfigCore/Conflicts.swift`
- Delete: `Tests/SSHConfigCoreTests/SyncEngineTests.swift`
- Delete: `Tests/SSHConfigCoreTests/ConflictTests.swift`

**Interfaces:** none new. Verify no remaining references.

- [ ] **Step 1: Confirm nothing references the removed types**

Run: `grep -rn "SyncEngine\|ConflictDetector\|ConflictResolver\|SyncItem\|\bConflict\b" Sources App --include=*.swift`
Expected: no matches (only in the files about to be deleted, if any). If the app still references them, fix those call sites first.

- [ ] **Step 2: Delete the files**

```bash
git rm Sources/SSHConfigCore/SyncEngine.swift Sources/SSHConfigCore/Conflicts.swift \
       Tests/SSHConfigCoreTests/SyncEngineTests.swift Tests/SSHConfigCoreTests/ConflictTests.swift
```

- [ ] **Step 3: Build + test**

Run: `swift test 2>&1 | tail -1 && tuist generate --no-open && tuist build Sesh 2>&1 | tail -1`
Expected: tests pass (minus the deleted suites), BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git commit -m "chore(core): remove sync engine and conflict resolution (app-primary)"
```

---

### Task 6: Wrap-up — version, README, build, install

**Files:**
- Modify: `Project.swift` (0.5.0 → 0.6.0)
- Modify: `README.md`

- [ ] **Step 1: Bump `CFBundleShortVersionString` to `0.6.0` in `Project.swift`.**

- [ ] **Step 2: README** — replace the sync/conflict + terminal-aware bullets with: app-primary store; exports to `~/.ssh/sesh.conf` linked via one `Include`; connect via `ssh://`; optional import from `~/.ssh/config`. Note the config file is never rewritten (only the Include line).

- [ ] **Step 3: Full verification**

Run: `swift test && tuist generate --no-open && tuist build Sesh`
Expected: all tests pass, BUILD SUCCEEDED.

- [ ] **Step 4: Release build + reinstall**

```bash
osascript -e 'quit app "Sesh"' 2>/dev/null; pkill -x Sesh 2>/dev/null; sleep 1
tuist generate --no-open
xcodebuild -workspace sshconfig.xcworkspace -scheme Sesh -configuration Release -derivedDataPath build-release build
rm -rf /Applications/Sesh.app
ditto build-release/Build/Products/Release/Sesh.app /Applications/Sesh.app
codesign -v /Applications/Sesh.app
plutil -p /Applications/Sesh.app/Contents/Info.plist | grep ShortVersion   # expect 0.6.0
```

- [ ] **Step 5: Commit**

```bash
git add Project.swift README.md
git commit -m "chore: bump to 0.6.0 — app-primary model with ssh:// connect"
```

---

## Self-Review Notes

- **Spec coverage:** store relocation + fresh start (Task 3); ConfigExporter/IncludeManager/ConfigImporter (Task 1); ssh:// connect + fallback + handler narrowing (Tasks 2–3); remove SyncEngine/Conflicts/SyncSheet/SyncMode (Tasks 3–5); Import action + Settings link/status + managed path (Tasks 3–4); Raw viewer → sesh.conf, first-run reframe (Task 4); version 0.6.0 (Task 6).
- **Deviation:** `HostEntry.rawBlock` kept (unused) rather than removed — documented in Global Constraints; avoids churning all `HostEntry(...)` call sites for no benefit on a fresh store. If a reviewer insists, it's a mechanical follow-up.
- **Build-green ordering:** Tasks 2–3 intentionally leave the *app target* temporarily uncompilable (Core `swift test` stays green throughout); the app compiles green again at the end of Task 4. Tasks 2/3 commits are checkpoints of a coherent refactor-in-progress, then Task 4 restores a buildable app. This is called out in each task's build step so a reviewer isn't surprised.
- **Type consistency:** `connect(_ entry: HostEntry, with: Terminal?)` used in Tasks 3–4; `exportNow()` replaces `autoSyncToFile()` at every call site; `TerminalLauncher.open(_:with:onAsyncError:)` replaces `launch(_:host:onAsyncError:)`; `managedFileActive`/`linkInclude()`/`importFromConfig()`/`managedPath` names match across Tasks 3–4. `LaunchPlan` reduced to `.systemDefault`/`.sshURL` consistently in Task 2.
- **Risk:** the app-target-red window across Tasks 2–3 means the per-task reviewer for those tasks reviews Core + intent, not a running app; the Task 4 reviewer verifies the app builds and the flows compile. Data safety: `IncludeManager` backs up `~/.ssh/config` before its one-line edit and never rewrites existing blocks; `ConfigExporter` only ever writes the app-owned `sesh.conf`; the user's config is otherwise read-only.
