# Sesh — App-Primary Data Model & ssh:// Connect (Revamp)

**Date:** 2026-07-11
**Status:** Approved design
**Base:** current Sesh app (v0.5.0). This inverts the source-of-truth model shipped so far.

## Goal

Make the in-app store the source of truth. The app **exports** to an app-owned
ssh config include file (never rewriting the user's `~/.ssh/config`), and
**connects via the `ssh://` URL scheme**. Start with an empty store; leave the
existing `~/.ssh/config` intact.

## User-confirmed decisions

| Decision | Choice |
|---|---|
| Source of truth | **In-app store** (SwiftData), authoritative |
| Config file | App owns `~/.ssh/sesh.conf`; **never rewrites** `~/.ssh/config` |
| Linking to ssh | App adds one idempotent `Include ~/.ssh/sesh.conf` line to `~/.ssh/config` (backup first, existing blocks untouched) |
| Connect | `ssh://<alias>` when the managed file is active, else `ssh://user@host:port` |
| Connect handler | ssh://-registering apps only (Terminal, iTerm2, Warp, system default); a Settings picker chooses |
| Sync/conflict | **Removed.** Replaced by automatic 1-way export + optional manual import |
| Starting data | **Empty** store at a new dedicated location |
| Dropped | argv launchers + Zetty-scratch connect (Zetty/Ghostty/kitty/WezTerm no longer Connect targets) |

## Architecture

### Store relocation & fresh start

`AppModel.container` moves from the implicit shared default
(`~/Library/Application Support/default.store`) to an explicit
`ModelConfiguration(url:)` at `~/Library/Application Support/Sesh/Sesh.store`.
Because that file doesn't exist yet, the app starts empty — satisfying "fresh
start" without deleting anything (the old `default.store` is left on disk,
unused). This also ends the shared-store smell flagged earlier.

`HostEntry` keeps `host`, `properties`, `createdAt`, `updatedAt`, `groupName`,
`isDefaultProfile`. **`rawBlock` is removed** — it existed only to round-trip
original file blocks, which no longer happens (blocks are generated from the
store). SwiftData lightweight migration tolerates a dropped optional in a fresh
store; since we start on a new store URL, there is no on-disk migration at all.

### Core components

Reused: `SSHConfigParser` (for import only), `SSHConfigWriter` (render store →
sesh.conf), `HostEntry`, `HostGrouping`, `ProfileFactory`, `HostValidation`,
`BackupManager`, `SSHProperty`.

**Removed:** `SyncEngine`, `ConflictDetector`, `ConflictResolver`,
`SyncSheet`, `SyncMode`, and the terminal argv machinery in `TerminalRegistry`
(`.openArgs`, `.zettyCLI`) + the corresponding branches in `TerminalLauncher`.

New Core:

- **`ConfigExporter`** (`Sources/SSHConfigCore/ConfigExporter.swift`) — pure
  rendering + a write entry point. `render(entries:) -> String` produces the
  full sesh.conf text (a header comment marking it app-managed, then one `Host`
  block per entry via `SSHConfigWriter.render`). `write(entries:toPath:)` writes
  it `0600` (reusing `SSHConfigWriter.write`'s atomic 0600 + symlink-aware path).
  No segment preservation — the file is 100% app-owned.
- **`IncludeManager`** (`Sources/SSHConfigCore/IncludeManager.swift`) —
  `ensureInclude(managedPath:inConfig:) throws -> Bool` reads `~/.ssh/config`
  (creating it 0600 if absent), returns false if an `Include <managedPath>`
  line is already present (idempotent), else backs the file up
  (`BackupManager`) and writes a new copy with `Include ~/.ssh/sesh.conf` on the
  first line, a blank line, then the original content verbatim. `hasInclude(...)`
  is a pure check used by the connect fallback. Never edits existing blocks.
- **`ConfigImporter`** (`Sources/SSHConfigCore/ConfigImporter.swift`) — thin
  wrapper over `SSHConfigParser`: `hosts(inConfigAt:) -> [ImportedHost]` returns
  parsed host aliases + properties (skipping the managed include and any
  `Match`/`Include`), for the app to insert additively.

### AppModel

Drops: `runSync`, `syncItems`, `conflicts`, `showSyncSheet`, `detector`,
`resolver`, `engine`. Adds:

- `configPath` (existing `ConfigPathStore`, default `~/.ssh/config`) and a new
  `managedPath` (default `~/.ssh/sesh.conf`, stored in UserDefaults).
- `func exportNow()` — renders all `HostEntry`s and writes them to
  `managedPath`, then `IncludeManager.ensureInclude`. Called automatically after
  every create/edit/duplicate/delete/profile mutation (replacing the old
  `autoSyncToFile()`), failures → `pendingError`.
- `func importFromConfig() -> String?` — reads `configPath` via
  `ConfigImporter`, inserts hosts not already present (by alias), saves,
  `exportNow()`. Additive; never deletes. Returns an error or nil. Exposed as a
  Settings / menu action.
- `var managedFileActive: Bool` — `IncludeManager.hasInclude(...)` &&
  `FileManager.fileExists(managedPath)`; drives the connect fallback.
- `connect(_ entry:)` — if `managedFileActive`, open `ssh://<entry.host>`; else
  build `ssh://[user@]hostname[:port]` from the entry's `HostName`/`User`/`Port`
  (falling back to the alias as host when there's no `HostName`). Opened via the
  chosen ssh:// handler (see below). `HostValidation` still guards the alias.

### Connect handler (simplified TerminalLauncher)

`TerminalRegistry` shrinks to ssh://-scheme apps: system default,
`com.apple.Terminal`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`. Each is
launched by opening the `ssh://` URL, optionally with a specific app
(`NSWorkspace.open([url], withApplicationAt:)`); system default uses
`NSWorkspace.open(url)`. `detectInstalled` filters by installed bundle id.
Preferred-terminal preference and the Settings picker stay, limited to this set.
`LaunchPlan`/`arguments(for:)`/the zetty CLI helpers are deleted.

### UI changes

- **Remove** the Sync toolbar menu, `SyncSheet`, and all conflict UI.
- **Toolbar/menu:** add **Import from ~/.ssh/config…** (Settings or the ⌘ menu)
  and keep Raw Config (now showing sesh.conf) + Settings.
- **Settings:** config path field (for import + Include target), managed-file
  path (read-only or editable, default `~/.ssh/sesh.conf`), Connect-with picker
  (ssh:// apps), and a line showing whether the Include is active with a
  "Link into ~/.ssh/config" button that calls `ensureInclude`.
- **Raw Config viewer:** shows `~/.ssh/sesh.conf` (the app-managed file).
- First-run: instead of "set config path then sync", it now offers to link the
  Include (via `ensureInclude`) and optionally Import; a fresh store with no
  hosts shows an empty state prompting New Host / Import.
- Palette, menu bar, grouping, profiles, icon, menu-bar-only shape: unchanged
  except connect routing and the removal of sync actions.

## Data flow

1. User adds/edits a host or profile in-app → store saves → `exportNow()`
   rewrites `~/.ssh/sesh.conf` from the store and ensures the Include.
2. Connect → `ssh://<alias>` resolves via the Include'd sesh.conf (identity,
   port, ProxyJump, all fidelity) → handed to the chosen ssh:// app.
3. Optional Import → parse `~/.ssh/config`, add missing hosts to the store,
   re-export. The user's config is read, never written (except the one Include).

## Error handling

- Export/Include failures → `pendingError` alert; the store change already
  persisted (store is the source of truth, so the file is reconstructable).
- `ensureInclude` backs up `~/.ssh/config` before its single-line edit; if the
  backup or write fails it throws and the config is untouched.
- Import is additive and never deletes; alias collisions are skipped (reported
  in the result summary).
- Connect on a non-connectable alias (wildcards) is disabled as today.

## Testing (swift-testing, Core)

- `ConfigExporterTests`: render produces one block per entry with the managed
  header; multi-value + extras preserved; 0600 write.
- `IncludeManagerTests`: adds the Include once; idempotent on second call;
  backs up before editing; preserves original content verbatim below the
  Include; creates `~/.ssh/config` 0600 when absent; `hasInclude` true/false.
- `ConfigImporterTests`: parses hosts, skips Match/Include/managed lines,
  returns aliases + properties; empty/missing file → [].
- Retained parser/writer/grouping/profile/backup/validation tests stay green;
  removed `SyncEngineTests`/`ConflictTests` are deleted with their code.
- App layer (connect routing, Settings, import action) — manual QA.

## Migration / rollout

- New store URL → empty start automatically; no data migration.
- `sshConfigPath` preference already migrated to `co.webteractive.sesh`.
- Old `SyncEngine`/conflict code and tests are removed in the same change.
- Version → 0.6.0 (breaking model change).

## Out of scope

- Two-way live sync or watching `~/.ssh/config` for external edits (import is
  a manual pull).
- Non-ssh:// terminals (Zetty/Ghostty/kitty/WezTerm) as Connect targets.
- Managing/expanding other `Include`d files or `Match` blocks.
