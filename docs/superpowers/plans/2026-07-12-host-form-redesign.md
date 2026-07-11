# Host Form Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the add/edit host form with Name + Host (ip/domain) + a repeater of {User, Port, SSH key} rows (≥1), where each row is a real ssh alias (profile), using a pure reconciler that keeps unchanged aliases stable on edit.

**Architecture:** Add `HostEntry.displayName`; make `HostGrouping` titles display-name-aware; add pure Core `HostFormModel` + `HostFormReconciler` (create/update/delete plan) reusing `ProfileFactory`'s sanitizer; rewrite `HostFormSheet` to the new form and add `AppModel.saveHostForm`; show `displayName` across sidebar/menu bar/palette/detail.

**Tech Stack:** Swift (language mode v5), SwiftUI (macOS 15), SwiftData, swift-testing, Tuist. No new deps.

**Spec:** `docs/superpowers/specs/2026-07-12-host-form-redesign-design.md` — read first.

## Global Constraints

- Repo `/Users/glenbangkila/AI/sshconfig-swift`, main. Tests `swift test`; app build `tuist generate --no-open && tuist build Sesh` (scheme **Sesh**).
- Core (`Sources/SSHConfigCore/**`) Foundation/SwiftData only.
- `displayName` is app-only; never written to `sesh.conf`. Alias derivation reuses `ProfileFactory` sanitization (ASCII `[A-Za-z0-9._-]`). Default/first row alias = unique `sanitize(Name)`; extra rows = `sanitize(Name)-<user>` unique-suffixed; on edit an unchanged-user row keeps its current alias.
- Extra ssh options on an entry must be **preserved** through edit (not shown/edited in the form).
- Git commits: NO `Co-Authored-By`, NO `Claude-Session:` lines, never push. Commits approved.

---

### Task 1: Core — displayName, grouping title, HostFormModel + HostFormReconciler

**Files:**
- Modify: `Sources/SSHConfigCore/HostEntry.swift` (add `displayName`)
- Modify: `Sources/SSHConfigCore/HostGrouping.swift` (title from displayName)
- Modify: `Sources/SSHConfigCore/ProfileFactory.swift` (expose sanitizer)
- Create: `Sources/SSHConfigCore/HostFormModel.swift`
- Test: `Tests/SSHConfigCoreTests/HostFormReconcilerTests.swift`
- Test: `Tests/SSHConfigCoreTests/HostGroupingTests.swift` (add displayName title test)
- Test: `Tests/SSHConfigCoreTests/HostEntryMigrationTests.swift` (add displayName default)

**Interfaces:**
- Consumes: `SSHProperty` (+ `[SSHProperty].first/set`), `ProfileFactory`.
- Produces:
  - `HostEntry.displayName: String?` (default nil).
  - `HostRow.displayName: String?` (new init param, last); `HostGroupView.title = displayName ?? groupName ?? alias`.
  - `ProfileFactory.sanitizedAlias(_ label: String) -> String` (public; the existing private `sanitize` becomes this).
  - `struct CredentialRow: Equatable, Sendable { var user, port, identityFile: String; var extras: [SSHProperty] }`
  - `struct HostFormModel: Equatable, Sendable { var displayName, hostName: String; var rows: [CredentialRow]; func validationError() -> String? }`
  - `struct HostFormPlan: Equatable, Sendable { struct Upsert { let alias: String; let properties: [SSHProperty]; let isDefault: Bool; let groupName: String? }; let upserts: [Upsert]; let deleteAliases: [String] }`
  - `enum HostFormReconciler { static func plan(_ form: HostFormModel, existing: [(alias: String, user: String?)], allAliases: Set<String>) -> HostFormPlan }`

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/HostFormReconcilerTests.swift`**

```swift
import Testing
@testable import SSHConfigCore

private func row(_ user: String, port: String = "", key: String = "", extras: [SSHProperty] = []) -> CredentialRow {
    CredentialRow(user: user, port: port, identityFile: key, extras: extras)
}
private func form(_ name: String, host: String, _ rows: [CredentialRow]) -> HostFormModel {
    HostFormModel(displayName: name, hostName: host, rows: rows)
}

@Test func validation() {
    #expect(form("", host: "h", [row("u")]).validationError() != nil)          // empty name
    #expect(form("  ", host: "h", [row("u")]).validationError() != nil)         // blank name
    #expect(form("!!!", host: "h", [row("u")]).validationError() != nil)        // name sanitizes to empty
    #expect(form("web", host: "", [row("u")]).validationError() != nil)         // empty host
    #expect(form("web", host: "h", []).validationError() != nil)                // no rows
    #expect(form("web", host: "h", [row("")]).validationError() != nil)         // row without user
    #expect(form("Prod Web", host: "10.0.0.5", [row("admin")]).validationError() == nil)
}

@Test func singleRowMakesLoneHost() {
    let p = HostFormReconciler.plan(
        form("Prod Web", host: "10.0.0.5", [row("admin", port: "2222", key: "~/.ssh/admin")]),
        existing: [], allAliases: [])
    #expect(p.deleteAliases.isEmpty)
    #expect(p.upserts.count == 1)
    let u = p.upserts[0]
    #expect(u.alias == "Prod-Web")           // sanitize(Name)
    #expect(u.groupName == nil)               // lone host
    #expect(u.isDefault == true)
    #expect(u.properties.first("HostName") == "10.0.0.5")
    #expect(u.properties.first("User") == "admin")
    #expect(u.properties.first("Port") == "2222")
    #expect(u.properties.first("IdentityFile") == "~/.ssh/admin")
}

@Test func multipleRowsFormGroup() {
    let p = HostFormReconciler.plan(
        form("web", host: "h", [row("admin"), row("deploy"), row("ci")]),
        existing: [], allAliases: [])
    #expect(p.upserts.map(\.alias) == ["web", "web-deploy", "web-ci"])
    #expect(p.upserts.allSatisfy { $0.groupName == "web" })     // group id = default alias
    #expect(p.upserts.map(\.isDefault) == [true, false, false])
    #expect(p.upserts[1].properties.first("User") == "deploy")
}

@Test func editKeepsUnchangedAliasesStableAndDiffs() {
    // existing group: web(admin,default), web-deploy(deploy). Edit: keep admin,
    // change deploy→ci (remove deploy row, add ci row).
    let p = HostFormReconciler.plan(
        form("web", host: "h", [row("admin"), row("ci")]),
        existing: [("web", "admin"), ("web-deploy", "deploy")],
        allAliases: ["web", "web-deploy"])
    // admin row keeps "web"; deploy removed; ci is new
    #expect(p.upserts.contains { $0.alias == "web" && $0.properties.first("User") == "admin" && $0.isDefault })
    #expect(p.upserts.contains { $0.alias == "web-ci" && $0.properties.first("User") == "ci" })
    #expect(p.deleteAliases == ["web-deploy"])
}

@Test func preservesRowExtras() {
    let p = HostFormReconciler.plan(
        form("web", host: "h", [row("admin", extras: [SSHProperty(key: "ProxyJump", values: ["bastion"])])]),
        existing: [], allAliases: [])
    #expect(p.upserts[0].properties.first("ProxyJump") == "bastion")
}

@Test func aliasCollisionsSuffixed() {
    let p = HostFormReconciler.plan(
        form("web", host: "h", [row("admin")]),
        existing: [], allAliases: ["web"])   // "web" taken by an unrelated host
    #expect(p.upserts[0].alias == "web-2")
}
```

- [ ] **Step 2: Write failing test — add to `HostGroupingTests.swift`**

```swift
@Test func titleUsesDisplayNameWhenPresent() {
    let g = HostGrouping.groups(from: [
        HostRow(alias: "prod-web", groupName: nil, user: "admin", identityFile: nil,
                isDefault: true, isConnectable: true, displayName: "Prod Web")
    ])
    #expect(g[0].title == "Prod Web")
    #expect(g[0].members[0].alias == "prod-web")
}
```

- [ ] **Step 3: Write failing test — add to `HostEntryMigrationTests.swift`**

```swift
@MainActor @Test func displayNameDefaultsNil() throws {
    let ctx = try makeContext()
    let e = HostEntry(host: "web", properties: [], rawBlock: nil)
    ctx.insert(e); try ctx.save()
    #expect(try ctx.fetch(FetchDescriptor<HostEntry>())[0].displayName == nil)
}
```

- [ ] **Step 4: Run to verify failure**

Run: `swift test --filter HostFormReconcilerTests`
Expected: FAIL — types not found.

- [ ] **Step 5: `HostEntry.swift` — add displayName**

Add after `isDefaultProfile`:
```swift
    /// Human label from the New Host form; shown in the UI, never written to
    /// the ssh config. Nil for entries created before this field / by import.
    public var displayName: String? = nil
```
(Leave `init` as-is; the inline default covers new + migrated rows.)

- [ ] **Step 6: `ProfileFactory.swift` — expose the sanitizer**

Rename the private `sanitize` to `public static func sanitizedAlias(_ label: String) -> String` and update its internal caller. (Keep behavior identical: ASCII `[A-Za-z0-9._-]`, collapse `--`, trim `-`, empty→`"profile"`.)

- [ ] **Step 7: `HostGrouping.swift` — displayName**

Add `public let displayName: String?` to `HostRow` (new last init param, defaulted nil for source compatibility). In `groups(from:)`, capture the first row's `displayName` for the bucket and set `title = rows.first?.displayName ?? rows.first?.groupName ?? members[0].alias`.

- [ ] **Step 8: Create `HostFormModel.swift`**

```swift
import Foundation

public struct CredentialRow: Equatable, Sendable {
    public var user: String
    public var port: String
    public var identityFile: String
    public var extras: [SSHProperty]
    public init(user: String, port: String = "", identityFile: String = "", extras: [SSHProperty] = []) {
        self.user = user; self.port = port; self.identityFile = identityFile; self.extras = extras
    }
    /// Core + preserved-extra properties for this row (HostName supplied by the form).
    func properties(hostName: String) -> [SSHProperty] {
        var p: [SSHProperty] = []
        p.set("HostName", hostName)
        p.set("User", user)
        p.set("Port", port)
        p.set("IdentityFile", identityFile)
        p.append(contentsOf: extras.filter { !$0.key.isEmpty })
        return p
    }
}

public struct HostFormModel: Equatable, Sendable {
    public var displayName: String
    public var hostName: String
    public var rows: [CredentialRow]
    public init(displayName: String, hostName: String, rows: [CredentialRow]) {
        self.displayName = displayName; self.hostName = hostName; self.rows = rows
    }

    public func validationError() -> String? {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Name is required." }
        // Must yield a real alias: at least one ASCII letter or digit.
        if !name.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return "Name must contain letters or numbers."
        }
        if hostName.trimmingCharacters(in: .whitespaces).isEmpty { return "Host (ip or domain) is required." }
        if rows.isEmpty { return "At least one user is required." }
        if rows.contains(where: { $0.user.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Every credential row needs a user."
        }
        return nil
    }
}

public struct HostFormPlan: Equatable, Sendable {
    public struct Upsert: Equatable, Sendable {
        public let alias: String
        public let properties: [SSHProperty]
        public let isDefault: Bool
        public let groupName: String?
        public init(alias: String, properties: [SSHProperty], isDefault: Bool, groupName: String?) {
            self.alias = alias; self.properties = properties; self.isDefault = isDefault; self.groupName = groupName
        }
    }
    public let upserts: [Upsert]
    public let deleteAliases: [String]
}

public enum HostFormReconciler {
    public static func plan(_ form: HostFormModel,
                            existing: [(alias: String, user: String?)],
                            allAliases: Set<String>) -> HostFormPlan {
        let host = form.hostName.trimmingCharacters(in: .whitespaces)
        let base = uniqueAlias(ProfileFactory.sanitizedAlias(form.displayName.trimmingCharacters(in: .whitespaces)),
                               taken: allAliases, existingForThisGroup: Set(existing.map(\.alias)))
        let multi = form.rows.count > 1
        let groupName: String? = multi ? base : nil

        var taken = allAliases
        var usedExisting = Set<String>()
        var upserts: [HostFormPlan.Upsert] = []

        for (i, r) in form.rows.enumerated() {
            let user = r.user.trimmingCharacters(in: .whitespaces)
            let alias: String
            if i == 0 {
                alias = base
            } else if let match = existing.first(where: { $0.user == user && !usedExisting.contains($0.alias) }) {
                alias = match.alias                      // stability: unchanged user keeps its alias
            } else {
                alias = uniqueAlias("\(base)-\(ProfileFactory.sanitizedAlias(user))",
                                    taken: taken, existingForThisGroup: [])
            }
            usedExisting.insert(alias)
            taken.insert(alias)
            upserts.append(.init(alias: alias,
                                 properties: r.properties(hostName: host),
                                 isDefault: i == 0,
                                 groupName: groupName))
        }
        let keep = Set(upserts.map(\.alias))
        let deletes = existing.map(\.alias).filter { !keep.contains($0) }
        return HostFormPlan(upserts: upserts, deleteAliases: deletes)
    }

    /// Prefer `candidate`; if taken by an alias NOT belonging to this group,
    /// suffix -2, -3… (an alias already in this group is fine to reuse).
    private static func uniqueAlias(_ candidate: String, taken: Set<String>,
                                    existingForThisGroup: Set<String>) -> String {
        if !taken.contains(candidate) || existingForThisGroup.contains(candidate) { return candidate }
        var n = 2
        while taken.contains("\(candidate)-\(n)") { n += 1 }
        return "\(candidate)-\(n)"
    }
}
```

Note on the base-alias stability edge: when editing an existing group whose default alias equals `base`, `existingForThisGroup` lets the base keep its alias instead of being suffixed. The `editKeepsUnchangedAliasesStableAndDiffs` test exercises the first row keeping `web`.

- [ ] **Step 9: Run tests**

Run: `swift test`
Expected: all pass (existing + new reconciler/grouping/migration tests). If `validationError`'s "sanitizes to empty" check is awkward, adjust: treat name invalid when `ProfileFactory.sanitizedAlias(name)` has no `[A-Za-z0-9]` — implement that precisely so `"!!!"` fails and `"Prod Web"` passes.

- [ ] **Step 10: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): displayName, display-title grouping, and host-form reconciler"
```

---

### Task 2: App — new HostFormSheet + saveHostForm (create & edit)

**Files:**
- Modify: `App/Sources/Views/HostFormSheet.swift` (full rewrite)
- Modify: `App/Sources/AppModel.swift` (add `saveHostForm`)
- Delete: `App/Sources/Views/AddProfileSheet.swift`
- Modify: `App/Sources/Views/HostDetailView.swift` (Add Profile → edit group)
- Modify: `App/Sources/Views/MainWindow.swift` (edit opens group; drop addProfileBase sheet)

**Interfaces:**
- Consumes: `HostFormModel`, `CredentialRow`, `HostFormReconciler`, `HostFormPlan`, `HostEntry.displayName`, `[SSHProperty].first`.
- Produces: `AppModel.saveHostForm(_ form: HostFormModel, editingGroup groupID: String?) -> String?`; `HostFormSheet(mode:)` presenting the new UI; `FormMode.edit(HostEntry)` loads the whole group.

- [ ] **Step 1: `AppModel.saveHostForm`**

```swift
    /// Applies a HostFormModel: reconciles against the edited group's current
    /// members (nil groupID = create), inserts/updates/deletes HostEntrys, then
    /// exports. Returns an error message or nil.
    func saveHostForm(_ form: HostFormModel, editingGroup groupID: String?) -> String? {
        if let message = form.validationError() { return message }
        let all = (try? context.fetch(FetchDescriptor<HostEntry>())) ?? []
        // Members of the group being edited (by groupName, or the single alias).
        let members = all.filter { entry in
            guard let groupID else { return false }
            return entry.groupName == groupID || entry.host == groupID
        }
        let memberAliases = Set(members.map(\.host))
        let allAliases = Set(all.map(\.host))
        let plan = HostFormReconciler.plan(
            form,
            existing: members.map { ($0.host, $0.properties.first("User")) },
            allAliases: allAliases.subtracting(memberAliases))   // this group's own aliases don't block reuse

        let byAlias = Dictionary(uniqueKeysWithValues: all.map { ($0.host, $0) })
        // Snapshot for rollback of dirty in-memory fields.
        let snapshot = members.map { ($0, $0.host, $0.groupName, $0.isDefaultProfile, $0.displayName) }

        for alias in plan.deleteAliases { if let e = byAlias[alias] { context.delete(e) } }
        for u in plan.upserts {
            let entry = byAlias[u.alias] ?? {
                let e = HostEntry(host: u.alias, properties: u.properties, rawBlock: nil)
                context.insert(e); return e
            }()
            entry.host = u.alias
            entry.properties = u.properties
            entry.groupName = u.groupName
            entry.isDefaultProfile = u.isDefault
            entry.displayName = form.displayName.trimmingCharacters(in: .whitespaces)
            entry.updatedAt = .now
        }
        do {
            try context.save(); exportNow(); return nil
        } catch {
            context.rollback()
            for (e, host, group, isDefault, name) in snapshot {
                e.host = host; e.groupName = group; e.isDefaultProfile = isDefault; e.displayName = name
            }
            return error.localizedDescription
        }
    }
```
(Adapt property/field names to the actual `AppModel`. `exportNow` already exists.)

- [ ] **Step 2: Rewrite `HostFormSheet.swift`**

New UI: `FormMode.create` starts one empty row; `FormMode.edit(entry)` builds a `HostFormModel` from the entry's group (displayName ?? entry.host, HostName from the default member, one `CredentialRow` per member with user/port/identityFile + preserved extras = the member's properties minus HostName/User/Port/IdentityFile). Fields: Name, Host, a `ForEach` over rows with User, Port, and an SSH-key path field + "Choose…" (`NSOpenPanel`, files, canChooseFiles). Add-row button; per-row remove (hidden/disabled when one row). Save calls `model.saveHostForm(form, editingGroup: groupID)` where `groupID` = for edit, `entry.groupName ?? entry.host`; nil for create. Show returned error inline; dismiss on nil. Save disabled while `form.validationError() != nil`.

Delete the old `HostFormData`-based body. (`HostFormData` may remain used elsewhere? Grep — if now unused, leave it or remove in Task 3.)

- [ ] **Step 3: Delete AddProfileSheet + rewire HostDetailView/MainWindow**

`git rm App/Sources/Views/AddProfileSheet.swift`. In `MainWindow.swift` remove `@State addProfileBase` and its `.sheet(item:)`. In `HostDetailView.swift` the "Add Profile…" button now triggers editing the group (call the existing `onEdit(entry)` which opens `HostFormSheet` in edit mode — since edit now shows all rows + an add-row button, that's where you add a profile). Keep per-profile Connect and Remove.

- [ ] **Step 4: Build + test**

Run: `tuist generate --no-open && tuist build Sesh && swift test`
Expected: BUILD SUCCEEDED; tests green. Launch headlessly (no crash). Manual QA noted for the form/file-picker/edit-reconcile.

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "feat(app): Name/Host/credential-rows host form for create and edit"
```

---

### Task 3: App — show displayName across surfaces

**Files:**
- Modify: `App/Sources/AppModel.swift` (`groups(from:)` passes displayName into HostRow)
- Modify: `App/Sources/Views/HostDetailView.swift` (title uses displayName)
- Modify: `App/Sources/Views/MenuBarView.swift`, `App/Sources/Views/CommandPalette.swift` (already use group.title — verify displayName flows through)

**Interfaces:** consumes `HostGroupView.title` (now displayName-aware) and `HostEntry.displayName`.

- [ ] **Step 1: `AppModel.groups(from:)` — pass displayName**

In the `HostRow(...)` mapping add `displayName: e.displayName`. (This makes every grouped surface — sidebar, menu bar, palette — title by displayName automatically, since they derive from `group.title`.)

- [ ] **Step 2: HostDetailView title**

The detail header currently shows `entry.host`. Change to `entry.displayName ?? entry.host` (falls back for imported/legacy entries). The Profiles section still lists per-member aliases/labels.

- [ ] **Step 3: Build + verify**

Run: `tuist generate --no-open && tuist build Sesh && swift test`
Expected: BUILD SUCCEEDED; green. Confirm (grep) MenuBarView/CommandPalette render `group.title` (they do) so no extra change needed beyond Step 1.

- [ ] **Step 4: Commit**

```bash
git add App
git commit -m "feat(app): surface displayName in sidebar, detail, menu bar, and palette"
```

---

### Task 4: Wrap-up — version, build, install

**Files:**
- Modify: `Project.swift` (0.6.0 → 0.7.0)

- [ ] **Step 1: Bump `CFBundleShortVersionString` to `0.7.0`.**

- [ ] **Step 2: Full verification**

Run: `swift test && tuist generate --no-open && tuist build Sesh`
Expected: all pass, BUILD SUCCEEDED.

- [ ] **Step 3: Release build + reinstall + relaunch (menu-bar app)**

```bash
osascript -e 'quit app "Sesh"' 2>/dev/null; pkill -x Sesh 2>/dev/null; sleep 1
tuist generate --no-open
xcodebuild -workspace sshconfig.xcworkspace -scheme Sesh -configuration Release -derivedDataPath build-release build
rm -rf /Applications/Sesh.app
ditto build-release/Build/Products/Release/Sesh.app /Applications/Sesh.app
codesign -v /Applications/Sesh.app
plutil -p /Applications/Sesh.app/Contents/Info.plist | grep ShortVersion   # expect 0.7.0
open /Applications/Sesh.app   # relaunch so the menu-bar icon returns
```

- [ ] **Step 4: Commit**

```bash
git add Project.swift
git commit -m "chore: bump to 0.7.0 — redesigned host form"
```

---

## Self-Review Notes

- **Spec coverage:** displayName field + migration default (Task 1); grouping title (Task 1/3); HostFormModel validation + reconciler with edit stability, group formation, extras preservation, collision suffixing (Task 1); new form UI + file picker + create/edit via saveHostForm (Task 2); AddProfileSheet removed, detail Add Profile → edit (Task 2); displayName across surfaces (Task 3); version/build/install (Task 4).
- **Reconciler edit-stability nuance:** the group's own current aliases are excluded from the "taken" set (`allAliases.subtracting(memberAliases)` in `saveHostForm`, and `existingForThisGroup` in the reconciler) so re-saving an unchanged group doesn't suffix its own aliases. The first row always takes `base`; non-first rows match an existing member by unchanged user to keep its alias, else mint a new one.
- **Data-safety:** save failure rolls back and restores dirty in-memory fields (host/groupName/isDefaultProfile/displayName), consistent with the earlier SwiftData-rollback finding. Export only writes the managed file; the guard from v0.6.0 still prevents managed==config.
- **Type consistency:** `saveHostForm(_:editingGroup:)`, `HostFormReconciler.plan(_:existing:allAliases:)`, `HostFormPlan.Upsert{alias,properties,isDefault,groupName}`, `CredentialRow{user,port,identityFile,extras}`, `ProfileFactory.sanitizedAlias(_:)`, `HostRow(... displayName:)` used consistently across tasks.
- **Deviation risk:** validation's "name must contain a letter/number" replaces the awkward sanitizedAlias=="profile" heuristic — Task 1 Step 9 instructs implementing the precise check.
