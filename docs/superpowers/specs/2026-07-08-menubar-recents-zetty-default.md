# SSH Config — Menu Bar Recents & Zetty-Default Terminal (v0.2.1)

**Date:** 2026-07-08
**Status:** Approved
**Base:** builds on `2026-07-08-palette-terminals-design.md` (v0.2.0 shipped)

## Changes

1. **Menu bar panel — latest 10 + search-all.** Sort hosts by `updatedAt`
   descending. Empty query shows the 10 most-recent hosts. A non-empty query
   fuzzy-searches across ALL hosts (via `FuzzyMatcher`, existing behavior).
   Keyboard nav, copy buttons, and footer unchanged.

2. **Terminal options exclude System Default.** The Settings "Connect with"
   picker and the Connect button's "Connect with …" menu list only detected
   real terminals (`selectableTerminals` = installed minus `system-default`).
   When none are detected, Settings shows a note ("No supported terminal
   detected — Connect uses the system default.").

3. **Default terminal = Zetty if installed.** `preferredTerminal` resolves as:
   the explicitly-stored id if that terminal is still installed and is not
   `system-default` → else Zetty (`dev.more.zetty`) if installed → else the
   first `selectableTerminals` entry → else `system-default` (invisible
   last-resort). This auto-migrates a pre-existing stored `system-default`
   preference to Zetty/first-detected, and guarantees Connect never dead-ends.

4. **Sidebar search** — no change; the existing `.searchable` toolbar field
   already satisfies it (user chose to keep it).

## Files

- `App/Sources/AppModel.swift` — add `selectableTerminals`; rework
  `preferredTerminal` resolution (Zetty-preferred, system-default hidden
  fallback). `connect` unchanged (still falls back through `preferredTerminal`).
- `App/Sources/Views/SettingsSheet.swift` — picker iterates
  `selectableTerminals`; empty-state note; drop the old reset-to-system-default
  `onAppear` guard (resolution handles staleness).
- `App/Sources/Views/HostDetailView.swift` — Connect menu iterates
  `selectableTerminals`.
- `App/Sources/Views/MenuBarView.swift` — sort `updatedAt` desc; empty query →
  `prefix(10)`; query → fuzzy over all.
- `Project.swift` — version 0.2.0 → 0.2.1.

## Safety / testing

- The `HostValidation.isSafeToLaunch` guard in `TerminalLauncher.launch` is
  untouched — the injection fix remains in force on every path.
- Core suite (65 tests) must stay green; changes are app-layer (manual QA for
  the picker/menu-bar behavior), build-verified.

## Out of scope

- Making sidebar search an inline field (user kept the toolbar field).
- Custom/user-added terminals; per-host terminal overrides.
