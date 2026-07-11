# Grouped Import + First-Run Offer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Import `~/.ssh/config` into the new model — one host per block titled by a Name, auto-grouping same-HostName-different-user blocks into profile groups (preserving existing aliases), offered opt-in on first run.

**Architecture:** Pure Core `ConfigImporter.groups(inConfigAt:)` + `commonAliasPrefix` (tested); rewrite `AppModel.importFromConfig` to be group-aware and additive; add a first-run Import offer.

**Tech Stack:** Swift v5, SwiftUI (macOS 15), SwiftData, swift-testing, Tuist.

**Spec:** `docs/superpowers/specs/2026-07-12-grouped-import-design.md` — read first.

## Global Constraints

- Repo `/Users/glenbangkila/AI/sshconfig-swift`, main. Tests `swift test`; build `tuist generate --no-open && tuist build Sesh` (scheme Sesh).
- Import **preserves existing aliases** (never re-derives/renames). Additive (skip by alias, never delete).
- Grouping: bucket single-alias hosts by HostName; ≥2 distinct Users in a bucket → one group (members keep aliases, groupName = first member's alias, first isDefault, displayName = longest common alias prefix trimmed of trailing `.-_`, fallback first alias if <2 chars); else singletons (groupName nil, displayName = alias). Wildcard/multi-pattern Host lines → singletons, never grouped.
- Core = Foundation/SwiftData only. Git: NO Co-Authored-By, NO Claude-Session lines, never push. Commits approved.

---

### Task 1: Core — grouped import + AppModel.importFromConfig rewrite

**Files:**
- Modify: `Sources/SSHConfigCore/ConfigImporter.swift` (add `ImportGroup`, `groups(inConfigAt:)`, `commonAliasPrefix`)
- Modify: `App/Sources/AppModel.swift` (`importFromConfig` group-aware)
- Test: `Tests/SSHConfigCoreTests/ConfigImporterTests.swift` (extend)

**Interfaces:**
- Consumes: `SSHConfigParser`, `SSHProperty.first`, `ImportedHost`.
- Produces: `struct ImportGroup: Equatable, Sendable { let displayName: String; let groupName: String?; let members: [ImportedHost] }`; `ConfigImporter.groups(inConfigAt:) -> [ImportGroup]`; `ConfigImporter.commonAliasPrefix(_ aliases: [String]) -> String` (static or instance).

- [ ] **Step 1: Write failing tests — extend `ConfigImporterTests.swift`**

```swift
@Test func groupsSameHostNameDifferingUsers() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try """
    Host WebSolutionsTools
        HostName 143.198.192.77
        User forge
        IdentityFile ~/.ssh/web

    Host WebSolutionsToolsCoopit
        HostName 143.198.192.77
        User coopit
        IdentityFile ~/.ssh/web

    Host solo
        HostName 10.0.0.9
        User root
    """.write(toFile: config, atomically: true, encoding: .utf8)

    let groups = ConfigImporter().groups(inConfigAt: config)
    let tools = groups.first { $0.members.contains { $0.alias == "WebSolutionsTools" } }!
    #expect(tools.groupName == "WebSolutionsTools")                 // first member's alias
    #expect(tools.members.map(\.alias) == ["WebSolutionsTools", "WebSolutionsToolsCoopit"])
    #expect(tools.displayName == "WebSolutionsTools")               // common prefix
    let solo = groups.first { $0.members.first?.alias == "solo" }!
    #expect(solo.groupName == nil)
    #expect(solo.displayName == "solo")
}

@Test func sameHostNameSameUserStaysSeparate() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try """
    Host sds
        HostName 104.248.237.163
        User forge

    Host jobs.example.co
        HostName 104.248.237.163
        User forge
    """.write(toFile: config, atomically: true, encoding: .utf8)

    let groups = ConfigImporter().groups(inConfigAt: config)
    #expect(groups.count == 2)
    #expect(groups.allSatisfy { $0.groupName == nil })            // both singletons
    #expect(Set(groups.map(\.displayName)) == ["sds", "jobs.example.co"])
}

@Test func wildcardHostIsSingleton() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try "Host *.internal\n    User admin\n".write(toFile: config, atomically: true, encoding: .utf8)
    let groups = ConfigImporter().groups(inConfigAt: config)
    #expect(groups.count == 1)
    #expect(groups[0].groupName == nil)
    #expect(groups[0].displayName == "*.internal")
}

@Test func commonPrefix() {
    #expect(ConfigImporter.commonAliasPrefix(["WebSolutionsTools", "WebSolutionsToolsCoopit"]) == "WebSolutionsTools")
    #expect(ConfigImporter.commonAliasPrefix(["prod-web", "prod-db"]) == "prod")      // trims trailing '-'
    #expect(ConfigImporter.commonAliasPrefix(["alpha", "beta"]) == "")                 // no common prefix
    #expect(ConfigImporter.commonAliasPrefix(["only"]) == "only")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ConfigImporterTests`
Expected: FAIL — `groups`/`commonAliasPrefix`/`ImportGroup` not found.

- [ ] **Step 3: Implement in `ConfigImporter.swift`**

```swift
public struct ImportGroup: Equatable, Sendable {
    public let displayName: String
    public let groupName: String?
    public let members: [ImportedHost]
    public init(displayName: String, groupName: String?, members: [ImportedHost]) {
        self.displayName = displayName; self.groupName = groupName; self.members = members
    }
}

public extension ConfigImporter {
    func groups(inConfigAt path: String) -> [ImportGroup] {
        let hosts = self.hosts(inConfigAt: path)   // existing: [ImportedHost], file order
        func isWildcard(_ a: String) -> Bool { a.contains(where: { "*?! ".contains($0) }) }

        // Bucket connectable hosts by HostName in first-seen order.
        var order: [String] = []
        var buckets: [String: [ImportedHost]] = [:]
        var singletons: [ImportGroup] = []
        var result: [ImportGroup] = []
        var placeholderIndex: [String: Int] = [:]   // where each bucket's group slots into result order

        for h in hosts {
            let hn = h.properties.first("HostName")
            if isWildcard(h.alias) || hn == nil {
                result.append(ImportGroup(displayName: h.alias, groupName: nil, members: [h]))
                continue
            }
            let key = hn!
            if buckets[key] == nil { placeholderIndex[key] = result.count; result.append(
                ImportGroup(displayName: "", groupName: nil, members: [])) }  // reserve slot
            buckets[key, default: []].append(h)
        }
        // Fill reserved slots (may expand a bucket into multiple singleton groups).
        for (key, members) in buckets {
            let slot = placeholderIndex[key]!
            let users = Set(members.map { $0.properties.first("User") ?? "" })
            if members.count >= 2 && users.count >= 2 {
                let prefix = Self.commonAliasPrefix(members.map(\.alias))
                let name = prefix.count >= 2 ? prefix : members[0].alias
                result[slot] = ImportGroup(displayName: name, groupName: members[0].alias, members: members)
            } else {
                // singletons: replace the reserved slot with the first, append the rest after it
                var expanded: [ImportGroup] = members.map {
                    ImportGroup(displayName: $0.alias, groupName: nil, members: [$0])
                }
                result[slot] = expanded.removeFirst()
                if !expanded.isEmpty { result.insert(contentsOf: expanded, at: slot + 1) }
            }
        }
        _ = singletons
        return result
    }

    static func commonAliasPrefix(_ aliases: [String]) -> String {
        guard let first = aliases.first else { return "" }
        if aliases.count == 1 { return first }
        var prefix = first
        for a in aliases.dropFirst() {
            while !a.hasPrefix(prefix) { prefix = String(prefix.dropLast()); if prefix.isEmpty { return "" } }
        }
        // trim trailing separators
        while let last = prefix.last, ".-_".contains(last) { prefix = String(prefix.dropLast()) }
        return prefix
    }
}
```

Note: inserting into `result` mid-list shifts later reserved slots — to avoid index drift, the implementer should build `result` more simply: first pass produces an ordered list of "bucket keys and standalone entries," second pass expands. If the index-drift bookkeeping above is fragile, replace with: collect `(orderKey, ImportGroup...)` tuples in encounter order and flatten — the tests pin the required behavior, so choose whichever construction passes them cleanly. **Correctness (tests) over the exact snippet.**

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: green (existing + new). Fix construction until `groups*` tests pass, keeping the documented semantics.

- [ ] **Step 5: Rewrite `AppModel.importFromConfig` (group-aware, additive)**

```swift
    @discardableResult
    func importFromConfig() -> (added: Int, skipped: Int) {
        let path = configPath ?? ConfigPathStore.defaultSuggestion
        let existing = Set((try? context.fetch(FetchDescriptor<HostEntry>()))?.map(\.host) ?? [])
        var added = 0, skipped = 0
        for group in importer.groups(inConfigAt: path) {
            let isGroup = group.groupName != nil
            for (i, m) in group.members.enumerated() {
                if existing.contains(m.alias) { skipped += 1; continue }
                let e = HostEntry(host: m.alias, properties: m.properties, rawBlock: nil)
                e.displayName = group.displayName
                e.groupName = group.groupName
                e.isDefaultProfile = isGroup && i == 0
                context.insert(e)
                added += 1
            }
        }
        do { try context.save(); exportNow(); return (added, skipped) }
        catch { context.rollback(); pendingError = error.localizedDescription; return (0, 0) }
    }
```

- [ ] **Step 6: Build + test**

Run: `tuist generate --no-open && tuist build Sesh && swift test`
Expected: BUILD SUCCEEDED; tests green.

- [ ] **Step 7: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests App/Sources/AppModel.swift
git commit -m "feat: grouped, alias-preserving import (shared-HostName differing-user profiles)"
```

---

### Task 2: App — first-run Import offer + empty-state; wrap-up

**Files:**
- Modify: `App/Sources/Views/FirstRunSheet.swift`
- Modify: `App/Sources/Views/MainWindow.swift` (empty-state Import affordance)
- Modify: `Project.swift` (0.7.0 → 0.7.1)

**Interfaces:** consumes `AppModel.importFromConfig()`, `configPath`, host `@Query`.

- [ ] **Step 1: First-run Import offer (`FirstRunSheet.swift`)**

After the path is saved and the Include linked, if `~/.ssh/config` exists, show an **"Import my existing hosts"** button and a **Skip** (dismiss). READ the current FirstRunSheet first. Tapping Import calls `model.importFromConfig()` and shows the count (reuse the existing inline error/info text or `pendingError` only-if-nil pattern), then dismisses. Nothing imports without the tap.

- [ ] **Step 2: Empty-state Import affordance (`MainWindow.swift`)**

When the host list is empty, the detail `ContentUnavailableView` should mention Import — e.g. change the "No Host Selected" empty case (when `hosts.isEmpty`) to a dedicated view: "No hosts yet — press ⌘N to add one, or Import from ~/.ssh/config." with a button calling the same `importNow()` the toolbar uses. READ the current detail/empty code and adapt; keep the existing non-empty behavior.

- [ ] **Step 3: Bump version to 0.7.1 in `Project.swift`.**

- [ ] **Step 4: Build + full verify**

Run: `swift test && tuist generate --no-open && tuist build Sesh`
Expected: all pass, BUILD SUCCEEDED. Launch headlessly (no crash). Manual QA noted for first-run/import.

- [ ] **Step 5: Release build + reinstall + relaunch**

```bash
osascript -e 'quit app "Sesh"' 2>/dev/null; pkill -x Sesh 2>/dev/null; sleep 1
tuist generate --no-open
xcodebuild -workspace sshconfig.xcworkspace -scheme Sesh -configuration Release -derivedDataPath build-release build
rm -rf /Applications/Sesh.app
ditto build-release/Build/Products/Release/Sesh.app /Applications/Sesh.app
codesign -v /Applications/Sesh.app
plutil -p /Applications/Sesh.app/Contents/Info.plist | grep ShortVersion   # expect 0.7.1
open /Applications/Sesh.app
```

- [ ] **Step 6: Commit**

```bash
git add App Project.swift
git commit -m "feat(app): first-run import offer + empty-state import; bump 0.7.1"
```

---

## Self-Review Notes

- **Spec coverage:** grouping rules + commonAliasPrefix + ImportGroup (Task 1); alias-preserving additive importFromConfig (Task 1); first-run opt-in offer + empty-state (Task 2); version/build/install (Task 2). Alias preservation (no re-derivation) is explicit in importFromConfig (uses `m.alias` verbatim).
- **Construction caveat:** the `groups(inConfigAt:)` ordering/slot code is illustrative; the tests are the contract. The implementer may restructure the two-pass build for clarity as long as all `ConfigImporterTests` pass.
- **Type consistency:** `ImportGroup{displayName,groupName,members}`, `groups(inConfigAt:)`, `commonAliasPrefix(_:)`, `importFromConfig() -> (added:,skipped:)` used consistently.
- **Data safety:** import is additive (skip by alias), save rolls back on failure, and `exportNow` still guards managed≠config. Existing store entries are never modified or deleted by import.
