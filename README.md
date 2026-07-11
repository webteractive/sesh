# Sesh

Native macOS menu-bar app for managing SSH connections. **The app is the source
of truth**: you manage hosts in Sesh, and it exports them to an app-owned
`~/.ssh/sesh.conf` that's linked into your `~/.ssh/config` via a single
`Include` line. Your existing config is never rewritten. Originally a Swift port
of [webteractive/sshconfig](https://github.com/webteractive/sshconfig)
(Laravel + Filament); rebuilt with SwiftUI, SwiftData, and Tuist.

## Features

- App-primary host management (create, edit, duplicate, delete) — the store is
  authoritative, not the file
- Automatic export to `~/.ssh/sesh.conf`; a single idempotent `Include` line is
  added to `~/.ssh/config` (backed up first, existing blocks untouched)
- Optional one-off **Import from ~/.ssh/config** to pull in existing hosts
- Connect via the `ssh://` scheme — `ssh://<alias>` when the managed file is
  linked, else `ssh://user@host:port`; opened by your chosen ssh:// handler
  (Terminal, iTerm2, Warp, or system default)
- Connection profiles: one host, multiple user+identity profiles (real ssh
  aliases); pick one from the Connect menu, menu bar, or ⌘K
- Extra properties editor for any ssh_config option (ProxyJump, ForwardAgent, …)
- ⌘K command palette; searchable menu-bar panel; raw viewer of the managed file
- Menu-bar-only app: no Dock icon; the window opens on demand and closes fully

## Requirements

- macOS 15.0+
- Xcode 16+ and [Tuist](https://tuist.dev) to build

## Build

```bash
tuist generate --no-open
tuist build Sesh
```

## Test

```bash
swift test
```

Core logic (parser, writer, exporter, include manager, importer, backups) lives
in the `SSHConfigCore` package under `Sources/`; the SwiftUI app is under `App/`.
