# Sesh — Host Form Redesign (Name + Host + credential rows)

**Date:** 2026-07-12
**Status:** Approved design
**Base:** Sesh v0.6.0 (app-primary model)

## Goal

Replace the add/edit host form with: **Name**, **Host (ip/domain)**, then a
**repeater of {User, Port, SSH key} rows (≥1 required)**. Each credential row is
a real ssh alias (a connection profile). Create and edit both use this form.

## User-confirmed decisions

| Decision | Choice |
|---|---|
| Name | A friendly **display label** (`displayName`); the ssh alias is *derived* from it (`sanitize(Name)`), not typed |
| Host | `HostName` (ip/domain), shared across all rows of the entry |
| Rows | `{User, Port, SSH key}`, ≥1 required; each row → one ssh alias |
| Alias naming | Default/first row alias = `sanitize(Name)` (unique); additional rows = `sanitize(Name)-<user>` |
| Edit | Same form; opens the whole group and reconciles add/remove/edit of rows |
| Extras | The free-form extra-properties editor is dropped from this form; existing extra properties are **preserved** round-trip (not editable here) |

## Data model

Add one field to `HostEntry`:

- `displayName: String?` — the human label from the form. Shown in the sidebar,
  menu bar, palette, and detail title. App-only, never written to `sesh.conf`
  (SwiftData lightweight migration; optional/defaulted, safe on the current
  empty store).

`groupName` keeps its role as the unique group id (the default row's alias).
A single-row entry has `groupName == nil` (lone host); a multi-row entry sets
`groupName` = the default alias on every member (existing grouping semantics).
Every entry created/edited via the form carries `displayName`.

`HostGrouping` gains display-title awareness: `HostRow` gets a `displayName:
String?`; `HostGroupView.title` becomes `displayName ?? groupName ?? alias`
(members carry their own alias; the group shows the label). `ProfileRef` keeps
`label` = user (row-level), unchanged.

## Core: `HostFormModel` + reconciliation

New pure type `Sources/SSHConfigCore/HostFormModel.swift` (UI-agnostic,
testable):

```swift
public struct CredentialRow: Equatable, Sendable {
    public var user: String
    public var port: String
    public var identityFile: String
    public var extras: [SSHProperty]     // preserved, not shown in v1
    public init(user:port:identityFile:extras:)
}

public struct HostFormModel: Equatable, Sendable {
    public var displayName: String
    public var hostName: String
    public var rows: [CredentialRow]     // ≥1
    public init(displayName:hostName:rows:)

    public func validationError() -> String?   // name non-empty & sanitizes to non-empty alias; hostName non-empty; ≥1 row; each row has a user
}

/// The set of HostEntry mutations to realize a form for a group.
public struct HostFormPlan: Equatable, Sendable {
    public struct Upsert: Equatable, Sendable {
        public let alias: String
        public let properties: [SSHProperty]  // HostName, User, Port, IdentityFile (+ preserved extras)
        public let isDefault: Bool
        public let groupName: String?
    }
    public let upserts: [Upsert]           // create or update these aliases
    public let deleteAliases: [String]     // aliases to remove (rows removed on edit)
}

public enum HostFormReconciler {
    /// Given the desired form and the group's existing members (alias + user),
    /// produce the create/update/delete plan. Row identity is matched by the
    /// existing member's alias when its user is unchanged; new rows get fresh
    /// unique aliases; existing members whose row was removed are deleted.
    public static func plan(_ form: HostFormModel,
                            existing: [(alias: String, user: String?)],
                            allAliases: Set<String>) -> HostFormPlan
}
```

Alias rules (reuse `ProfileFactory.sanitize` charset): base = unique
`sanitize(displayName)` among `allAliases`; additional rows =
`sanitize(displayName)-<user>` unique-suffixed. The first row is the default;
its alias is the `groupName` for all members when there are ≥2 rows (nil when
one row). On edit, an existing member whose user is unchanged **keeps its
current alias** (so `sesh.conf` aliases and any muscle memory stay stable);
only genuinely new rows mint new aliases and removed rows are deleted.

## App layer

- **`HostFormSheet` rewritten**: Name field, Host field, a `ForEach` repeater of
  credential rows (User, Port, SSH key path with an NSOpenPanel "Choose…"
  button), an "Add credential" button, per-row remove (disabled when only one
  row remains). Save is disabled until `validationError()` is nil.
- **`AppModel`** gains `saveHostForm(_ form: HostFormModel, editing groupID: String?) -> String?`:
  builds `allAliases` from the store, calls `HostFormReconciler.plan`, applies
  it (insert/update `HostEntry`s, set `displayName`/`groupName`/`isDefaultProfile`,
  delete removed), `context.save()` with rollback-on-failure, then `exportNow()`.
  Returns an error message or nil.
- **Edit**: `FormMode.edit` now carries the group. Opening edit loads a
  `HostFormModel` from the group's members (displayName, shared HostName, one
  row per member with its user/port/key + preserved extras). `HostFormReconciler`
  handles the diff on save.
- **Remove** the separate `AddProfileSheet` (its job — adding a credential — is
  now "add a row" in the edit form). `HostDetailView`'s "Add Profile…" action is
  replaced by opening the group in the edit form (where the user adds a row);
  its per-profile **Connect** pickers are unchanged, and its per-profile
  **Remove** stays as a shortcut (deletes that alias, same as removing its row).
- **Duplicate**: still duplicates a single entry's alias with a `-copy-N`
  suffix; it copies `displayName` too.

## Data flow

Create: form → `saveHostForm(form, editing: nil)` → N `HostEntry`s (1 default +
extras) → save → `exportNow()` writes `sesh.conf` + ensures Include. Connect
uses `ssh://<alias>` per row as today.

Edit: form → `saveHostForm(form, editing: groupID)` → reconciler diffs against
current members → upserts/deletes → save → export.

## Error handling

- `validationError()` blocks save (empty Name/Host, Name that sanitizes to
  empty, zero rows, a row missing a user).
- Save failure → `context.rollback()` + `pendingError`; explicitly restore any
  in-memory `displayName`/`groupName`/`isDefaultProfile` mutations (SwiftData
  rollback doesn't revert dirty properties on existing objects — established
  earlier in this codebase).
- Alias collisions are resolved by unique-suffixing in the reconciler; never
  throws for that.

## Testing (swift-testing, Core)

- `HostFormModelTests`: validation (empty name, name→empty-after-sanitize,
  empty host, zero rows, row without user); happy path.
- `HostFormReconcilerTests`: single row → one upsert, groupName nil, isDefault
  true; three rows → base alias = sanitize(name), two `-user` aliases, groupName
  = base on all, first is default; **edit stability** — unchanged user keeps its
  alias; a new row mints a new alias; a removed row appears in `deleteAliases`;
  preserved extras carried through; alias collisions suffixed.
- `HostGroupingTests`: title uses `displayName` when present.
- Migration: existing entries load with `displayName == nil` (title falls back
  to groupName/alias).
- App layer (form UI, file picker, edit reconcile end-to-end) — manual QA.

## Out of scope

- Editing arbitrary extra ssh options in this form (preserved, not shown).
- Per-row distinct HostName (the Host field is shared across a group's rows).
- Bulk/CSV host entry.
