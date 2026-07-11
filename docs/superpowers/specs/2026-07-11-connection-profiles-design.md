# SSH Config — Connection Profiles (multiple user+identity per host)

**Date:** 2026-07-11
**Status:** Draft for review
**Base:** builds on the shipped app (v0.3.0)

## Goal

Let one logical server carry several **connection profiles** — each a
`{user, identityFile}` pair — and pick one when connecting. User-confirmed
decisions:

- **ssh-native:** each profile is a real `Host` block in `~/.ssh/config`, so it
  works in every terminal and outside the app.
- **Picker everywhere:** the profile chooser appears in the Connect button menu,
  the menu bar rows, and the ⌘K palette.

## The SSH constraint (why this shape)

A single `Host` block can hold only one `User`. "Same server, different users"
is therefore modeled the standard ssh way — **multiple aliases**:

```
Host web
    HostName 10.0.0.5
    User admin
    IdentityFile ~/.ssh/admin

Host web-deploy
    HostName 10.0.0.5
    User deploy
    IdentityFile ~/.ssh/deploy
```

Each alias is a complete, valid, standalone block (usable from any shell). The
app groups `web` and `web-deploy` into one logical host with a profile picker.

## Architecture — additive, core untouched

The risky core (parser / writer / sync / conflicts / backups) is **not
changed**: every profile is an ordinary `HostEntry` that renders as its own
`Host` block and round-trips exactly as today. New work is app-side grouping,
one Core action + model fields, and UI.

### Core changes

1. **`HostEntry` gains two optional fields** (SwiftData lightweight migration —
   added optionals are automatic):
   - `groupName: String?` — non-nil members sharing a value form one logical
     host; nil = standalone (today's behavior). This is **app metadata**, never
     read from or written to the config file.
   - `isDefaultProfile: Bool` (default `false`) — the profile used on a plain
     (non-picked) connect for its group.

   Sync must preserve these: `syncFromFile` already updates only
   `properties`/`rawBlock` on existing entries, so `groupName`/`isDefaultProfile`
   survive a re-import. Entries newly imported from a file get `groupName = nil`
   (ungrouped) — a hand-authored `web`/`web-deploy` pair imports as two separate
   hosts until the user groups them in the app. (Documented tradeoff of keeping
   the file 100% standard.)

2. **`HostGrouping` (pure, testable)** — `Sources/SSHConfigCore/HostGrouping.swift`:
   ```swift
   public struct HostGroupView: Identifiable, Sendable {
       public let id: String            // groupName, or the single host alias
       public let title: String         // display name (groupName or alias)
       public let members: [ProfileRef] // ≥1
   }
   public struct ProfileRef: Identifiable, Sendable {
       public let id: String            // host alias (unique)
       public let alias: String
       public let label: String         // profile label: User, else alias
       public let user: String?
       public let identityFile: String?
       public let isDefault: Bool
       public let isConnectable: Bool
   }
   public enum HostGrouping {
       /// Fold a flat host list into groups: entries with the same non-nil
       /// groupName collapse into one group (default member first, then by
       /// user); nil-group entries each become a singleton group. Ordering of
       /// groups follows the input order of their first member.
       public static func groups(from: [(alias: String, groupName: String?, user: String?, identityFile: String?, isDefault: Bool, isConnectable: Bool)]) -> [HostGroupView]
   }
   ```
   (Takes plain tuples, not `HostEntry`, to stay UI/SwiftData-free and unit-testable.)

3. **`ProfileFactory` (Core action)** — derive a new profile alias + properties
   from a base entry: copy all non-`User`/`IdentityFile` properties (HostName,
   Port, ProxyJump, …), set the chosen `User`/`IdentityFile`, and propose a
   unique alias `"<base>-<label>"` (sanitised to the host charset, `-N` on
   collision). Returns `(alias, properties)`; the app inserts the `HostEntry`
   with the shared `groupName`. Pure except for the uniqueness check (takes the
   set of existing aliases as input).

### App changes

- **Grouping in the sidebar:** the sidebar lists **groups**. A group with one
  member renders as today. A multi-member group shows the title with a profile
  count; expanding (disclosure) or selecting shows its profiles. Selecting a
  group shows a detail view listing profiles.
- **Detail view:** shows the group's shared connection info and a **Profiles**
  section — each profile row has its user/identity, a "default" marker, Edit,
  and **Connect** (per-terminal submenu as today). An **Add Profile** button
  opens a small sheet (label, user, identityFile) that calls `ProfileFactory`
  and inserts a grouped `HostEntry`, then auto-syncs.
- **Grouping actions:** on a host, "Add Profile" (creates a sibling in the same
  group, creating the group on first use and marking the original as default);
  a profile can be removed (deletes that alias' `HostEntry`); "Ungroup" clears
  `groupName` on all members.
- **Connect button menu:** for a multi-profile group, the menu lists
  **Connect as <label>** per profile (each expanding to the per-terminal choice,
  or using the preferred terminal directly); primary click uses the default
  profile. Single-profile hosts behave exactly as today.
- **Menu bar rows:** a host with >1 profile shows a profile submenu / chooser;
  the row's Open-in-Terminal uses the default profile, with the submenu to pick
  another. Copy copies the selected profile's `ssh <alias>`.
- **Command palette:** a multi-profile host expands to one entry per profile —
  `"web · deploy"` — each connecting to that profile's alias. Single-profile
  hosts stay one row.

Connecting always targets a **profile's own alias** (e.g. `ssh web-deploy`), so
no `-l`/`-i` overrides are needed and every terminal path (ssh://, argv, Zetty
scratch) works unchanged. `HostValidation` still guards the alias.

## Error handling

- Adding a profile with a colliding alias → the factory's `-N` suffix resolves
  it; the add sheet validates the label/alias via the existing
  `HostFormData`-style rules and the unique-host check.
- Deleting the last non-default member, or the default: deleting the default
  promotes the earliest remaining member to default; deleting the last member
  removes the group entirely (the host becomes standalone/none).
- Auto-sync after every profile create/edit/delete/group/ungroup (same path as
  existing host mutations), with the same failure alerting.

## Testing (swift-testing, Core)

- `HostGroupingTests`: singletons for nil groups; multi-member fold with default
  first then by user; group order follows first-member input order;
  non-connectable members flagged; mixed grouped/ungrouped input.
- `ProfileFactoryTests`: copies HostName/Port/extras, overrides User/Identity,
  drops the base's User/IdentityFile; alias derivation + `-N` collision;
  sanitises labels with spaces/invalid chars to a valid alias.
- Migration smoke: an in-memory store with pre-existing entries (no group
  fields) loads with `groupName == nil`, `isDefaultProfile == false`.
- App UI (grouping display, pickers, add-profile sheet) — manual QA.

## Out of scope (v1)

- Editing the base's shared fields (HostName/Port) and cascading to all group
  members — v1 edits each profile block independently.
- Auto-detecting groups from hand-authored aliases on import (imports ungrouped).
- Shared-base ssh syntax (`Host web web-*` with a common block) — v1 writes each
  profile as a full standalone block for maximum portability.
