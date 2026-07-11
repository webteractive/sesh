# Sesh

Native macOS menu-bar app for managing your SSH config file (`~/.ssh/config`).
A Swift port of [webteractive/sshconfig](https://github.com/webteractive/sshconfig)
(Laravel + Filament), rebuilt with SwiftUI, SwiftData, and Tuist.

## Features

- Visual management of SSH hosts (create, edit, duplicate, delete)
- Extra properties editor for any ssh_config option (ProxyJump, ForwardAgent, …)
- Three sync modes: from file, to file, both — with conflict detection/resolution
- Preserves `Match` blocks, `Include` directives, and global settings on write
- Timestamped backups before every file write (keeps the 20 newest)
- Click-to-copy `ssh <host>` command; Connect opens your default terminal via `ssh://`
- Menu bar extra for quick connect/copy
- Raw config viewer
- ⌘K command palette: fuzzy search across hosts and app actions
- Terminal-aware Connect: detects Terminal, iTerm2, Warp, Ghostty, Alacritty,
  kitty, WezTerm, and Zetty; pick a default in Settings or one-off via
  "Connect with …"
- Searchable menu bar panel (window style) that stays usable with many hosts
- Menu-bar-only app: no Dock icon; the window opens on demand and closes fully
- Connection profiles: give one host multiple user+identity profiles (real ssh
  aliases) and pick which to connect with, from the Connect menu, menu bar, or ⌘K

## Requirements

- macOS 14.0+
- Xcode 16+ and [Tuist](https://tuist.dev) to build

## Build

```bash
tuist generate --no-open
tuist build SSHConfig
```

## Test

```bash
swift test
```

Core logic (parser, writer, sync, conflicts, backups) lives in the
`SSHConfigCore` package under `Sources/`; the SwiftUI app is under `App/`.
