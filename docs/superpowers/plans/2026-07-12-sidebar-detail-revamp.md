# Sidebar + Detail Revamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Sidebar shows one row per logical host — Name on top, HostName (ip/domain) underneath — with an inline search field and a (+) New Host button at the top. Detail section is restyled to mirror the create form (Name / HostName / divider / credentials list with per-credential Connect+Copy actions and an Edit button). No Core changes.

**Architecture:** Pure SwiftUI/view-layer changes in `MainWindow.swift` and `HostDetailView.swift`. Sidebar lists `model.groups(from:)` (one row per group), selection keyed by each group's default-member `persistentModelID`; delete/duplicate operate on the logical host. Detail is a read-only, form-styled view of the whole group.

**Tech Stack:** SwiftUI (macOS 15), SwiftData, Tuist. No new deps, no Core edits, no new tests (app-layer; `swift test` stays 87 green).

**User decisions (this turn):** detail = display styled like the form (edit still via the sheet); sidebar subtitle = HostName (ip/domain); move (+) and search into the sidebar.

## Global Constraints

- Repo `/Users/glenbangkila/AI/sshconfig-swift`, main. Build `tuist generate --no-open && tuist build Sesh`; `swift test` must stay green (87).
- One row per logical host (group or lone). Selection keyed by the group's default member entry id. Editing/adding profiles still goes through `HostFormSheet` (unchanged). Connect via `model.connect(entry)`, copy via `model.copyCommand(entry)` — unchanged.
- Git: NO Co-Authored-By, NO Claude-Session lines, never push. Commits approved.

---

### Task 1: Detail view restyled like the form

**Files:**
- Modify: `App/Sources/Views/HostDetailView.swift`

**Interfaces:**
- Consumes: `AppModel.groups(from:)`, `entry(forAlias:in:)`, `connect(_:with:)`, `copyCommand(_:)`, `selectableTerminals`, `preferredTerminal`; `HostGroupView`/`ProfileRef`; `HostEntry.displayName`. `onEdit(entry)` closure (exists) opens the edit sheet.

- [ ] **Step 1: Rewrite `HostDetailView` body to the form-mirroring layout**

READ the current file first. New structure (ScrollView → VStack, spacing ~16):
1. **Name** — `Text(entry.displayName ?? entry.host).font(.largeTitle.bold())`.
2. **Host** — a labeled row: "HostName" (secondary) + the shared HostName value (`entry.properties.first("HostName") ?? "—"`), selectable, styled like the form's Host field area (a `GroupBox` or a simple labeled row is fine — mirror the form's grouped look).
3. `Divider()`.
4. **Credentials** — a `GroupBox("Credentials")` (or section header) listing one row per group member (from `model.groups(from: hosts)` filtered to this entry's group; a lone host = one row). Each credential row shows: the label (user, bold), and under it `port` (default 22) and the identity file path if any; trailing **action buttons**: a Connect control (the existing per-terminal `Menu`/`primaryAction` targeting `member.alias`, only when `member.isConnectable`) and a **Copy** button (`copyCommand` on the member's entry).
5. A footer button row: **Edit** (`onEdit(entry)` — opens the form sheet where Name/Host/rows are edited/added). Keep the existing per-member **Remove** available too (in the credential row's actions or via Edit — keep Remove in the row's action buttons for parity with the old detail; route it through the existing `onRemoveProfile` closure if present, else `model.removeProfile`).
   - Preserve the current `onEdit`/`onRemoveProfile`/`onAddProfile` closure inputs the view already declares; "Add Profile" is now "Edit" (opens the form to add a row) per the prior wave — keep whatever exists, don't reintroduce AddProfileSheet.
6. Optional: show the per-host raw/ssh command hint as before if it was present — otherwise drop it; the credentials list is the focus.

The layout should read top-to-bottom exactly like the create form: **Name → HostName → divider → credentials**. Reuse the existing `profileRow`/Connect-menu code where possible; the difference from today is the explicit Name title + HostName row + divider above the credentials, matching the form.

- [ ] **Step 2: Build**

Run: `tuist generate --no-open && tuist build Sesh`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Views/HostDetailView.swift
git commit -m "feat(app): restyle host detail to mirror the create form (Name/HostName/credentials)"
```

---

### Task 2: Sidebar — one row per host, inline search + (+), selection/delete on groups; install

**Files:**
- Modify: `App/Sources/Views/MainWindow.swift`
- Modify: `Project.swift` (0.7.1 → 0.7.2)

**Interfaces:** consumes `model.groups(from:)`, `entry(forAlias:in:)`, `model.connect`, existing delete/duplicate helpers, `HostGroupView`.

- [ ] **Step 1: Sidebar header — inline search + (+) New Host**

READ MainWindow first. Remove the `.searchable(text:$search)` modifier and the toolbar `New Host` `ToolbarItem`. In the sidebar column, put a header above the `List`:
```swift
    HStack(spacing: 8) {
        TextField("Search hosts", text: $search)
            .textFieldStyle(.roundedBorder)
        Button {
            formMode = .create
        } label: { Image(systemName: "plus") }
        .buttonStyle(.borderless)
        .keyboardShortcut("n", modifiers: .command)
        .help("New Host")
    }
    .padding(8)
```
Keep ⌘N working via the button's `keyboardShortcut`. Keep the Import / Raw Config / Settings toolbar items as they are.

- [ ] **Step 2: One row per logical host (drop the DisclosureGroup)**

Replace the `List { ForEach(sidebarGroups) { group in if isMultiProfile DisclosureGroup … else memberRow } }` with a flat one-row-per-group list:
```swift
    List(selection: $selection) {
        ForEach(sidebarGroups) { group in
            if let entry = model.entry(forAlias: group.defaultMember.alias, in: hosts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).font(.headline)                 // Name / group label
                    Text(hostSubtitle(group)).font(.caption)          // ip/domain
                        .foregroundStyle(.secondary)
                }
                .tag(entry.persistentModelID)                          // select the logical host
                .contextMenu {
                    Button("Edit") { formMode = .edit(entry) }
                    Button("Duplicate") { duplicate(entry) }
                    Divider()
                    Button("Delete", role: .destructive) { requestDeleteGroup(group) }
                }
            }
        }
    }
```
Add `hostSubtitle(_ group:)` → the shared HostName: resolve the default member's entry, `properties.first("HostName") ?? "—"`. `sidebarGroups` (already exists, search-aware) stays; verify its filter still matches Name/HostName/user — extend the `filtered` predicate to also match `displayName` if not already.

- [ ] **Step 3: Delete a whole logical host**

Selection is now keyed by default-member ids, but a group has multiple member entries. Add `requestDeleteGroup(_ group:)` → confirmationDialog "Delete '\(group.title)'?" whose action deletes ALL member entries of the group (resolve each `group.members` alias → entry, `context.delete`), clears their ids from `selection`, saves (rollback+pendingError), `exportNow()`. For multi-select delete, map each selected id → its group → union of all member entries to delete. Keep the existing single/multi confirmationDialogs but have them delete full groups. (Duplicate stays per-entry on the default member.)

Detail resolution: `detailContent`'s `selection.count == 1` branch resolves the entry by id and shows `HostDetailView(entry:)`, which now renders the whole group — no change needed there beyond it already looking up the group.

- [ ] **Step 4: Build + test + smoke**

Run: `tuist generate --no-open && tuist build Sesh && swift test`
Expected: BUILD SUCCEEDED; 87 green. Launch headlessly (no crash). Manual QA: search filters, (+) opens New Host, rows show Name+IP, selecting shows the form-styled detail, delete removes the whole host/group.

- [ ] **Step 5: Bump version + install**

```bash
sed -i '' 's/"CFBundleShortVersionString": "0.7.1"/"CFBundleShortVersionString": "0.7.2"/' Project.swift
osascript -e 'quit app "Sesh"' 2>/dev/null; pkill -x Sesh 2>/dev/null; sleep 1
tuist generate --no-open
xcodebuild -workspace sshconfig.xcworkspace -scheme Sesh -configuration Release -derivedDataPath build-release build
rm -rf /Applications/Sesh.app
ditto build-release/Build/Products/Release/Sesh.app /Applications/Sesh.app
codesign -v /Applications/Sesh.app
open /Applications/Sesh.app
```

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Views/MainWindow.swift Project.swift
git commit -m "feat(app): sidebar one-row-per-host with inline search + New Host; bump 0.7.2"
```

---

## Self-Review Notes

- **Coverage:** detail restyle to Name/HostName/divider/credentials (Task 1); sidebar Name+IP rows, inline search + (+) moved into the sidebar, one-row-per-logical-host, group-aware delete (Task 2); install (Task 2).
- **Selection nuance:** rows tag the group's default-member id; delete resolves the whole group's members. Duplicate stays per default entry. This avoids a full selection-model rewrite while giving one-row-per-host behavior.
- **Risk:** multi-select delete must union all members of each selected group (a group's non-default members aren't individually selectable now, so deleting a selected group must still remove its extra profiles). Task 2 Step 3 calls this out.
- **No Core/data changes**; export/connect/import paths untouched; `swift test` stays 87.
