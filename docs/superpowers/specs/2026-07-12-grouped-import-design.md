# Sesh — Grouped Import + First-Run Offer

**Date:** 2026-07-12
**Status:** Approved design
**Base:** Sesh v0.7.0

## Goal

Import the user's existing `~/.ssh/config` into the app's new model: each Host
block becomes a host titled by a **Name** (`displayName`); blocks that share a
`HostName` but have **differing users** are auto-grouped into one logical host
with a credential profile per block. Offer this on first run. Import
**preserves existing aliases** (never renames hosts).

## User-confirmed decisions

- **Structure:** flat (one host per block, `displayName` = alias) EXCEPT
  same-`HostName` blocks whose users differ → merged into a profile group.
- **First run:** offer an explicit "Import from ~/.ssh/config" (opt-in; the user
  previously regretted an unprompted import).
- **Trigger:** enhanced import behind the existing Import action + the first-run
  offer; the user initiates (headless can't click for them).

## Grouping rules (Core, pure)

Parse hosts (existing `SSHConfigParser`). Bucket single-alias hosts by
`HostName`:

- A bucket with **≥2 distinct `User` values** → one **profile group**: keep every
  member's **original alias** (no re-derivation), `groupName` = the first
  member's alias (stable unique id, matching the app's convention),
  `isDefaultProfile` on the first member (file order), `displayName` = the
  members' **longest common alias prefix** trimmed of trailing separators
  (`.-_`); if that's empty/too short (<2 chars), fall back to the first
  member's alias.
- Any other bucket (single member, or all members share one user) → each member
  is a **singleton**: `groupName` = nil, `displayName` = its alias.
- Multi-pattern/wildcard `Host` lines (`* ? !`, spaces) import as singletons
  titled by their pattern (unchanged), never grouped.

New Core type + function in `Sources/SSHConfigCore/ConfigImporter.swift`:

```swift
public struct ImportGroup: Equatable, Sendable {
    public let displayName: String
    public let groupName: String?          // nil for a singleton
    public let members: [ImportedHost]     // ≥1; first is default
}
public extension ConfigImporter {
    /// Parsed hosts folded into import groups per the rules above.
    func groups(inConfigAt path: String) -> [ImportGroup]
}
```

A small pure helper `commonAliasPrefix([String]) -> String` (testable).

## AppModel.importFromConfig (rewrite)

Replace the flat loop with group-aware, still **additive** (skip by alias, never
delete):

- For each `ImportGroup`, for each member whose alias isn't already in the store,
  insert a `HostEntry` (host = member alias, properties = member properties,
  `rawBlock: nil`), set `displayName` = group.displayName, `groupName` =
  group.groupName, and `isDefaultProfile` = true only for the first member of a
  real group (`groupName != nil`); singletons get `isDefaultProfile = false`
  (a lone host's default falls back to its sole member, per the existing model).
- Skipped-by-alias members don't change grouping of what's already there.
- Save (rollback + `pendingError` on failure), then `exportNow()`.
- Return `(added: Int, skipped: Int)` (unchanged signature).

Edge: if only some members of a would-be group already exist, insert the missing
ones with the same `groupName`/`displayName` (they join the group). Members
already present keep their current fields (additive; no clobber).

## First-run offer

`FirstRunSheet`: after the user saves the config path (and the Include is
linked), if the store is empty and `~/.ssh/config` has importable hosts, show an
**"Import my existing hosts"** button (and a "Skip" / dismiss). Tapping it runs
`importFromConfig()` and shows the count. Keep it opt-in — nothing imports
without the tap. The empty-state main window also surfaces an **Import** action
(the toolbar Import button already exists; ensure the empty state points at it).

## Error handling

- Unreadable/missing config → `(0, 0)`, no crash (existing behavior).
- Save failure → rollback + `pendingError`.
- Grouping is deterministic; alias preservation means no collision risk with the
  store beyond the existing skip-by-alias.

## Testing (swift-testing, Core)

- `ConfigImporterTests` (extend): differing-users bucket → one group, members
  keep aliases, first is default, `groupName` = first alias, `displayName` =
  common prefix; same-user bucket → separate singletons; single host → singleton
  `displayName` = alias; wildcard host → singleton, not grouped.
- `commonAliasPrefix`: `["WebteractiveSolutionsTools","WebteractiveSolutionsToolsCoopit"]`
  → `"WebteractiveSolutionsTools"`; no-common → fallback handled by caller;
  trims trailing `.-_`.
- App layer (first-run offer, actual import into the store) — manual QA.

## Out of scope

- Re-deriving/renaming existing aliases on import (explicitly preserved).
- Grouping across different HostNames, or by anything other than shared HostName
  + differing users.
- Auto-import without an explicit tap.
