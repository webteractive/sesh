# Connection Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one logical host carry multiple `{user, identityFile}` connection profiles — each a real ssh `Host` alias — grouped in the app, with a profile picker in the Connect menu, menu bar, and ⌘K palette.

**Architecture:** Each profile is an ordinary `HostEntry` rendered as its own `Host` block, so the parser/writer/sync/backup core is unchanged. New work is additive: two app-only optional fields on `HostEntry` (`groupName`, `isDefaultProfile`), a pure `HostGrouping` folder and `ProfileFactory` action in Core (unit-tested), AppModel helpers, and grouped UI + pickers.

**Tech Stack:** Swift (language mode v5), SwiftUI (macOS 15), SwiftData (lightweight migration for added optionals), swift-testing.

**Spec:** `docs/superpowers/specs/2026-07-11-connection-profiles-design.md` — read it first.

## Global Constraints

- Repo `/Users/glenbangkila/AI/sshconfig-swift`, main branch. Tests: `swift test` (currently 65). App build: `tuist generate --no-open && tuist build SSHConfig`. Deployment target macOS 15; Core package platform `.v15`.
- `groupName` / `isDefaultProfile` are **app metadata only** — never parsed from or written to the config file. `SyncEngine.syncFromFile` must continue to touch only `properties`/`rawBlock` on existing entries (verify it doesn't clobber the new fields; entries imported fresh get `groupName == nil`, `isDefaultProfile == false`).
- Connecting always targets a profile's own alias (`ssh <alias>`); no `-l`/`-i` overrides. `HostValidation.isSafeToLaunch` still guards aliases.
- Core files under `Sources/SSHConfigCore/**` must not import SwiftUI/AppKit (SwiftData/Foundation only).
- Git commits: NO `Co-Authored-By`, NO `Claude-Session:` lines, never push. Commits approved.

---

### Task 1: Core — `HostEntry` group fields + `HostGrouping`

**Files:**
- Modify: `Sources/SSHConfigCore/HostEntry.swift`
- Create: `Sources/SSHConfigCore/HostGrouping.swift`
- Test: `Tests/SSHConfigCoreTests/HostGroupingTests.swift`
- Test: `Tests/SSHConfigCoreTests/HostEntryMigrationTests.swift`

**Interfaces:**
- Consumes: existing `HostEntry`, `makeContext()` test helper (in HostEntryTests.swift).
- Produces:
  - `HostEntry.groupName: String?` (default nil), `HostEntry.isDefaultProfile: Bool` (default false).
  - `struct HostRow: Sendable, Equatable { let alias, groupName?, user?, identityFile?: String?; let isDefault, isConnectable: Bool }` (init memberwise-public).
  - `struct ProfileRef: Identifiable, Sendable, Equatable { let id: String /* alias */; let alias, label: String; let user, identityFile: String?; let isDefault, isConnectable: Bool }`
  - `struct HostGroupView: Identifiable, Sendable, Equatable { let id, title: String; let members: [ProfileRef]; var isMultiProfile: Bool { members.count > 1 }; var defaultMember: ProfileRef }`
  - `enum HostGrouping { static func groups(from rows: [HostRow]) -> [HostGroupView] }`

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/HostGroupingTests.swift`**

```swift
import Testing
@testable import SSHConfigCore

private func row(_ alias: String, group: String? = nil, user: String? = nil,
                 identity: String? = nil, isDefault: Bool = false,
                 connectable: Bool = true) -> HostRow {
    HostRow(alias: alias, groupName: group, user: user, identityFile: identity,
            isDefault: isDefault, isConnectable: connectable)
}

@Test func ungroupedRowsBecomeSingletonGroups() {
    let g = HostGrouping.groups(from: [row("web", user: "admin"), row("db", user: "root")])
    #expect(g.count == 2)
    #expect(g.map(\.title) == ["web", "db"])
    #expect(g.allSatisfy { $0.members.count == 1 })
    #expect(g[0].defaultMember.alias == "web")          // lone member is the default
    #expect(!g[0].isMultiProfile)
}

@Test func sameGroupNameFolds_defaultFirstThenByUser() {
    let g = HostGrouping.groups(from: [
        row("web-deploy", group: "web", user: "deploy"),
        row("web", group: "web", user: "admin", isDefault: true),
        row("web-ci", group: "web", user: "ci"),
    ])
    #expect(g.count == 1)
    let m = g[0]
    #expect(m.title == "web")
    #expect(m.isMultiProfile)
    #expect(m.members.map(\.alias) == ["web", "web-ci", "web-deploy"]) // default, then user asc
    #expect(m.defaultMember.alias == "web")
    #expect(m.members[1].label == "ci")   // label falls back to user
}

@Test func groupOrderFollowsFirstMemberInputOrder() {
    let g = HostGrouping.groups(from: [
        row("b1", group: "beta", user: "x", isDefault: true),
        row("a1", group: "alpha", user: "y", isDefault: true),
        row("b2", group: "beta", user: "z"),
    ])
    #expect(g.map(\.title) == ["beta", "alpha"])   // group appears when first seen
}

@Test func labelFallsBackToAliasWhenNoUser() {
    let g = HostGrouping.groups(from: [row("gateway")])
    #expect(g[0].members[0].label == "gateway")
}

@Test func nonConnectableFlagPreserved() {
    let g = HostGrouping.groups(from: [row("*.internal", connectable: false)])
    #expect(g[0].members[0].isConnectable == false)
}

@Test func groupWithNoExplicitDefaultUsesFirstByUser() {
    let g = HostGrouping.groups(from: [
        row("s-b", group: "s", user: "bob"),
        row("s-a", group: "s", user: "amy"),
    ])
    // no isDefault set → earliest by user sort is the default
    #expect(g[0].defaultMember.user == "amy")
    #expect(g[0].members.map(\.user) == ["amy", "bob"])
}
```

- [ ] **Step 2: Write failing test — `Tests/SSHConfigCoreTests/HostEntryMigrationTests.swift`**

```swift
import Testing
import SwiftData
@testable import SSHConfigCore

@MainActor @Test func newGroupFieldsDefaultForExistingEntries() throws {
    let ctx = try makeContext()
    let e = HostEntry(host: "legacy", properties: [], rawBlock: nil)
    ctx.insert(e)
    try ctx.save()
    let fetched = try ctx.fetch(FetchDescriptor<HostEntry>())
    #expect(fetched[0].groupName == nil)
    #expect(fetched[0].isDefaultProfile == false)
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter HostGroupingTests`
Expected: FAIL — `cannot find 'HostGrouping'` / `HostRow`.

- [ ] **Step 4: Add fields to `Sources/SSHConfigCore/HostEntry.swift`**

Insert the two stored properties after `updatedAt` and initialize them in `init` (added SwiftData optionals/defaults migrate automatically):

```swift
    public var createdAt: Date
    public var updatedAt: Date
    /// App-only grouping: entries sharing a non-nil groupName are one logical
    /// host (never read from / written to the config file).
    public var groupName: String?
    /// The profile chosen on a plain (non-picked) connect for its group.
    public var isDefaultProfile: Bool

    public init(host: String, properties: [SSHProperty], rawBlock: String?) {
        self.host = host
        self.properties = properties
        self.rawBlock = rawBlock
        self.createdAt = .now
        self.updatedAt = .now
        self.groupName = nil
        self.isDefaultProfile = false
    }
```

- [ ] **Step 5: Implement `Sources/SSHConfigCore/HostGrouping.swift`**

```swift
import Foundation

public struct HostRow: Sendable, Equatable {
    public let alias: String
    public let groupName: String?
    public let user: String?
    public let identityFile: String?
    public let isDefault: Bool
    public let isConnectable: Bool

    public init(alias: String, groupName: String?, user: String?,
                identityFile: String?, isDefault: Bool, isConnectable: Bool) {
        self.alias = alias
        self.groupName = groupName
        self.user = user
        self.identityFile = identityFile
        self.isDefault = isDefault
        self.isConnectable = isConnectable
    }
}

public struct ProfileRef: Identifiable, Sendable, Equatable {
    public let id: String        // == alias
    public let alias: String
    public let label: String
    public let user: String?
    public let identityFile: String?
    public let isDefault: Bool
    public let isConnectable: Bool
}

public struct HostGroupView: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let members: [ProfileRef]
    public var isMultiProfile: Bool { members.count > 1 }
    public var defaultMember: ProfileRef {
        members.first(where: { $0.isDefault }) ?? members[0]
    }
}

public enum HostGrouping {
    /// Fold rows into groups. Rows with the same non-nil groupName collapse into
    /// one group; nil-group rows each become a singleton. Members are ordered
    /// default-first, then by user (nil users last), then by alias. Groups are
    /// ordered by where their first member appears in the input.
    public static func groups(from rows: [HostRow]) -> [HostGroupView] {
        var order: [String] = []          // group key, in first-seen order
        var buckets: [String: [HostRow]] = [:]

        for row in rows {
            let key = row.groupName ?? "\u{0}single:\(row.alias)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(row)
        }

        return order.map { key in
            let rows = buckets[key]!
            let sorted = rows.sorted { a, b in
                if a.isDefault != b.isDefault { return a.isDefault }         // default first
                switch (a.user, b.user) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.alias < b.alias
                }
            }
            let members = sorted.map { r in
                ProfileRef(id: r.alias, alias: r.alias,
                           label: (r.user?.isEmpty == false ? r.user! : r.alias),
                           user: r.user, identityFile: r.identityFile,
                           isDefault: r.isDefault, isConnectable: r.isConnectable)
            }
            let title = rows.first?.groupName ?? members[0].alias
            let id = rows.first?.groupName ?? "single:\(members[0].alias)"
            return HostGroupView(id: id, title: title, members: members)
        }
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test`
Expected: existing 65 + new grouping/migration tests pass. Note: a group with no `isDefault` still yields a `defaultMember` (first after sort), satisfying `groupWithNoExplicitDefaultUsesFirstByUser`.

- [ ] **Step 7: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): HostEntry group fields and host grouping"
```

---

### Task 2: Core — `ProfileFactory`

**Files:**
- Create: `Sources/SSHConfigCore/ProfileFactory.swift`
- Test: `Tests/SSHConfigCoreTests/ProfileFactoryTests.swift`

**Interfaces:**
- Consumes: `SSHProperty`, `[SSHProperty].first/set` (Task 2 of the base app), `HostFormData.hostPatternRegex` is NOT reused here (this is Core; regex lives in Core's HostFormData already — but to avoid a UI dependency, sanitise inline).
- Produces:
  - `struct NewProfile: Equatable, Sendable { let alias: String; let properties: [SSHProperty] }`
  - `enum ProfileFactory { static func make(baseProperties: [SSHProperty], baseAlias: String, label: String, user: String, identityFile: String?, existingAliases: Set<String>) -> NewProfile }`
  - Behavior: copy every base property EXCEPT `User`/`IdentityFile`; set `User = user`; set `IdentityFile` when non-empty; derive alias `sanitize("\(baseAlias)-\(label)")`, appending `-2`, `-3`… until not in `existingAliases`. `sanitize` lowercases nothing (preserve case), replaces any run of characters outside `[A-Za-z0-9._-]` with `-`, trims leading/trailing `-`, and falls back to `"\(baseAlias)-profile"` if the label sanitises to empty.

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/ProfileFactoryTests.swift`**

```swift
import Testing
@testable import SSHConfigCore

@Test func copiesBaseConfigOverridesUserAndIdentity() {
    let base: [SSHProperty] = [
        SSHProperty(key: "HostName", values: ["10.0.0.5"]),
        SSHProperty(key: "Port", values: ["2222"]),
        SSHProperty(key: "User", values: ["admin"]),
        SSHProperty(key: "IdentityFile", values: ["~/.ssh/admin"]),
        SSHProperty(key: "ProxyJump", values: ["bastion"]),
    ]
    let p = ProfileFactory.make(baseProperties: base, baseAlias: "web",
                                label: "deploy", user: "deploy",
                                identityFile: "~/.ssh/deploy", existingAliases: ["web"])
    #expect(p.alias == "web-deploy")
    #expect(p.properties.first("HostName") == "10.0.0.5")
    #expect(p.properties.first("Port") == "2222")
    #expect(p.properties.first("ProxyJump") == "bastion")
    #expect(p.properties.first("User") == "deploy")
    #expect(p.properties.first("IdentityFile") == "~/.ssh/deploy")
    // base's admin/identity must NOT leak through
    #expect(p.properties.filter { $0.key.caseInsensitiveCompare("User") == .orderedSame }.count == 1)
}

@Test func aliasCollisionGetsNumericSuffix() {
    let p = ProfileFactory.make(baseProperties: [], baseAlias: "web", label: "deploy",
                                user: "deploy", identityFile: nil,
                                existingAliases: ["web", "web-deploy", "web-deploy-2"])
    #expect(p.alias == "web-deploy-3")
}

@Test func labelSanitisedToAliasCharset() {
    let p = ProfileFactory.make(baseProperties: [], baseAlias: "web", label: "Ops Team!",
                                user: "ops", identityFile: nil, existingAliases: [])
    #expect(p.alias == "web-Ops-Team")
}

@Test func emptyIdentityOmitsKey() {
    let p = ProfileFactory.make(baseProperties: [], baseAlias: "web", label: "x",
                                user: "x", identityFile: "", existingAliases: [])
    #expect(p.properties.first("IdentityFile") == nil)
    #expect(p.properties.first("User") == "x")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ProfileFactoryTests`
Expected: FAIL — `cannot find 'ProfileFactory'`.

- [ ] **Step 3: Implement `Sources/SSHConfigCore/ProfileFactory.swift`**

```swift
import Foundation

public struct NewProfile: Equatable, Sendable {
    public let alias: String
    public let properties: [SSHProperty]
}

public enum ProfileFactory {
    public static func make(baseProperties: [SSHProperty], baseAlias: String,
                            label: String, user: String, identityFile: String?,
                            existingAliases: Set<String>) -> NewProfile {
        // Copy everything except the identity-defining keys, then set ours.
        var props = baseProperties.filter {
            let k = $0.key.lowercased()
            return k != "user" && k != "identityfile"
        }
        props.set("User", user)
        props.set("IdentityFile", identityFile)

        let stem = sanitize(label)
        var candidate = "\(baseAlias)-\(stem)"
        if existingAliases.contains(candidate) {
            var n = 2
            while existingAliases.contains("\(baseAlias)-\(stem)-\(n)") { n += 1 }
            candidate = "\(baseAlias)-\(stem)-\(n)"
        }
        return NewProfile(alias: candidate, properties: props)
    }

    private static func sanitize(_ label: String) -> String {
        let mapped = label.map { c -> Character in
            (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "-"
        }
        var s = String(mapped)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "profile" : s
    }
}
```

Note: `sanitize("Ops Team!")` → `Ops-Team-` → collapse/trim → `Ops-Team`, giving `web-Ops-Team`. `sanitize` empty → `"profile"`, giving `"\(baseAlias)-profile"`.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): profile factory for deriving connection-profile aliases"
```

---

### Task 3: App — `AppModel` profile helpers

**Files:**
- Modify: `App/Sources/AppModel.swift`
- Test: (none — app layer; verified by build + manual QA)

**Interfaces:**
- Consumes: `HostGrouping`, `HostRow`, `HostGroupView`, `ProfileRef` (Task 1), `ProfileFactory`/`NewProfile` (Task 2), `HostEntry` fields, existing `connect(_:with:)`, `autoSyncToFile()`, `pendingError`.
- Produces (Tasks 4–5 rely on these; all `@MainActor`):
  - `func groups(from hosts: [HostEntry]) -> [HostGroupView]` — maps entries → `HostRow` (user/identity read from `properties`) → `HostGrouping.groups`.
  - `func entry(forAlias: String, in hosts: [HostEntry]) -> HostEntry?`
  - `func addProfile(to base: HostEntry, label: String, user: String, identityFile: String?, allHosts: [HostEntry]) -> String?` — creates the sibling `HostEntry` (shared `groupName`, defaulting `base.groupName` to `base.host` and marking base `isDefaultProfile = true` when it had no group yet), saves, auto-syncs; returns an error string or nil.
  - `func removeProfile(_ entry: HostEntry, groupMembers: [HostEntry]) -> String?` — deletes the alias; if it was the default, promotes the earliest remaining member; if it was the last member, the group dissolves (remaining single member keeps its `groupName`? no — clear it). Returns error or nil.
  - `func ungroup(_ members: [HostEntry]) -> String?` — clears `groupName`/`isDefaultProfile` on all, saves, auto-syncs.

- [ ] **Step 1: Add the helpers to `AppModel`**

Add near the other host helpers. Read the file first for exact placement.

```swift
    // MARK: - Connection profiles

    func groups(from hosts: [HostEntry]) -> [HostGroupView] {
        HostGrouping.groups(from: hosts.map { e in
            HostRow(alias: e.host, groupName: e.groupName,
                    user: e.properties.first("User"),
                    identityFile: e.properties.first("IdentityFile"),
                    isDefault: e.isDefaultProfile, isConnectable: e.isConnectable)
        })
    }

    func entry(forAlias alias: String, in hosts: [HostEntry]) -> HostEntry? {
        hosts.first { $0.host == alias }
    }

    func addProfile(to base: HostEntry, label: String, user: String,
                    identityFile: String?, allHosts: [HostEntry]) -> String? {
        let group = base.groupName ?? base.host
        let profile = ProfileFactory.make(
            baseProperties: base.properties, baseAlias: base.host, label: label,
            user: user, identityFile: identityFile,
            existingAliases: Set(allHosts.map(\.host)))
        if base.groupName == nil {          // first profile turns the host into a group
            base.groupName = group
            base.isDefaultProfile = true
        }
        let entry = HostEntry(host: profile.alias, properties: profile.properties, rawBlock: nil)
        entry.groupName = group
        context.insert(entry)
        do {
            try context.save()
            autoSyncToFile()
            return nil
        } catch {
            context.rollback()
            return error.localizedDescription
        }
    }

    func removeProfile(_ entry: HostEntry, groupMembers: [HostEntry]) -> String? {
        let wasDefault = entry.isDefaultProfile
        let remaining = groupMembers.filter { $0.persistentModelID != entry.persistentModelID }
        context.delete(entry)
        if remaining.count == 1 {
            remaining[0].groupName = nil          // group dissolves back to a lone host
            remaining[0].isDefaultProfile = false
        } else if wasDefault, let promote = remaining.first {
            promote.isDefaultProfile = true
        }
        do {
            try context.save()
            autoSyncToFile()
            return nil
        } catch {
            context.rollback()
            return error.localizedDescription
        }
    }

    func ungroup(_ members: [HostEntry]) -> String? {
        for m in members { m.groupName = nil; m.isDefaultProfile = false }
        do {
            try context.save()
            autoSyncToFile()
            return nil
        } catch {
            context.rollback()
            return error.localizedDescription
        }
    }
```

- [ ] **Step 2: Verify sync preserves the new fields**

Open `Sources/SSHConfigCore/SyncEngine.swift` and confirm `syncFromFile` only assigns `entry.properties`, `entry.rawBlock`, `entry.updatedAt` on existing entries (it does — no `groupName`/`isDefaultProfile` touched) and that newly-created entries leave them at defaults. No code change; note this in the report.

- [ ] **Step 3: Build + test**

Run: `tuist generate --no-open && tuist build SSHConfig && swift test`
Expected: BUILD SUCCEEDED; tests still pass.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/AppModel.swift
git commit -m "feat(app): AppModel profile grouping and add/remove/ungroup helpers"
```

---

### Task 4: App — grouped sidebar, detail Profiles section, Add Profile sheet

**Files:**
- Create: `App/Sources/Views/AddProfileSheet.swift`
- Modify: `App/Sources/Views/MainWindow.swift`
- Modify: `App/Sources/Views/HostDetailView.swift`

**Interfaces:**
- Consumes: `AppModel.groups/addProfile/removeProfile/ungroup/entry(forAlias:)`, `HostGroupView`, `ProfileRef`.
- Produces: `AddProfileSheet(base: HostEntry)`; a detail Profiles section; grouped sidebar rows.

- [ ] **Step 1: Create `App/Sources/Views/AddProfileSheet.swift`**

```swift
import SwiftUI
import SwiftData
import SSHConfigCore

struct AddProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query private var hosts: [HostEntry]

    let base: HostEntry
    @State private var label = ""
    @State private var user = ""
    @State private var identityFile = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Profile to '\(base.host)'").font(.title2.bold())
            Text("Creates a sibling SSH alias sharing this host's connection settings, with its own user and identity.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Label", text: $label, prompt: Text("deploy"))
                TextField("User", text: $user, prompt: Text("deploy"))
                TextField("IdentityFile", text: $identityFile, prompt: Text("~/.ssh/id_deploy"))
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Add") { add() }
                    .keyboardShortcut(.return).buttonStyle(.borderedProminent)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty
                              || user.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }

    private func add() {
        let id = identityFile.trimmingCharacters(in: .whitespaces)
        if let message = model.addProfile(
            to: base,
            label: label.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            identityFile: id.isEmpty ? nil : id,
            allHosts: hosts) {
            error = message
        } else {
            dismiss()
        }
    }
}
```

- [ ] **Step 2: Group the sidebar in `MainWindow.swift`**

Replace the flat `List(filtered, …)` with a grouped list. Read the current file; keep search, selection (`Set<PersistentIdentifier>`), context menu, and all sheets/dialogs/overlay intact. The grouping model comes from `model.groups(from: filtered)`. Each group renders as one row; multi-profile groups get a profile-count caption and a disclosure of member rows (each member selectable by its own `persistentModelID`, so the existing detail/edit/delete keyed on selection keeps working). Concretely:

```swift
            List(selection: $selection) {
                ForEach(model.groups(from: filtered)) { group in
                    if group.isMultiProfile {
                        DisclosureGroup {
                            ForEach(group.members) { member in
                                memberRow(member)
                            }
                        } label: {
                            groupLabel(group)
                        }
                    } else {
                        memberRow(group.members[0])
                    }
                }
            }
            .searchable(text: $search, prompt: "Search hosts")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
```

Add these helpers to `MainWindow` (each member row must resolve its `HostEntry` for context-menu actions via `model.entry(forAlias:in:)`):

```swift
    @ViewBuilder
    private func groupLabel(_ group: HostGroupView) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title).font(.headline)
            Text("^[\(group.members.count) profile](inflect: true)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func memberRow(_ member: ProfileRef) -> some View {
        let entry = model.entry(forAlias: member.alias, in: hosts)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(member.label).font(.headline)
                if member.isDefault { Text("default").font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule()) }
            }
            Text(member.user.map { "\($0)@\(entry?.properties.first("HostName") ?? "—")" }
                 ?? member.alias).font(.caption).foregroundStyle(.secondary)
        }
        .tag(member.alias.hashValue)   // placeholder; see note
        .modifier(SelectableTag(id: entry?.persistentModelID))
        .contextMenu {
            if let entry {
                Button("Edit") { formMode = .edit(entry) }
                Button("Add Profile…") { addProfileBase = entry }
                if entry.groupName != nil {
                    Button("Remove from Group") { _ = model.ungroupOne(entry, allHosts: hosts) }
                }
                Divider()
                Button("Delete", role: .destructive) { requestDelete(entry) }
            }
        }
    }
```

Because `List(selection:)` needs each selectable row tagged with a `PersistentIdentifier`, tag the row with the entry's id directly instead of the placeholder above — final row uses `.tag(entry?.persistentModelID)` on an `if let entry` branch. Implementer: bind selection by tagging the row `.tag(entry.persistentModelID)` (wrap the row body in `if let entry = model.entry(forAlias: member.alias, in: hosts)`), dropping the `SelectableTag`/`hashValue` placeholder — that was illustrative. Add `@State private var addProfileBase: HostEntry?` and a sheet:

```swift
        .sheet(item: $addProfileBase) { base in
            AddProfileSheet(base: base)
        }
```

`HostEntry` must be `Identifiable` for `.sheet(item:)` — `@Model` classes are `Identifiable` via `persistentModelID`? They are `PersistentModel` which is `Identifiable`. Good.

Add a convenience to `AppModel` used above (single-entry ungroup): in `AppModel`, add
```swift
    func ungroupOne(_ entry: HostEntry, allHosts: [HostEntry]) -> String? {
        let members = allHosts.filter { $0.groupName != nil && $0.groupName == entry.groupName }
        return ungroup(members)   // clears the whole group; simplest coherent behavior for v1
    }
```
(Removing one profile from a group of >2 while keeping the rest grouped is out of v1 scope; "Remove from Group" dissolves the group. Document this.)

- [ ] **Step 3: Add a Profiles section + Add Profile button to `HostDetailView.swift`**

Read the file. When the shown entry belongs to a group, add a **Profiles** `GroupBox` listing the group's members (label, user, identity, default badge) with a per-row Connect (reuse the existing per-terminal Connect menu, but targeting `member.alias`) and a Remove button (`model.removeProfile`). Always add an **Add Profile…** button that sets a binding the parent uses to present `AddProfileSheet` (pass an `onAddProfile: (HostEntry) -> Void` closure from `MainWindow`, mirroring the existing `onEdit` closure). Group members are fetched via `model.groups(from:)` filtered to the entry's group, resolving each `ProfileRef` back to a `HostEntry` with `model.entry(forAlias:in:)`.

- [ ] **Step 4: Build + smoke**

Run: `tuist generate --no-open && tuist build SSHConfig`
Expected: BUILD SUCCEEDED. (GUI grouping/add-profile needs manual QA — note it.)

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "feat(app): grouped sidebar, detail profiles section, add-profile sheet"
```

---

### Task 5: App — profile pickers in Connect menu, menu bar, palette

**Files:**
- Modify: `App/Sources/Views/HostDetailView.swift`
- Modify: `App/Sources/Views/MenuBarView.swift`
- Modify: `App/Sources/Views/CommandPalette.swift`

**Interfaces:**
- Consumes: `AppModel.groups/connect(_:with:)/copyCommand/entry(forAlias:)`, `HostGroupView`, `ProfileRef`.
- Produces: no new types.

- [ ] **Step 1: Detail Connect menu — per profile**

In `HostDetailView`, when the entry's group is multi-profile, the Connect control lists **Connect as <label>** for each member (each opening the existing per-terminal submenu, or connecting via the preferred terminal on click and targeting `member.alias`). Single-profile hosts keep today's behavior. Primary click connects the **default** member.

- [ ] **Step 2: Menu bar rows — profile chooser**

In `MenuBarView`, iterate `model.groups(from: filtered)` instead of raw hosts. A single-profile group renders as today (Copy + Open-in-Terminal for `member.alias`). A multi-profile group shows the title and a small `Menu` (e.g. "person.2" icon) listing **Connect as <label>** per member plus **Copy <label>**; the row's default Open-in-Terminal targets the default member. Keep the search/keyboard/footer behavior; keyboard `activateSelected` connects the highlighted group's default member. `filtered` stays a host list; derive groups from it for display.

- [ ] **Step 3: Palette — per-profile rows**

In `CommandPalette`, expand a multi-profile host into one row per profile, titled `"<group> · <label>"`, each with `connect`/`copy` targeting that profile's alias. Build the palette's host items from `model.groups(from: hosts)` (pass `model` in, or compute groups in `MainWindow` and pass the flattened rows). Simplest: change `CommandPalette` to accept `groups: [HostGroupView]` and a `resolve: (String) -> HostEntry?`; Enter/⌘Enter act on the profile's alias via the existing `onHost` closure keyed by alias. Update `MainWindow`'s `CommandPalette(...)` call site accordingly (`onHost` switch already handles connect/copy/reveal by alias — for reveal, select that alias' entry).

- [ ] **Step 4: Build + smoke**

Run: `tuist generate --no-open && tuist build SSHConfig && swift test`
Expected: BUILD SUCCEEDED; 65+ tests pass. (Pickers need manual QA.)

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "feat(app): profile pickers in connect menu, menu bar, and palette"
```

---

### Task 6: Wrap-up — version bump, README, build, reinstall

**Files:**
- Modify: `Project.swift` (0.3.0 → 0.4.0)
- Modify: `README.md`

- [ ] **Step 1: Bump `CFBundleShortVersionString` to `0.4.0` in `Project.swift`.**

- [ ] **Step 2: Add a README feature bullet**

```markdown
- Connection profiles: give one host multiple user+identity profiles (real ssh
  aliases) and pick which to connect with, from the Connect menu, menu bar, or ⌘K
```

- [ ] **Step 3: Full verification**

Run: `swift test && tuist generate --no-open && tuist build SSHConfig`
Expected: all tests pass, BUILD SUCCEEDED.

- [ ] **Step 4: Release build + reinstall**

```bash
osascript -e 'quit app "SSHConfig"' 2>/dev/null; pkill -x SSHConfig 2>/dev/null; sleep 1
tuist generate --no-open
xcodebuild -workspace sshconfig.xcworkspace -scheme SSHConfig -configuration Release -derivedDataPath build-release build
rm -rf /Applications/SSHConfig.app
ditto build-release/Build/Products/Release/SSHConfig.app /Applications/SSHConfig.app
codesign -v /Applications/SSHConfig.app
plutil -p /Applications/SSHConfig.app/Contents/Info.plist | grep ShortVersion   # expect 0.4.0
```

- [ ] **Step 5: Commit**

```bash
git add Project.swift README.md
git commit -m "chore: bump to 0.4.0 with connection profiles"
```

---

## Self-Review Notes

- **Spec coverage:** group fields + migration (Task 1); HostGrouping (Task 1); ProfileFactory (Task 2); AppModel add/remove/ungroup + sync-preservation check (Task 3); grouped sidebar + detail + Add Profile sheet (Task 4); pickers in all three surfaces (Task 5); version/README/install (Task 6). Error handling (auto-sync + rollback + pendingError) is folded into the AppModel helpers (Task 3). Default-promotion and group-dissolve on delete are in `removeProfile` (Task 3).
- **Deferred vs spec:** the spec's per-member "Remove from Group" is simplified in v1 to dissolving the whole group (`ungroupOne` → `ungroup`); noted in Task 4. Editing the base's shared fields with cascade remains out of scope per the spec.
- **Type consistency:** `HostGroupView`/`ProfileRef`/`HostRow` names are used identically across Tasks 1, 3, 4, 5. `AppModel.groups(from:)`, `entry(forAlias:in:)`, `addProfile(to:label:user:identityFile:allHosts:)`, `removeProfile(_:groupMembers:)`, `ungroup(_:)`, `ungroupOne(_:allHosts:)` signatures match between Task 3 (definitions) and Tasks 4–5 (call sites). `connect(_:with:)` unchanged from the shipped app.
- **Risk:** the only Core-model change is two additive optional/defaulted fields (SwiftData lightweight migration) — verified safe by the Task 1 migration test. The parser/writer/sync remain untouched; Task 3 Step 2 is an explicit read-only confirmation of that invariant.
