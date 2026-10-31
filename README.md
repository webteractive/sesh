# Sesh

Native macOS menu-bar app for managing SSH connections and `/etc/hosts`
entries. **The app is the source of truth**: you manage hosts in Sesh, and it exports them to an app-owned
`~/.ssh/sesh.conf` that's linked into your `~/.ssh/config` via a single
`Include` line. Your existing config is never rewritten.

## Features

- App-primary host management (create, edit, duplicate, delete) — the store is
  authoritative, not the file
- Automatic export to `~/.ssh/sesh.conf`; a single idempotent `Include` line is
  added to `~/.ssh/config` (backed up first, existing blocks untouched). Both
  paths can be changed but stay inside `~/.ssh`, and Sesh never overwrites a
  file it didn't write
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
  (the prompt lists the lines being added and removed; macOS remembers the
  password for a few minutes), and flushes the DNS cache. Enabling
  an entry turns off any other Sesh entry for the same hostname. If the file
  changes behind Sesh's back, a **Re-apply** banner appears; Sesh never
  rewrites the file on its own. The toolbar's Raw Config button (or the menu
  bar's Hosts tab) shows the whole `/etc/hosts` in a sheet, with Sesh's section
  highlighted
- **Add from Text** (the **+** menu in the Hosts File view or the menu bar's
  Hosts tab) pastes several `/etc/hosts` lines at once,
  `IP hostname…[ # note]` per line. Each parsed entry is listed with an
  **Enabled** switch (commented-out lines start switched off). They're written
  in one go behind a single password prompt; a line Sesh already has isn't
  duplicated, and a pasted line takes over its hostnames from any clashing
  Sesh entry
- **Export** and **Import**, separately for SSH hosts and for hosts-file
  entries: the Export and Import buttons in the window toolbar and the menu
  bar cover the side you're on (SSH or Hosts File), and ⌘K offers each.
  Exporting SSH hosts writes the ones you tick to a JSON file — settings,
  profiles, workspaces, and identity file *paths*, never keys. They're listed
  by workspace, as in the sidebar, and each workspace can be ticked as a
  whole; hosts that are only in `~/.ssh/config` get their own group, unticked.
  Import lists a file's items the same way: anything Sesh already has is shown
  but skipped, and risky SSH hosts start unticked with a warning: ones that
  set any option beyond where to connect, as whom and how patiently (`User`,
  `Port`, `IdentityFile`, `ServerAliveInterval`, …), since others run
  commands (`ProxyCommand`, `RemoteCommand`), open ports or send your
  environment (`RemoteForward`, `SendEnv`), or loosen host key checks
  (`StrictHostKeyChecking`, `HostKeyAlias`); ones that
  would replace a host in your `~/.ssh/config`, or are named like a real
  server (`github.com`) with `HostName` pointing elsewhere. A host whose alias
  is a pattern, like `Host *`, isn't imported at all. Hosts-file entries
  import behind one password prompt, merged the same way as Add from Text.
- Optional one-off **Import from /etc/hosts** that moves your existing entries
  (including commented-out ones, as disabled) into Sesh's section, after a
  backup to `~/Library/Application Support/Sesh/hosts-backups`. System entries
  and Docker Desktop's and SwitchHosts' sections are left alone
- A **`sesh` command line** that does everything the app does, for you in
  Terminal or for an AI agent: hosts, profiles, workspaces, `/etc/hosts`
  entries, export and import, linking, settings, and connecting. See
  [Command line](#command-line)
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

## Command line

Sesh.app carries a `sesh` command. Put it on your PATH from **Settings →
General → Install sesh Command** (it links `/usr/local/bin/sesh` to the copy
inside the app, so it updates with Sesh), or from Terminal:

```sh
sudo /Applications/Sesh.app/Contents/Helpers/sesh settings install-command
# or, with no sudo, into a folder you own that's on your PATH:
/Applications/Sesh.app/Contents/Helpers/sesh settings install-command --dir ~/.local/bin
```

`sesh` asks the Sesh app to do the work, starting it in the background if it
isn't running, so every change goes through the same code as the window and
shows up there straight away. It talks to the app over a socket in
`~/Library/Application Support/Sesh` that only your user can open.

```sh
sesh status                                   # what Sesh manages, at a glance
sesh hosts list
sesh hosts add "My Server" --hostname 203.0.113.7 --user root --workspace Work
sesh profiles add "My Server" --label deploy --user deploy --identity-file ~/.ssh/deploy
sesh hosts edit my-server --port 2222 --option ServerAliveInterval=60
sesh connect my-server                        # opens your terminal app
sesh hosts-file add 127.0.0.1 api.test --note "local API"
printf '10.0.0.5 web.test\n10.0.0.6 db.test\n' | sesh hosts-file add-text
sesh hosts-file disable api.test
sesh export ~/Desktop/sesh.json
sesh import ~/Desktop/sesh.json --dry-run
```

Run `sesh --help`, or `sesh <command> --help`, for everything else:
workspaces, duplicating and moving hosts, `/etc/hosts` import and status,
`~/.ssh/config` import and linking, terminals, appearance, and updates.
Changes to `/etc/hosts` ask for your administrator password in a macOS dialog
that lists the lines being changed, as they do in the app; switching several
entries on or off at once asks once. Deleting asks first; pass `--yes` when
there's no one to ask.

**For scripts and AI agents**, add `--json` to any command. Results print as
JSON on stdout, and so do errors (`{"error": {"code": …, "message": …}}`).
Warnings go to stderr as `warning: …` — for example, a change that was saved
but couldn't be written to `~/.ssh/sesh.conf` — and leave the exit code at 0.
Exit codes tell outcomes apart without parsing text:

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | failed |
| 2 | invalid input; nothing was changed |
| 3 | not found |
| 4 | ambiguous: the name matches more than one thing |
| 5 | conflict: already exists |
| 6 | cancelled: a password prompt or confirmation was declined |
| 7 | Sesh isn't running and couldn't be started |
| 8 | `sesh` and the running Sesh are different versions |
| 9 | confirmation required: pass `--yes` |
| 64 | usage error |

`sesh --version` (or `-v`, or `sesh version`) prints the version of the Sesh
it came in.

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
