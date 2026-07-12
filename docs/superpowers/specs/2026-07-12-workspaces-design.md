# Sesh — Workspaces

**Date:** 2026-07-12
**Status:** Approved design
**Base:** Sesh v0.7.2

## Goal

Group hosts into **workspaces** (first-class, creatable-empty). Sidebar shows
collapsible workspace sections; hosts with no workspace live under an implicit
**Default**. When no user workspaces exist, the sidebar stays flat (today's
one-row-per-host list) — adding the first workspace switches to "workspace
mode". The menu-bar panel mirrors the sidebar sections, with its per-row action
buttons.

## User-confirmed decisions

| Decision | Choice |
|---|---|
| Model | **First-class `Workspace` entity** (creatable empty, renamable, deletable) |
| Assign | **Context menu "Move to Workspace ▸ …"** + a **Workspace picker in the host form** |
| Create | Sidebar **(+) becomes a menu**: New Host / New Workspace |

## Data model

- New `@Model final class Workspace` (app-only, never written to ssh config):
  `@Attribute(.unique) var id: UUID`, `var name: String`, `var createdAt: Date`.
  Ordered by `createdAt` (manual reordering deferred).
- `HostEntry.workspaceID: UUID? = nil` (nil = Default). App-only. A logical host
  (a profile group) belongs to ONE workspace — all its member entries share the
  same `workspaceID`; moves set it on every member.
- `AppModel.container` now `ModelContainer(for: HostEntry.self, Workspace.self)`.
  Lightweight migration (new model + new optional field) on the current empty
  store — no on-disk migration needed.
- Using a stable `id` (not name) as the foreign key means renaming a workspace
  touches only the `Workspace` record, not hosts.

## Core: sectioning

Add `Sources/SSHConfigCore/WorkspaceSectioning.swift` (pure, testable). Since
`Workspace` is a SwiftData `@Model`, the sectioner takes plain inputs:

```swift
public struct WorkspaceRef: Equatable, Sendable { public let id: UUID; public let name: String }
public struct WorkspaceSection: Identifiable, Sendable {
    public let workspace: WorkspaceRef?   // nil = Default
    public let groups: [HostGroupView]
    public var id: String { workspace?.id.uuidString ?? "default" }
    public var title: String { workspace?.name ?? "Default" }
}
public enum WorkspaceSectioning {
    /// rows carry each host's workspaceID; workspaces are ordered as passed.
    /// Produces: Default section first (only if it has groups), then one
    /// section per workspace in input order (even if empty). Each section's
    /// groups come from HostGrouping over that section's rows.
    public static func sections(rows: [HostRow], workspaceIDByAlias: [String: UUID],
                                workspaces: [WorkspaceRef]) -> [WorkspaceSection]
}
```

`HostRow` already feeds `HostGrouping`; the sectioner buckets rows by
`workspaceIDByAlias[alias]` (nil → Default) then runs `HostGrouping.groups` per
bucket. A group's workspace = its default member's workspaceID (members share
it). The UI decides flat vs sectioned: **no workspaces → render the Default
section's groups flat**; **≥1 workspace → render all sections**.

## AppModel

- `workspaces: [Workspace]` — fetched sorted by `createdAt`.
- `var isWorkspaceMode: Bool { !workspaces.isEmpty }`.
- `func sections(from hosts: [HostEntry]) -> [WorkspaceSection]` — maps to
  `HostRow`s (+ a `workspaceID` per alias) and calls the Core sectioner.
- `func createWorkspace(name: String) -> String?` — unique non-empty name;
  insert; save; returns error or nil.
- `func renameWorkspace(_ ws: Workspace, to: String) -> String?`
- `func deleteWorkspace(_ ws: Workspace) -> String?` — reassign its hosts to
  Default (`workspaceID = nil` on all members), delete the `Workspace`, save.
  (Never deletes hosts.)
- `func move(groupDefaultAlias: String, toWorkspace id: UUID?) -> String?` —
  set `workspaceID = id` on every member entry of that logical host; save.
  (Workspace membership isn't in ssh config, so no `exportNow` needed; save
  only, rollback + `pendingError` on failure.)

## Host form

- `HostFormModel` gains `workspaceID: UUID?`. New Host defaults it to the
  workspace context the user created from (or Default). Edit loads the group's
  current `workspaceID`. The form shows a **Workspace** picker (Default + each
  workspace) only when `isWorkspaceMode` (hidden when flat). `saveHostForm`
  writes `workspaceID` onto every upserted member.

## UI

### Sidebar

- Header: search field + a **(+) `Menu`**: "New Host" (opens the form),
  "New Workspace" (name sheet).
- **Flat mode** (no workspaces): unchanged — one row per logical host (Name + IP).
- **Workspace mode**: a `DisclosureGroup` per `WorkspaceSection`. **Default**
  section shown only if it has hosts; each workspace section shown always (even
  empty, so you can move hosts in). Section header = workspace name, with a
  right-click menu: **Rename…**, **Delete** (confirm; hosts fall back to
  Default). Rows inside = the logical-host rows (Name + IP), same tag/selection/
  context-menu as flat mode, plus **Move to Workspace ▸ [Default, each
  workspace, New Workspace…]** on each host.
- Selection, detail, group-aware delete: unchanged.

### Menu bar panel

Mirror the sidebar: flat mode unchanged; workspace mode renders collapsible
workspace sections (Default only if non-empty, then workspaces) each listing its
host rows with the existing per-row Connect/Copy action buttons. Search still
filters across all sections. Footer unchanged.

### New Workspace / Rename sheet

A small sheet: a name `TextField`, Cancel/Save; rejects empty and duplicate
names (case-insensitive). Used for create and rename.

## Error handling

- Duplicate/empty workspace name → inline error, no save.
- Move/rename/delete failures → `context.rollback()` + `pendingError`.
- Deleting the last workspace → `isWorkspaceMode` becomes false → sidebar/menu
  bar revert to flat automatically.
- A host whose `workspaceID` references a deleted workspace (shouldn't happen —
  delete reassigns first) is treated as Default by the sectioner (unknown id →
  Default bucket) as a safety net.

## Testing (swift-testing, Core)

- `WorkspaceSectioningTests`: no workspaces → single Default section with all
  groups; hosts split across Default + 2 workspaces land in the right sections;
  an empty workspace still yields a section (empty groups); Default section
  omitted when it has no hosts; unknown workspaceID → Default; section order =
  Default then workspaces-as-passed; grouping still applies within a section.
- Migration: existing `HostEntry` loads with `workspaceID == nil`; a store with
  no `Workspace` rows → flat.
- App layer (mode switch, disclosure, move menu, form picker, menu-bar mirror) —
  manual QA.

## Out of scope (v1)

- Manual workspace reordering (ordered by creation).
- Nested workspaces; a host in multiple workspaces.
- Persisting per-section collapse state across launches.
- Workspaces affecting the exported `sesh.conf` (purely an app-side view).
