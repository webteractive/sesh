# Sesh

Native macOS menu-bar app for managing SSH connections and `/etc/hosts`
entries. **The app is the source of truth**: you manage hosts in Sesh, and it exports them to an app-owned
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
- `/etc/hosts` management: add, edit, and enable/disable entries from the
  window's **Hosts File** view or the menu bar's **Hosts** tab. Sesh owns one
  marked section at the end of `/etc/hosts` (disabled entries are written as
  commented-out lines), asks for your administrator password when it writes
  (macOS remembers it for a few minutes), and flushes the DNS cache. Enabling
  an entry turns off any other Sesh entry for the same hostname. If the file
  changes behind Sesh's back, a **Re-apply** banner appears; Sesh never
  rewrites the file on its own. The toolbar's Raw Config button (or the menu
  bar's Hosts tab) shows the whole `/etc/hosts` in a sheet, with Sesh's section
  highlighted
- Optional one-off **Import from /etc/hosts** that moves your existing entries
  (including commented-out ones, as disabled) into Sesh's section, after a
  backup to `~/Library/Application Support/Sesh/hosts-backups`. System entries
  and Docker Desktop's and SwitchHosts' sections are left alone
- ⌘K command palette; searchable menu-bar panel; raw viewer of the managed file
- Light/Dark/System appearance and a tabbed Settings window
- Menu-bar-first app: the Dock icon appears only while a window is open

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘K | Command palette |
| ⌘N | New host (or hosts entry in Hosts File view) |
| ⌘⇧N | New workspace |
| ⌘E | Edit selected host or hosts entry |
| ⌘↩ | Connect selected host |
| ⌘⇧C | Copy ssh command |
| ⌘D | Duplicate selected host or hosts entry |
| ⌘F | Focus search |
| ⌘, | Settings |
| ⌫ | Delete selection |

## Installation

### Download (recommended)

1. Open the [Releases](https://github.com/webteractive/sesh/releases) page and
   download the latest `Sesh-<version>.dmg`.
2. Open the DMG and drag **Sesh** into **Applications**.
3. Launch Sesh from Applications or Spotlight.

Sesh lives in the menu bar (look for the key glyph). Click it to search and
connect; open the main window from there to manage hosts.

### Verify the download (optional)

Each release ships a `Sesh-<version>.dmg.sha256` sidecar:

```sh
shasum -a 256 Sesh-<version>.dmg   # compare against the .sha256 file
```

## Requirements

macOS 15.0 or later.

## License

Sesh is open source under the [MIT License](LICENSE).
