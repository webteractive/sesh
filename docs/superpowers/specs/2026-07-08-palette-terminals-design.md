# SSH Config — Command Palette & Terminal-Aware Connect

**Date:** 2026-07-08
**Status:** Approved design
**Base:** builds on `2026-07-08-sshconfig-swift-design.md` (v1 shipped; this is the first feature addition)

## Goal

1. A **⌘K command palette** in the main window: fuzzy search over hosts and app
   actions, keyboard-first.
2. **Terminal-aware Connect**: detect installed terminals (Zetty, Ghostty,
   Terminal.app, iTerm2, Warp, Alacritty, kitty, WezTerm) and connect through a
   user-preferred one instead of only the system `ssh://` handler.
3. **Searchable menu bar panel**: the menu bar host list grows unusably long
   with many hosts — replace the plain menu with a window-style panel that has
   search and a scrollable, height-capped list.

User-confirmed decisions: Connect uses a **Settings default + per-connect
"Connect with …" menu**; the palette covers **hosts + actions**. A CLI surface
was considered and deliberately deferred (the config file itself is the
scripting API; Sync From File absorbs external edits).

## Architecture

Same layering as v1: pure logic in `SSHConfigCore` (unit-tested), system/UI in
the app target.

### Core (new files)

**`TerminalRegistry.swift`** — pure data + plan construction, no AppKit:

```swift
public struct Terminal: Equatable, Identifiable, Sendable {
    public let id: String            // bundle id, or "system-default"
    public let name: String          // display name
    public let launchPlan: LaunchPlan
}

public enum LaunchPlan: Equatable, Sendable {
    case systemDefault               // NSWorkspace.open(ssh://host)
    case sshURL                      // open ssh://host WITH this app (registers the scheme)
    case openArgs([String])          // `open -na <app> --args <args>`; "%@" placeholder = ssh command tokens
    case zettyCLI                    // zetty new-tab → send "ssh host" --enter
}

public enum TerminalRegistry {
    public static let known: [Terminal]  // ordered: System Default, Terminal, iTerm2, Warp, Ghostty, Alacritty, kitty, WezTerm, Zetty
    /// Expand a plan into concrete argv for a host (pure, testable).
    public static func arguments(for plan: LaunchPlan, host: String) -> [String]?
}
```

Known terminals and plans:

| Terminal | Bundle id | Plan |
|---|---|---|
| System Default | `system-default` | `.systemDefault` |
| Terminal | `com.apple.Terminal` | `.sshURL` |
| iTerm2 | `com.googlecode.iterm2` | `.sshURL` |
| Warp | `dev.warp.Warp-Stable` | `.sshURL` |
| Ghostty | `com.mitchellh.ghostty` | `.openArgs(["-e", "ssh", "%h"])` |
| Alacritty | `org.alacritty` | `.openArgs(["-e", "ssh", "%h"])` |
| kitty | `net.kovidgoyal.kitty` | `.openArgs(["ssh", "%h"])` |
| WezTerm | `com.github.wez.wezterm` | `.openArgs(["start", "--", "ssh", "%h"])` |
| Zetty | `dev.more.zetty` | `.zettyCLI` |

`%h` is substituted with the host alias. Host aliases already match
`HostFormData.hostPatternRegex` (no spaces in a single alias; Connect is gated
on `isConnectable`), so no shell-quoting hazard — args are passed as discrete
argv entries, never through a shell string.

**`FuzzyMatcher.swift`** — pure scoring for the palette:

```swift
public enum FuzzyMatcher {
    /// nil = no match; higher = better. Case-insensitive subsequence match,
    /// bonuses for prefix, word-boundary, and consecutive hits.
    public static func score(_ query: String, in candidate: String) -> Int?
}
```

Empty query matches everything (score 0) so the palette shows the full list.

### App (new/changed files)

**`TerminalLauncher.swift` (new)** — executes plans:

- `detectInstalled() -> [Terminal]`: filters `TerminalRegistry.known` via
  `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`; System Default
  always included; Zetty additionally requires the `zetty` CLI on disk (checks
  `/opt/homebrew/bin/zetty`, `/usr/local/bin/zetty`, `~/.local/bin/zetty`).
- `launch(_ terminal: Terminal, host: String) throws`:
  - `.systemDefault` → `NSWorkspace.shared.open(ssh://)`
  - `.sshURL` → `NSWorkspace.shared.open([url], withApplicationAt: appURL, …)`
  - `.openArgs` → `NSWorkspace.openApplication(at:configuration:)` with
    `createsNewApplicationInstance = true` and `arguments` from the registry
  - `.zettyCLI` → `Process` runs `zetty new-tab` (captures pane id), sleeps
    1.5 s off the main thread, then `zetty send --pane <id> "ssh <host>" --enter`
  - Failures surface via the standard `pendingError` alert path.

**Preference** — `preferredTerminalId` in `UserDefaults` (default
`system-default`). If the stored terminal is no longer installed, fall back to
system default silently. Exposed on `AppModel` alongside a cached
`installedTerminals` (refreshed on launch and when Settings opens).

**`AppModel.connect(_:)`** — changes to `connect(_ host: String, with terminal: Terminal? = nil)`;
nil = preferred. Menu bar and palette use the preference.

**`SettingsSheet`** — gains a "Connect with" `Picker` listing
`installedTerminals`.

**`HostDetailView` Connect button** — becomes a split control: primary click
connects with the preferred terminal (label shows its name, e.g. "Connect ·
Ghostty"); attached `Menu` lists all detected terminals for one-off
"Connect with …".

**`CommandPalette.swift` (new)** — SwiftUI overlay in `MainWindow` (ZStack):

- ⌘K toggles (registered as a keyboard shortcut on a hidden/toolbar button);
  Esc or click-outside closes; opening clears the query and focuses the field.
- Content: one flat ranked list mixing **host items** (title = alias, subtitle
  = user@hostname; only `isConnectable` hosts get Connect as default action —
  non-connectable hosts still appear with "Reveal in list" as their action)
  and **action items**: New Host, Sync From File, Sync To File, Sync Both,
  Raw Config, Settings.
- Ranking: `FuzzyMatcher.score` against alias + hostname (hosts) / title
  (actions); hosts rank above actions on equal score; max ~12 rows shown.
- Keys: ↑/↓ move selection, Enter = primary action (host → connect via
  preferred terminal; action → run), ⌘Enter on a host = copy ssh command
  (brief "Copied" confirmation), Esc closes.
- Selecting a host item also selects it in the sidebar.

**`MenuBarView` (rework)** — switch the `MenuBarExtra` to
`.menuBarExtraStyle(.window)` (a plain menu cannot host a text field). The
panel (fixed width ~300 pt):

- Search field at the top (auto-focused on open), filtering/ranking hosts via
  `FuzzyMatcher` against alias + hostname — same matcher as the palette.
- Scrollable host list below, height-capped to ~10 rows (scrolling replaces
  pagination; no page controls). Each row: alias + `user@hostname` subtitle;
  primary click connects via the preferred terminal (rows for non-connectable
  hosts open the main window instead); a trailing copy button copies the ssh
  command. Empty states: "No hosts yet" / "No matches".
- Footer (divider): Sync Both (opens/activates main window first, as today),
  Open SSH Config, Quit.
- Keyboard: ↑/↓ + Enter work within the panel; Esc closes it.

## Error handling

- Launch failure (app vanished since detection, zetty socket down) →
  `pendingError` alert; nothing else mutated.
- Preferred terminal uninstalled → silent fallback to system default (the
  Settings picker re-syncs next time it opens).
- Palette actions reuse existing `AppModel` paths (`runSync`, sheets), so their
  error behavior is unchanged.

## Testing (swift-testing, Core only)

- `TerminalRegistryTests`: every known terminal has a unique id; `arguments(for:host:)`
  substitutes `%h` correctly for each `.openArgs` plan; `.sshURL`/`.systemDefault`/`.zettyCLI`
  return nil argv (handled by launcher, not argv expansion).
- `FuzzyMatcherTests`: empty query matches all; subsequence hit/miss; prefix
  beats scattered; word-boundary bonus; case-insensitivity; non-matching
  returns nil; ranking stability examples (e.g. query "web" ranks "web" over
  "my-web-box" over "workbench-eb").
- Launcher, palette, and menu bar panel are app-layer (no UI test target) — manual QA.

## Out of scope

- CLI surface (deferred — revisit if scripted mutations with app guarantees are wanted).
- Custom/user-defined terminal entries; per-host terminal overrides.
- Global (system-wide) palette hotkey — palette is in-window only.
