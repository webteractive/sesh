# Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Group hosts into first-class workspaces — collapsible sidebar sections (Default + user workspaces), flat until the first workspace exists, mirrored in the menu-bar panel, with move/assign via context menu + form picker.

**Architecture:** New `Workspace` `@Model` + `HostEntry.workspaceID`; pure `WorkspaceSectioning` layered over existing `HostGrouping`; AppModel workspace CRUD/move + `sections(from:)`; sidebar/menu-bar render sections in workspace mode, flat otherwise; host form gains a Workspace picker.

**Tech Stack:** Swift v5, SwiftUI (macOS 15), SwiftData, swift-testing, Tuist.

**Spec:** `docs/superpowers/specs/2026-07-12-workspaces-design.md` — read first.

## Global Constraints

- Repo `/Users/glenbangkila/AI/sshconfig-swift`, main. Build `tuist generate --no-open && tuist build Sesh`; `swift test` stays green (87).
- Workspaces are **app-only** — never affect exported `~/.ssh/sesh.conf`; move/rename/delete never call `exportNow`. A logical host (profile group) belongs to ONE workspace; moves set `workspaceID` on every member. `workspaceID` nil = Default. Unknown id → Default (safety net).
- Core (`Sources/SSHConfigCore/**`) Foundation/SwiftData only.
- Git: NO Co-Authored-By, NO Claude-Session lines, never push. Commits approved.

---

### Task 1: Core — Workspace model, HostEntry.workspaceID, WorkspaceSectioning

**Files:**
- Create: `Sources/SSHConfigCore/Workspace.swift`
- Modify: `Sources/SSHConfigCore/HostEntry.swift` (add `workspaceID`)
- Create: `Sources/SSHConfigCore/WorkspaceSectioning.swift`
- Test: `Tests/SSHConfigCoreTests/WorkspaceSectioningTests.swift`
- Test: `Tests/SSHConfigCoreTests/HostEntryMigrationTests.swift` (add workspaceID default)

**Interfaces:**
- Consumes: `HostRow`, `HostGrouping.groups`, `HostGroupView`.
- Produces:
  - `@Model final class Workspace { @Attribute(.unique) var id: UUID; var name: String; var createdAt: Date; init(name:) }`.
  - `HostEntry.workspaceID: UUID? = nil`.
  - `struct WorkspaceRef: Equatable, Sendable { let id: UUID; let name: String }`
  - `struct WorkspaceSection: Identifiable, Sendable { let workspace: WorkspaceRef?; let groups: [HostGroupView]; var id: String; var title: String }`
  - `enum WorkspaceSectioning { static func sections(rows: [HostRow], workspaceIDByAlias: [String: UUID], workspaces: [WorkspaceRef]) -> [WorkspaceSection] }`

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/WorkspaceSectioningTests.swift`**

```swift
import Testing
import Foundation
@testable import SSHConfigCore

private func row(_ alias: String, group: String? = nil, user: String? = "u",
                 isDefault: Bool = true) -> HostRow {
    HostRow(alias: alias, groupName: group, user: user, identityFile: nil,
            isDefault: isDefault, isConnectable: true, displayName: alias)
}

@Test func noWorkspacesYieldsSingleDefaultSection() {
    let s = WorkspaceSectioning.sections(
        rows: [row("a"), row("b")], workspaceIDByAlias: [:], workspaces: [])
    #expect(s.count == 1)
    #expect(s[0].workspace == nil)
    #expect(s[0].title == "Default")
    #expect(s[0].groups.count == 2)
}

@Test func hostsSplitAcrossDefaultAndWorkspaces() {
    let w1 = WorkspaceRef(id: UUID(), name: "Prod")
    let w2 = WorkspaceRef(id: UUID(), name: "Staging")
    let s = WorkspaceSectioning.sections(
        rows: [row("a"), row("b"), row("c")],
        workspaceIDByAlias: ["b": w1.id, "c": w2.id],
        workspaces: [w1, w2])
    #expect(s.map(\.title) == ["Default", "Prod", "Staging"])   // Default first, then input order
    #expect(s[0].groups.map(\.title) == ["a"])
    #expect(s[1].groups.map(\.title) == ["b"])
    #expect(s[2].groups.map(\.title) == ["c"])
}

@Test func defaultSectionOmittedWhenEmpty() {
    let w1 = WorkspaceRef(id: UUID(), name: "Prod")
    let s = WorkspaceSectioning.sections(
        rows: [row("a")], workspaceIDByAlias: ["a": w1.id], workspaces: [w1])
    #expect(s.map(\.title) == ["Prod"])                          // no Default (nothing in it)
    #expect(s[0].groups.map(\.title) == ["a"])
}

@Test func emptyWorkspaceStillYieldsSection() {
    let w1 = WorkspaceRef(id: UUID(), name: "Empty")
    let s = WorkspaceSectioning.sections(
        rows: [row("a")], workspaceIDByAlias: [:], workspaces: [w1])
    #expect(s.map(\.title) == ["Default", "Empty"])
    #expect(s[1].groups.isEmpty)
}

@Test func unknownWorkspaceIDFallsToDefault() {
    let w1 = WorkspaceRef(id: UUID(), name: "Prod")
    let s = WorkspaceSectioning.sections(
        rows: [row("a")], workspaceIDByAlias: ["a": UUID()],     // id not in `workspaces`
        workspaces: [w1])
    #expect(s.first(where: { $0.workspace == nil })?.groups.map(\.title) == ["a"])
}

@Test func groupingStillAppliesWithinSection() {
    let s = WorkspaceSectioning.sections(
        rows: [row("web", group: "web", isDefault: true),
               row("web-deploy", group: "web", user: "deploy", isDefault: false)],
        workspaceIDByAlias: [:], workspaces: [])
    #expect(s[0].groups.count == 1)                              // one profile group
    #expect(s[0].groups[0].members.count == 2)
}
```

- [ ] **Step 2: Write failing test — add to `HostEntryMigrationTests.swift`**

```swift
@MainActor @Test func workspaceIDDefaultsNil() throws {
    let ctx = try makeContext()
    let e = HostEntry(host: "web", properties: [], rawBlock: nil)
    ctx.insert(e); try ctx.save()
    #expect(try ctx.fetch(FetchDescriptor<HostEntry>())[0].workspaceID == nil)
}
```

Note: `makeContext()` builds a `ModelContainer` for `HostEntry.self`; adding `workspaceID` needs no container change for these Core tests. (The App container gains `Workspace.self` in Task 2.)

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter WorkspaceSectioningTests`
Expected: FAIL — `WorkspaceSectioning`/`WorkspaceRef` not found.

- [ ] **Step 4: Create `Sources/SSHConfigCore/Workspace.swift`**

```swift
import Foundation
import SwiftData

@Model
public final class Workspace {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
    }
}
```

- [ ] **Step 5: `HostEntry.swift` — add workspaceID**

Add after `displayName`:
```swift
    /// App-only workspace membership (nil = Default). Never written to ssh config.
    public var workspaceID: UUID? = nil
```

- [ ] **Step 6: Create `Sources/SSHConfigCore/WorkspaceSectioning.swift`**

```swift
import Foundation

public struct WorkspaceRef: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

public struct WorkspaceSection: Identifiable, Sendable {
    public let workspace: WorkspaceRef?      // nil = Default
    public let groups: [HostGroupView]
    public var id: String { workspace?.id.uuidString ?? "default" }
    public var title: String { workspace?.name ?? "Default" }
    public init(workspace: WorkspaceRef?, groups: [HostGroupView]) {
        self.workspace = workspace; self.groups = groups
    }
}

public enum WorkspaceSectioning {
    public static func sections(rows: [HostRow],
                                workspaceIDByAlias: [String: UUID],
                                workspaces: [WorkspaceRef]) -> [WorkspaceSection] {
        let known = Set(workspaces.map(\.id))
        // Bucket rows: nil / unknown id → Default.
        var defaultRows: [HostRow] = []
        var byWorkspace: [UUID: [HostRow]] = [:]
        for r in rows {
            if let wid = workspaceIDByAlias[r.alias], known.contains(wid) {
                byWorkspace[wid, default: []].append(r)
            } else {
                defaultRows.append(r)
            }
        }
        var result: [WorkspaceSection] = []
        if !defaultRows.isEmpty {
            result.append(WorkspaceSection(workspace: nil, groups: HostGrouping.groups(from: defaultRows)))
        }
        for ws in workspaces {
            result.append(WorkspaceSection(
                workspace: ws,
                groups: HostGrouping.groups(from: byWorkspace[ws.id] ?? [])))
        }
        return result
    }
}
```

- [ ] **Step 7: Run tests**

Run: `swift test`
Expected: all green (existing + new sectioning/migration).

- [ ] **Step 8: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): Workspace model, HostEntry.workspaceID, workspace sectioning"
```

---

### Task 2: App — AppModel workspace CRUD/move/sections + container + form picker

**Files:**
- Modify: `App/Sources/AppModel.swift`
- Modify: `Sources/SSHConfigCore/HostFormModel.swift` (add `workspaceID`)
- Modify: `App/Sources/Views/HostFormSheet.swift` (Workspace picker)

**Interfaces:**
- Consumes: `Workspace`, `WorkspaceSectioning`, `WorkspaceRef`, `WorkspaceSection`, `HostRow`, `HostFormModel`.
- Produces (Task 3 relies on these): `AppModel.workspaces: [Workspace]` (computed fetch, sorted createdAt); `isWorkspaceMode: Bool`; `sections(from hosts: [HostEntry]) -> [WorkspaceSection]`; `createWorkspace(name:) -> String?`; `renameWorkspace(_:to:) -> String?`; `deleteWorkspace(_:) -> String?`; `move(groupDefaultAlias:toWorkspace id: UUID?) -> String?`. `HostFormModel.workspaceID: UUID?`.

- [ ] **Step 1: Container + workspace queries in `AppModel`**

Change the container line to `try ModelContainer(for: HostEntry.self, Workspace.self, configurations: config)`. Add:
```swift
    var workspaces: [Workspace] {
        (try? context.fetch(FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }
    var isWorkspaceMode: Bool { !workspaces.isEmpty }

    func sections(from hosts: [HostEntry]) -> [WorkspaceSection] {
        let rows = hosts.map { e in
            HostRow(alias: e.host, groupName: e.groupName,
                    user: e.properties.first("User"), identityFile: e.properties.first("IdentityFile"),
                    isDefault: e.isDefaultProfile, isConnectable: e.isConnectable,
                    displayName: e.displayName)
        }
        var widByAlias: [String: UUID] = [:]
        for e in hosts { if let w = e.workspaceID { widByAlias[e.host] = w } }
        let refs = workspaces.map { WorkspaceRef(id: $0.id, name: $0.name) }
        return WorkspaceSectioning.sections(rows: rows, workspaceIDByAlias: widByAlias, workspaces: refs)
    }
```

- [ ] **Step 2: Workspace CRUD + move in `AppModel`**

```swift
    func createWorkspace(name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Workspace name is required." }
        if workspaces.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            return "A workspace named '\(n)' already exists."
        }
        context.insert(Workspace(name: n))
        return saveOrRollback()
    }

    func renameWorkspace(_ ws: Workspace, to name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Workspace name is required." }
        if workspaces.contains(where: { $0.id != ws.id && $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            return "A workspace named '\(n)' already exists."
        }
        let old = ws.name
        ws.name = n
        if let e = saveOrRollback() { ws.name = old; return e }
        return nil
    }

    func deleteWorkspace(_ ws: Workspace) -> String? {
        let id = ws.id
        let affected = (try? context.fetch(FetchDescriptor<HostEntry>()))?.filter { $0.workspaceID == id } ?? []
        let snapshot = affected.map { ($0, $0.workspaceID) }
        for e in affected { e.workspaceID = nil }        // reassign to Default (never delete hosts)
        context.delete(ws)
        if let err = saveOrRollback() {
            for (e, w) in snapshot { e.workspaceID = w }
            return err
        }
        return nil
    }

    /// Move a whole logical host (all members of the group whose default alias
    /// is `groupDefaultAlias`) to a workspace (nil = Default).
    func move(groupDefaultAlias alias: String, toWorkspace id: UUID?) -> String? {
        let all = (try? context.fetch(FetchDescriptor<HostEntry>())) ?? []
        guard let anchor = all.first(where: { $0.host == alias }) else { return nil }
        let key = anchor.groupName ?? anchor.host
        let members = all.filter { ($0.groupName ?? $0.host) == key }
        let snapshot = members.map { ($0, $0.workspaceID) }
        for m in members { m.workspaceID = id }
        if let err = saveOrRollback() {
            for (m, w) in snapshot { m.workspaceID = w }
            return err
        }
        return nil
    }

    private func saveOrRollback() -> String? {
        do { try context.save(); return nil }
        catch { context.rollback(); pendingError = error.localizedDescription; return error.localizedDescription }
    }
```
(If an equivalent save helper already exists, reuse it. Workspace ops do NOT call `exportNow` — membership isn't in ssh config.)

- [ ] **Step 3: `HostFormModel.workspaceID` + saveHostForm**

In `Sources/SSHConfigCore/HostFormModel.swift`, add `public var workspaceID: UUID?` to `HostFormModel` (default nil in a new memberwise init param — keep the existing init working: add `workspaceID: UUID? = nil` as the last param). `HostFormPlan.Upsert` does NOT need it (workspace is applied in the app after upsert, since it's not an ssh property). In `AppModel.saveHostForm`, after building each `HostEntry`, set `entry.workspaceID = form.workspaceID`. On edit, load `form.workspaceID` from the group's default member. Include `workspaceID` in the save-failure snapshot/restore already present in `saveHostForm`.

- [ ] **Step 4: Workspace picker in `HostFormSheet`**

READ the current file. When `model.isWorkspaceMode`, show a `Picker("Workspace", …)` over `[Default] + model.workspaces` bound to `form.workspaceID` (tag `UUID?`). New Host: default `form.workspaceID` to the workspace the create was initiated from (Task 3 passes it in; default nil). Edit: initialize from the group's default member's `workspaceID`. Hidden when not in workspace mode.

- [ ] **Step 5: Build + test**

Run: `tuist generate --no-open && tuist build Sesh && swift test`
Expected: BUILD SUCCEEDED; green.

- [ ] **Step 6: Commit**

```bash
git add App Sources/SSHConfigCore/HostFormModel.swift
git commit -m "feat(app): workspace CRUD/move, sectioning, and host-form workspace picker"
```

---

### Task 3: App — sidebar sections + (+) menu + move menu; menu-bar mirror; install

**Files:**
- Modify: `App/Sources/Views/MainWindow.swift`
- Modify: `App/Sources/Views/MenuBarView.swift`
- Create: `App/Sources/Views/WorkspaceNameSheet.swift`
- Modify: `Project.swift` (0.7.2 → 0.8.0)

**Interfaces:** consumes `AppModel.sections/isWorkspaceMode/workspaces/createWorkspace/renameWorkspace/deleteWorkspace/move`.

- [ ] **Step 1: Sidebar (+) menu + New Workspace sheet**

READ MainWindow. Turn the sidebar header (+) `Button` into a `Menu` labeled `Image(systemName: "plus")`: "New Host" (`formMode = .create`), "New Workspace" (`showNewWorkspace = true`). Add `@State private var showNewWorkspace = false` and a `.sheet(isPresented:)` presenting `WorkspaceNameSheet(mode: .create)`. Keep ⌘N → New Host (attach the shortcut to the New Host menu item or a hidden button as today).

Create `WorkspaceNameSheet.swift`: `enum WorkspaceSheetMode { case create; case rename(Workspace) }`; a name TextField + Cancel/Save; Save calls `model.createWorkspace` / `model.renameWorkspace`, shows inline error, dismisses on nil.

- [ ] **Step 2: Sidebar sections (workspace mode) vs flat**

Replace the sidebar `List` body with:
```swift
    List(selection: $selection) {
        if model.isWorkspaceMode {
            ForEach(model.sections(from: hosts)) { section in
                Section {
                    ForEach(section.groups) { group in hostRow(group) }
                } header: {
                    workspaceHeader(section)     // name; right-click Rename…/Delete for a real workspace
                }
            }
        } else {
            ForEach(sidebarGroups) { group in hostRow(group) }
        }
    }
```
Factor the existing row body into `hostRow(_ group:)` (Name + IP, tag = default member's persistentModelID, existing context menu PLUS a `Menu("Move to Workspace")` listing Default + each workspace + "New Workspace…" → `model.move(groupDefaultAlias: group.defaultMember.alias, toWorkspace: id)`; "New Workspace…" opens the sheet then moves on save — simplest: just list existing workspaces + Default now, and a "New Workspace…" that opens the create sheet; moving into a brand-new one can be a follow-up if wiring the callback is heavy — but prefer: create then move). Use `Section(header:)` for collapsibility (macOS sidebar sections collapse); if true disclosure collapse is needed, wrap in `DisclosureGroup` instead — pick whichever renders collapsible in a `List`. `workspaceHeader` for `section.workspace != nil` gets a `.contextMenu { Rename…; Delete }`; the Default header has no menu. `search` filtering: apply the existing `filtered`/search to the rows feeding `sections(from:)` (compute sections from the filtered host set so search works across sections).

- [ ] **Step 3: Menu-bar mirror**

READ MenuBarView. In workspace mode, group the rows under section headers (`Text(section.title).font(.caption).foregroundStyle(.secondary)` then its rows) using `model.sections(from: filtered)`; flat mode unchanged. Keep per-row Connect/Copy action buttons and search/keyboard/footer. Default section only when non-empty (the sectioner already omits it).

- [ ] **Step 4: Bump version 0.7.2 → 0.8.0 in `Project.swift`.**

- [ ] **Step 5: Build + test + smoke**

Run: `tuist generate --no-open && tuist build Sesh && swift test`
Expected: BUILD SUCCEEDED; 87+ green. Launch headlessly (no crash). Manual QA: add a workspace → sidebar switches to sections; move a host; rename/delete workspace; menu-bar mirrors.

- [ ] **Step 6: Release build + reinstall + relaunch**

```bash
osascript -e 'quit app "Sesh"' 2>/dev/null; pkill -x Sesh 2>/dev/null; sleep 1
tuist generate --no-open
xcodebuild -workspace sshconfig.xcworkspace -scheme Sesh -configuration Release -derivedDataPath build-release build
rm -rf /Applications/Sesh.app
ditto build-release/Build/Products/Release/Sesh.app /Applications/Sesh.app
codesign -v /Applications/Sesh.app
plutil -p /Applications/Sesh.app/Contents/Info.plist | grep ShortVersion   # 0.8.0
open /Applications/Sesh.app
```

- [ ] **Step 7: Commit**

```bash
git add App Project.swift
git commit -m "feat(app): collapsible workspace sections in sidebar + menu bar; bump 0.8.0"
```

---

## Self-Review Notes

- **Coverage:** Workspace model + workspaceID + sectioning + tests (Task 1); container, CRUD/move/sections, form picker (Task 2); sidebar sections + (+) menu + move menu + New Workspace/Rename sheet, menu-bar mirror, install (Task 3).
- **App-only invariant:** move/rename/delete/create never call `exportNow` — workspaces don't touch ssh config. Stated in Global Constraints + Task 2.
- **Whole-group move:** `move` resolves the group by `groupName ?? host` and sets `workspaceID` on all members — mirrors the delete/saveHostForm convention.
- **Mode switch:** `isWorkspaceMode = !workspaces.isEmpty`; Task 3 branches sidebar/menu-bar on it; Default section auto-omitted when empty by the Core sectioner.
- **Type consistency:** `sections(from:)`, `WorkspaceSection{workspace,groups,title}`, `move(groupDefaultAlias:toWorkspace:)`, `createWorkspace/renameWorkspace/deleteWorkspace`, `HostFormModel.workspaceID` used consistently across tasks.
- **Risk/known-simplification:** "Move to a brand-new workspace" may be a two-step (create via sheet, then move) if inline callback wiring is heavy — Task 3 Step 2 permits that fallback. Collapsible: use `Section` or `DisclosureGroup`, whichever actually collapses in a `List` on macOS 15 — implementer verifies at build/smoke.
