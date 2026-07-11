# SSH Config — Native Swift macOS App (Port of ~/Herd/sshconfig)

**Date:** 2026-07-08
**Status:** Approved design, pending implementation plan
**Source app:** `~/Herd/sshconfig` (Laravel 12 + Filament 4, wrapped as a Safari app)
**Target:** `~/AI/sshconfig-swift` — native SwiftUI macOS app, fresh design (not a UI copy)

## Goal

Port the SSH Config Manager's feature set to a native macOS app in the spirit of
Zetty and Okke: a real window app plus a menu bar extra, managing `~/.ssh/config`
with a local store, explicit sync, conflict resolution, and backups.

## Decisions (user-confirmed)

| Decision | Choice |
|---|---|
| Data model | **Store + sync** (port the Laravel model: local store is authoritative, explicit sync actions, conflict detection) |
| App shape | **Main window + menu bar extra** |
| Distribution | **Personal / direct** — no sandbox, direct access to `~/.ssh/config` |
| V1 extras | **Connect in terminal**, **raw config viewer**, **extra properties editor** |
| Structure/store | **Tuist + local SPM Core package + SwiftUI app target, SwiftData store** (approach B) |

## Architecture

Mirrors Zetty's layout:

- **Tuist project** `sshconfig`, bundle id `co.webteractive.sshconfig`, app name "SSH Config",
  deployment target macOS 14.0 (SwiftData's floor).
- **`SSHConfigCore`** — local SPM package containing all logic; unit-testable with
  `swift test`, no UI imports.
- **App target** — SwiftUI only: scenes, views, view models. Thin; delegates to Core.
- **Tests** — swift-testing suite against Core.

### Core components (`SSHConfigCore`)

| Component | Ports | Responsibility |
|---|---|---|
| `HostEntry` (`@Model`) | `SshConfig` model + migration | `host: String` (unique), `properties: [SSHProperty]` (ordered; `SSHProperty { key: String, values: [String] }` preserves order and multi-value keys), `rawBlock: String?`, `createdAt`, `updatedAt` |
| `SSHConfigParser` | `ParseSshConfigAction` | Parse config text into segments (see Parser fidelity) |
| `SSHConfigWriter` | `WriteSshConfigAction` | Render store + preserved segments back to file text |
| `SyncEngine` | `SyncSshConfigFromFileAction`, `SyncSshConfigToFileAction`, `SyncSshConfigBothAction` | The three sync modes, same semantics |
| `ConflictDetector` | `DetectSshConfigConflictsAction` | Diff file vs store per host |
| `ConflictResolver` | `ResolveSshConfigConflictAction` | Rename existing entry, or duplicate under a new name |
| `BackupManager` | `CreateSshConfigBackupAction`, `GetSshConfigBackupPathAction` | Timestamped sibling copies, pruned |
| `ConfigPathStore` | `Setting` model, `Get/StoreConfigPathAction` | Config path in `UserDefaults` |

### Settings

- Config file path in `UserDefaults` (native analog of the Laravel `settings` table).
- First-run sheet when unset: path field (accepts `~`, expanded to absolute),
  validation (parent directory must exist), on save: backup if the file exists,
  then initial import (sync from file). Default suggestion `~/.ssh/config`.

## Parser fidelity — ssh_config(5)

The Laravel parser is line-naive; a faithful native port must honor the real
format (per ssh_config(5)) or it will corrupt files on round-trip:

1. **Line syntax:** `keyword arguments`; keywords case-insensitive, arguments
   case-sensitive. Keyword/argument separator is whitespace **or optional
   whitespace and exactly one `=`** (`Port=22` is legal). Arguments may be
   **double-quoted** to contain spaces. Lines starting with `#` and empty lines
   are comments.
2. **Host blocks:** `Host` takes **multiple whitespace-separated patterns** with
   `*`/`?` wildcards and `!` negation. The store keys an entry by the full
   pattern string (e.g. `web1 web2` or `*.example.com`), same as Laravel keyed
   the whole match string.
3. **Match blocks:** parsed as **opaque segments** — preserved verbatim, shown in
   the raw viewer, never editable or destroyed in v1.
4. **Include:** preserved verbatim wherever it appears (top level or inside a
   block). Included files are **not** expanded/managed in v1; the raw viewer
   shows the directive as-is.
5. **Global prologue:** directives before the first `Host`/`Match` (and any
   standalone comments) are preserved verbatim.
6. **First-obtained-value-wins:** ssh uses the first value it finds, so **block
   order matters**. The writer must preserve file order.

### Segment model

`SSHConfigParser` produces an ordered `[Segment]`:

```
enum Segment {
  case hostBlock(ParsedHost)   // managed by the store
  case matchBlock(String)      // opaque, preserved
  case include(String)         // opaque, preserved
  case prologue(String)        // leading directives/comments, preserved
  case comment(String)         // standalone comment/blank runs between blocks
}
```

`ParsedHost` = host pattern string, ordered properties (multi-value aware,
`=`/quote syntax normalized to canonical `Key value` on write), and the raw
block text.

### Writer behavior

`SSHConfigWriter` rebuilds the file from the segment list: non-host segments are
emitted verbatim in their original positions; host blocks are re-rendered from
store entries (`Host <pattern>` + 4-space-indented `Key value` lines, blank line
between blocks); **new store-only hosts are appended at the end** (safe under
first-match-wins when a `Host *` defaults block exists — a caveat surfaced in
the UI if a `Host *` block precedes appended hosts). The written file is
`chmod 0600` (ssh rejects group/world-readable configs); parent directory
created `0700` if missing.

This is a deliberate correctness upgrade over the Laravel writer, which
regenerated the file purely from DB rows and dropped globals/Match/Include.

## Sync semantics (parity with Laravel)

- **From file → store:** upsert every parsed host; file wins on differences;
  `rawBlock` updated.
- **Store → file:** re-render all host segments from the store (preserving
  non-host segments); runs automatically after every create/edit/duplicate/delete,
  mirroring the Filament `after()` hooks; failures warn but don't roll back the
  store change.
- **Both:** file wins on shared hosts (update store), then store-only hosts are
  appended to the file; returns a synced/conflicts summary shown in a sheet.
- **Conflict detection:** three cases — in both but different, store-only,
  file-only. Resolution per host: rename the existing entry, or keep both by
  saving under a new name (replicate), or accept file/store version.

## Backups

Before **every write** to the config file (upgrade over Laravel, which backed up
only when setting the path): copy to `config.backup.YYYY-MM-DD_HHMMSS` beside
the file; keep the 20 most recent, prune older.

## UI

### Main window (fresh design, native idiom)

- `NavigationSplitView`: searchable sidebar list of hosts (alias, `user@hostname`
  subtitle) sorted by recently updated; detail pane for the selected host.
- Detail pane: core fields, extra properties, copyable `ssh <host>` command
  (click to copy, brief confirmation), **Connect** button, per-host raw block.
- Toolbar: **New Host** (⌘N), **Sync** menu (From File / To File / Both),
  **Raw Config**, **Settings**.
- Edit form (sheet): the 5 core fields — Host (required, unique, regex
  `[a-zA-Z0-9._*?-]+` plus spaces between multiple patterns; wildcards allowed,
  a deliberate loosening of the Laravel regex so imported `Host *` stays
  editable), HostName, User, Port (1–65535), IdentityFile — **plus an extra
  properties table** (key/value rows, add/remove/reorder) for arbitrary options
  (ProxyJump, ForwardAgent, ServerAliveInterval, …).
- Row actions: Edit, **Duplicate** (auto `-copy-N` unique suffix), Delete
  (confirm). Multi-select delete supported.
- Sync results & conflicts: summary sheet listing created/updated/appended and
  a conflicts section with per-host resolution actions.

### Menu bar extra

`MenuBarExtra` listing hosts; per host: **Connect** and **Copy ssh command**;
footer: **Open SSH Config** (raise main window), **Sync Both**.

### Connect in terminal

`NSWorkspace.shared.open(URL("ssh://<host>"))` — launches the user's default
`ssh://` handler (Terminal, iTerm2, Ghostty all register); ssh itself resolves
the alias against the config. No per-terminal AppleScript in v1. Hosts whose
pattern contains wildcards/negation/spaces don't get a Connect button (not a
single connectable alias).

### Raw config viewer

Read-only monospaced window with the current file contents and a
refresh-from-disk button.

## Error handling

- Config path unset → sync actions disabled; first-run sheet is the default action.
- File missing → from-file reports "nothing to import"; to-file creates it.
- Write/backup failure → alert (warning style), store change already applied
  (parity with Laravel's `rescue()` + warning notification).
- Duplicate host → caught in form validation before save.
- File permissions: written as `0600`; if the existing file is more permissive,
  fix on write.

## Testing

swift-testing in `SSHConfigCore`:

- **Parser:** fixtures for comments, blank lines, multi-value keys (multiple
  `IdentityFile`), `=` separator, quoted arguments, multiple host patterns,
  wildcards/negation, Match blocks, Include lines, global prologue.
- **Writer:** snapshot output; **round-trip** parse → write → parse equality,
  including files with Match/Include/globals (must survive untouched).
- **SyncEngine:** all three modes — file-wins updates, store-only append,
  created/updated/added reporting.
- **ConflictDetector:** matrix of both-differ / store-only / file-only.
- **BackupManager:** naming format, pruning to 20.
- App layer is thin; no UI tests in v1.

## Out of scope (v1)

- Editing Match blocks or expanding/managing Include files.
- SSH key generation/management, known_hosts, agent integration.
- Per-terminal connect integrations beyond the `ssh://` URL scheme.
- iCloud/device sync, App Store distribution.
