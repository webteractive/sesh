# Sesh

Native macOS menu-bar app for managing SSH connections. **The app is the source
of truth**: you manage hosts in Sesh, and it exports them to an app-owned
`~/.ssh/sesh.conf` that's linked into your `~/.ssh/config` via a single
`Include` line. Your existing config is never rewritten.

## Features

- App-primary host management (create, edit, duplicate, delete) — the store is
  authoritative, not the file
- Automatic export to `~/.ssh/sesh.conf`; a single idempotent `Include` line is
  added to `~/.ssh/config` (backed up first, existing blocks untouched)
- Optional one-off **Import from ~/.ssh/config** to pull in existing hosts
- Connect via the `ssh://` scheme — `ssh://<alias>` when the managed file is
  linked, else `ssh://user@host:port`; opened by your chosen ssh:// handler
  (Terminal, iTerm2, Warp, Zetty, or system default). The picker is derived from
  the installed apps that register the `ssh://` scheme, so it stays current
- Connection profiles: one host, multiple user+identity profiles (real ssh
  aliases); pick one from the Connect menu, menu bar, or ⌘K
- Workspaces to organize hosts into collapsible groups
- ⌘K command palette; searchable menu-bar panel; raw viewer of the managed file
- Light/Dark/System appearance and a tabbed Settings window
- Menu-bar-first app: the Dock icon appears only while a window is open

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘K | Command palette |
| ⌘N | New host |
| ⌘⇧N | New workspace |
| ⌘E | Edit selected host |
| ⌘↩ | Connect selected host |
| ⌘⇧C | Copy ssh command |
| ⌘D | Duplicate selected host |
| ⌘F | Focus search |
| ⌘, | Settings |
| ⌫ | Delete selection |

## Installation

### Download (recommended)

1. Open the [Releases](https://github.com/webteractive/sesh/releases) page and
   download the latest `Sesh-<version>.dmg`.
2. Open the DMG and drag **Sesh** into **Applications**.
3. Clear the Gatekeeper quarantine flag (see below), then launch Sesh from
   Applications or Spotlight:

   ```sh
   xattr -d com.apple.quarantine /Applications/Sesh.app
   ```

> **Why step 3?** Builds are not yet signed or notarized by Apple, so macOS
> quarantines the downloaded app and shows *"Sesh is damaged and can't be
> opened."* It isn't damaged — that's Gatekeeper's message for any unsigned
> download. The command above clears the flag on that copy; you won't see the
> dialog again until you install an **update**, where the freshly downloaded DMG
> repeats step 3. Developer ID signing + notarization is planned, which removes
> this step entirely.

Sesh lives in the menu bar (look for the terminal glyph). Click it to search and
connect; open the main window from there to manage hosts.

### Verify the download (optional)

Each release ships a `Sesh-<version>.dmg.sha256` sidecar:

```sh
shasum -a 256 Sesh-<version>.dmg   # compare against the .sha256 file
```

## Build from source

Requirements: macOS 15.0+, Xcode 16+, and [Tuist](https://tuist.dev).

```bash
tuist generate --no-open
tuist build Sesh
```

### Test

```bash
swift test
```

### Package a release

`scripts/package.sh` builds Release and produces `dist/Sesh-<version>.dmg` plus a
`.sha256` sidecar (version is read from the built app's Info.plist):

```bash
scripts/package.sh
```

Then attach both files to a GitHub release, e.g.:

```bash
gh release create v<version> dist/Sesh-<version>.dmg dist/Sesh-<version>.dmg.sha256 \
  --title "Sesh <version>" --generate-notes
```

## Layout

Core logic (parser, writer, exporter, include manager, importer, backups) lives
in the `SSHConfigCore` package under `Sources/`; the SwiftUI app is under `App/`.

## License

Sesh is open source under the [MIT License](LICENSE).
