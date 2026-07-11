# Command Palette, Terminal-Aware Connect & Searchable Menu Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a ⌘K command palette, terminal detection (Zetty/Ghostty/Terminal/iTerm2/Warp/Alacritty/kitty/WezTerm) with a preferred-terminal Connect flow, and a searchable window-style menu bar panel to the SSH Config app.

**Architecture:** Pure logic (terminal registry with launch plans, fuzzy matcher) goes into `SSHConfigCore` with swift-testing coverage; system execution (`TerminalLauncher`) and all UI (palette overlay, split Connect button, Settings picker, menu bar panel) go into the app target. No AppleScript — `.sshURL` terminals open `ssh://` with a specific app, others get argv via `NSWorkspace.openApplication`, Zetty goes through its CLI.

**Tech Stack:** Swift (language mode v5), SwiftUI (macOS 14 APIs: `onKeyPress`, `menuBarExtraStyle(.window)`, `Menu(primaryAction:)`), SwiftData (existing), swift-testing.

**Spec:** `docs/superpowers/specs/2026-07-08-palette-terminals-design.md` — read it first.

## Global Constraints

- Repo `/Users/glenbangkila/AI/sshconfig-swift`, main branch. Tests: `swift test` (currently 55 green). App build: `tuist generate --no-open && tuist build SSHConfig`.
- Core files under `Sources/SSHConfigCore/` must not import SwiftUI/AppKit.
- Terminal table (id → plan) verbatim from spec: `system-default`→systemDefault; `com.apple.Terminal`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`→sshURL; `com.mitchellh.ghostty`→openArgs(["-e","ssh","%h"]); `org.alacritty`→openArgs(["-e","ssh","%h"]); `net.kovidgoyal.kitty`→openArgs(["ssh","%h"]); `com.github.wez.wezterm`→openArgs(["start","--","ssh","%h"]); `dev.more.zetty`→zettyCLI.
- `%h` = host alias; args pass as discrete argv entries, never a shell string.
- Preference key: `preferredTerminalId` in UserDefaults, default `system-default`; missing/uninstalled stored id silently falls back to system default.
- Git commits: NO `Co-Authored-By`, NO `Claude-Session:` lines, never push. Commits approved.

---

### Task 1: Core — `TerminalRegistry` + `FuzzyMatcher`

**Files:**
- Create: `Sources/SSHConfigCore/TerminalRegistry.swift`
- Create: `Sources/SSHConfigCore/FuzzyMatcher.swift`
- Test: `Tests/SSHConfigCoreTests/TerminalRegistryTests.swift`
- Test: `Tests/SSHConfigCoreTests/FuzzyMatcherTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct Terminal: Equatable, Identifiable, Sendable { let id: String; let name: String; let launchPlan: LaunchPlan }`; `enum LaunchPlan: Equatable, Sendable { case systemDefault, sshURL, openArgs([String]), zettyCLI }`; `enum TerminalRegistry { static let systemDefaultId: String; static let known: [Terminal]; static func terminal(withId:) -> Terminal?; static func arguments(for plan: LaunchPlan, host: String) -> [String]? }`; `enum FuzzyMatcher { static func score(_ query: String, in candidate: String) -> Int? }`.

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/TerminalRegistryTests.swift`**

```swift
import Testing
@testable import SSHConfigCore

@Test func knownTerminalsHaveUniqueIdsAndSystemDefaultFirst() {
    let ids = TerminalRegistry.known.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.first == TerminalRegistry.systemDefaultId)
    #expect(ids.contains("dev.more.zetty"))
    #expect(ids.contains("com.mitchellh.ghostty"))
}

@Test func argumentsSubstituteHostForOpenArgsPlans() {
    let ghostty = TerminalRegistry.terminal(withId: "com.mitchellh.ghostty")!
    #expect(TerminalRegistry.arguments(for: ghostty.launchPlan, host: "web") == ["-e", "ssh", "web"])
    let kitty = TerminalRegistry.terminal(withId: "net.kovidgoyal.kitty")!
    #expect(TerminalRegistry.arguments(for: kitty.launchPlan, host: "db") == ["ssh", "db"])
    let wez = TerminalRegistry.terminal(withId: "com.github.wez.wezterm")!
    #expect(TerminalRegistry.arguments(for: wez.launchPlan, host: "x") == ["start", "--", "ssh", "x"])
}

@Test func argumentsNilForNonArgvPlans() {
    #expect(TerminalRegistry.arguments(for: .systemDefault, host: "web") == nil)
    #expect(TerminalRegistry.arguments(for: .sshURL, host: "web") == nil)
    #expect(TerminalRegistry.arguments(for: .zettyCLI, host: "web") == nil)
}

@Test func lookupByIdAndMiss() {
    #expect(TerminalRegistry.terminal(withId: "com.apple.Terminal")?.name == "Terminal")
    #expect(TerminalRegistry.terminal(withId: "nope") == nil)
}
```

- [ ] **Step 2: Write failing tests — `Tests/SSHConfigCoreTests/FuzzyMatcherTests.swift`**

```swift
import Testing
@testable import SSHConfigCore

@Test func emptyQueryMatchesEverythingAtZero() {
    #expect(FuzzyMatcher.score("", in: "anything") == 0)
}

@Test func subsequenceHitAndMiss() {
    #expect(FuzzyMatcher.score("wb", in: "web-box") != nil)
    #expect(FuzzyMatcher.score("xyz", in: "web-box") == nil)
}

@Test func caseInsensitive() {
    #expect(FuzzyMatcher.score("WEB", in: "web") == FuzzyMatcher.score("web", in: "WEB"))
    #expect(FuzzyMatcher.score("WEB", in: "web") != nil)
}

@Test func rankingPrefersExactThenBoundaryThenScattered() {
    let exact = FuzzyMatcher.score("web", in: "web")!
    let boundary = FuzzyMatcher.score("web", in: "my-web-box")!
    let scattered = FuzzyMatcher.score("web", in: "workbench-eb")!
    #expect(exact > boundary)
    #expect(boundary > scattered)
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter TerminalRegistryTests`
Expected: FAIL — `cannot find 'TerminalRegistry' in scope`.

- [ ] **Step 4: Implement `Sources/SSHConfigCore/TerminalRegistry.swift`**

```swift
/// A terminal emulator the app knows how to open an ssh session in.
public struct Terminal: Equatable, Identifiable, Sendable {
    public let id: String        // bundle id, or TerminalRegistry.systemDefaultId
    public let name: String
    public let launchPlan: LaunchPlan

    public init(id: String, name: String, launchPlan: LaunchPlan) {
        self.id = id
        self.name = name
        self.launchPlan = launchPlan
    }
}

public enum LaunchPlan: Equatable, Sendable {
    case systemDefault           // NSWorkspace.open(ssh://host) — whatever handles the scheme
    case sshURL                  // open ssh://host WITH this specific app
    case openArgs([String])     // launch the app with argv; "%h" is replaced by the host alias
    case zettyCLI                // zetty new-tab → send "ssh host" --enter
}

public enum TerminalRegistry {
    public static let systemDefaultId = "system-default"

    public static let known: [Terminal] = [
        Terminal(id: systemDefaultId, name: "System Default", launchPlan: .systemDefault),
        Terminal(id: "com.apple.Terminal", name: "Terminal", launchPlan: .sshURL),
        Terminal(id: "com.googlecode.iterm2", name: "iTerm2", launchPlan: .sshURL),
        Terminal(id: "dev.warp.Warp-Stable", name: "Warp", launchPlan: .sshURL),
        Terminal(id: "com.mitchellh.ghostty", name: "Ghostty", launchPlan: .openArgs(["-e", "ssh", "%h"])),
        Terminal(id: "org.alacritty", name: "Alacritty", launchPlan: .openArgs(["-e", "ssh", "%h"])),
        Terminal(id: "net.kovidgoyal.kitty", name: "kitty", launchPlan: .openArgs(["ssh", "%h"])),
        Terminal(id: "com.github.wez.wezterm", name: "WezTerm", launchPlan: .openArgs(["start", "--", "ssh", "%h"])),
        Terminal(id: "dev.more.zetty", name: "Zetty", launchPlan: .zettyCLI),
    ]

    public static func terminal(withId id: String) -> Terminal? {
        known.first { $0.id == id }
    }

    /// Concrete argv for a host — only .openArgs plans expand; others are
    /// handled wholesale by the launcher.
    public static func arguments(for plan: LaunchPlan, host: String) -> [String]? {
        guard case .openArgs(let template) = plan else { return nil }
        return template.map { $0 == "%h" ? host : $0 }
    }
}
```

- [ ] **Step 5: Implement `Sources/SSHConfigCore/FuzzyMatcher.swift`**

```swift
/// Case-insensitive subsequence scorer for the palette and menu bar search.
public enum FuzzyMatcher {
    /// nil = no match. Higher = better: +8 first-char prefix, +4 word
    /// boundary, +6 consecutive run, +1 per hit, small length penalty so
    /// tighter candidates win ties.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        if q.isEmpty { return 0 }

        var total = 0
        var searchFrom = 0
        var previousHit: Int? = nil

        for ch in q {
            var found: Int? = nil
            var i = searchFrom
            while i < c.count {
                if c[i] == ch { found = i; break }
                i += 1
            }
            guard let hit = found else { return nil }

            var gain = 1
            if hit == 0 {
                gain += 8
            } else {
                let before = c[hit - 1]
                if !before.isLetter && !before.isNumber { gain += 4 }
            }
            if let prev = previousHit, hit == prev + 1 { gain += 6 }

            total += gain
            previousHit = hit
            searchFrom = hit + 1
        }
        total -= max(0, c.count - q.count) / 4
        return total
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test`
Expected: PASS — 55 existing + 8 new = 63 tests green.

- [ ] **Step 7: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): terminal registry with launch plans and fuzzy matcher"
```

---

### Task 2: App — `TerminalLauncher`, preference, Settings picker, split Connect button

**Files:**
- Create: `App/Sources/TerminalLauncher.swift`
- Modify: `App/Sources/AppModel.swift` (connect/preference/installed list)
- Modify: `App/Sources/Views/SettingsSheet.swift` (picker)
- Modify: `App/Sources/Views/HostDetailView.swift` (split Connect button)

**Interfaces:**
- Consumes: `Terminal`, `LaunchPlan`, `TerminalRegistry` (Task 1).
- Produces (Tasks 3–4 rely on these): `AppModel.installedTerminals: [Terminal]`, `AppModel.preferredTerminal: Terminal`, `AppModel.preferredTerminalId: String { get set }`, `AppModel.refreshTerminals()`, `AppModel.connect(_ host: String, with terminal: Terminal? = nil)` (nil = preferred; errors → `pendingError`).

- [ ] **Step 1: Create `App/Sources/TerminalLauncher.swift`**

```swift
import AppKit
import Foundation
import SSHConfigCore

/// Executes LaunchPlans. Detection and launching live here (AppKit); the
/// registry data itself is in Core.
@MainActor
struct TerminalLauncher {
    enum LaunchError: LocalizedError {
        case badHost(String)
        case notInstalled(String)

        var errorDescription: String? {
            switch self {
            case .badHost(let host): "Cannot build an ssh URL for '\(host)'."
            case .notInstalled(let name): "\(name) is not installed (or its CLI is missing)."
            }
        }
    }

    static let zettyCLICandidates = [
        "/opt/homebrew/bin/zetty",
        "/usr/local/bin/zetty",
        NSHomeDirectory() + "/.local/bin/zetty",
    ]

    func detectInstalled() -> [Terminal] {
        TerminalRegistry.known.filter { terminal in
            switch terminal.launchPlan {
            case .systemDefault:
                true
            case .zettyCLI:
                appURL(for: terminal.id) != nil && zettyCLIPath() != nil
            case .sshURL, .openArgs:
                appURL(for: terminal.id) != nil
            }
        }
    }

    func launch(_ terminal: Terminal, host: String) throws {
        guard let url = URL(string: "ssh://\(host)") else {
            throw LaunchError.badHost(host)
        }
        switch terminal.launchPlan {
        case .systemDefault:
            NSWorkspace.shared.open(url)
        case .sshURL:
            guard let app = appURL(for: terminal.id) else {
                throw LaunchError.notInstalled(terminal.name)
            }
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        case .openArgs:
            guard let app = appURL(for: terminal.id),
                  let args = TerminalRegistry.arguments(for: terminal.launchPlan, host: host) else {
                throw LaunchError.notInstalled(terminal.name)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = args
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        case .zettyCLI:
            guard let cli = zettyCLIPath() else {
                throw LaunchError.notInstalled("Zetty CLI")
            }
            // zetty needs the pane's shell to be up before input is sent
            // (per zetty's own guidance: ~1–2 s), so this runs detached.
            Task.detached {
                guard let pane = try? Self.run(cli, ["new-tab"])
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !pane.isEmpty else { return }
                try? await Task.sleep(for: .seconds(1.5))
                _ = try? Self.run(cli, ["send", "--pane", pane, "ssh \(host)", "--enter"])
            }
        }
    }

    private func appURL(for bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    func zettyCLIPath() -> String? {
        Self.zettyCLICandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 2: Extend `App/Sources/AppModel.swift`**

Add stored/computed members near the other service properties (`pathStore`, `engine`, …) and replace the existing `connect(_ host: String)` method. Current `connect` is:

```swift
    func connect(_ host: String) {
        guard let url = URL(string: "ssh://\(host)") else { return }
        NSWorkspace.shared.open(url)
    }
```

Replace with (and add the new members):

```swift
    private let terminalLauncher = TerminalLauncher()
    var installedTerminals: [Terminal] = []

    static let preferredTerminalKey = "preferredTerminalId"

    var preferredTerminalId: String {
        get {
            UserDefaults.standard.string(forKey: Self.preferredTerminalKey)
                ?? TerminalRegistry.systemDefaultId
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.preferredTerminalKey) }
    }

    /// The stored preference if it's still installed, else system default.
    var preferredTerminal: Terminal {
        installedTerminals.first { $0.id == preferredTerminalId }
            ?? TerminalRegistry.known[0]
    }

    func refreshTerminals() {
        installedTerminals = terminalLauncher.detectInstalled()
    }

    /// Connect via a specific terminal, or the preferred one when nil.
    func connect(_ host: String, with terminal: Terminal? = nil) {
        do {
            try terminalLauncher.launch(terminal ?? preferredTerminal, host: host)
        } catch {
            pendingError = error.localizedDescription
        }
    }
```

Also call `refreshTerminals()` at the top of `onLaunch()`.

- [ ] **Step 3: Add the picker to `App/Sources/Views/SettingsSheet.swift`**

Inside the sheet's form/VStack (below the config-path field, above the error text), add — adapting to the file's actual layout, and call `model.refreshTerminals()` in the view's `.onAppear` (add one if absent):

```swift
            Picker("Connect with", selection: Binding(
                get: { model.preferredTerminalId },
                set: { model.preferredTerminalId = $0 }
            )) {
                ForEach(model.installedTerminals) { terminal in
                    Text(terminal.name).tag(terminal.id)
                }
            }
            .pickerStyle(.menu)
```

If the stored id isn't among `installedTerminals`, the picker must not crash: guard by adding this `.onAppear` line after `refreshTerminals()`:

```swift
                if !model.installedTerminals.contains(where: { $0.id == model.preferredTerminalId }) {
                    model.preferredTerminalId = TerminalRegistry.systemDefaultId
                }
```

(`import SSHConfigCore` at the top if not present.)

- [ ] **Step 4: Split Connect button in `App/Sources/Views/HostDetailView.swift`**

Replace the current Connect button block:

```swift
                    if entry.isConnectable {
                        Button {
                            model.connect(entry.host)
                        } label: {
                            Label("Connect", systemImage: "terminal")
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                    }
```

with a primary-action menu (click = preferred terminal, menu = one-offs):

```swift
                    if entry.isConnectable {
                        Menu {
                            ForEach(model.installedTerminals) { terminal in
                                Button("Connect with \(terminal.name)") {
                                    model.connect(entry.host, with: terminal)
                                }
                            }
                        } label: {
                            Label("Connect · \(model.preferredTerminal.name)", systemImage: "terminal")
                        } primaryAction: {
                            model.connect(entry.host)
                        }
                        .fixedSize()
                        .keyboardShortcut(.return, modifiers: .command)
                    }
```

- [ ] **Step 5: Build + test**

Run: `tuist generate --no-open && tuist build SSHConfig && swift test`
Expected: BUILD SUCCEEDED; 63/63 tests pass.

- [ ] **Step 6: Commit**

```bash
git add App
git commit -m "feat(app): terminal detection, preferred terminal, split connect button"
```

---

### Task 3: Command palette (⌘K)

**Files:**
- Create: `App/Sources/Views/CommandPalette.swift`
- Modify: `App/Sources/Views/MainWindow.swift` (overlay + ⌘K + action routing)

**Interfaces:**
- Consumes: `FuzzyMatcher.score` (Task 1), `AppModel.connect/copyCommand/runSync` (Task 2), MainWindow's existing state: `formMode: FormMode?`, `showSettings` (Bool driving SettingsSheet), `selection: Set<PersistentIdentifier>`, `@Environment(\.openWindow)`.
- Produces: `CommandPalette(hosts: [HostEntry], onHost: (HostEntry, PaletteHostAction) -> Void, onAction: (PaletteAction) -> Void, isPresented: Binding<Bool>)`; `enum PaletteAction: CaseIterable { case newHost, syncFromFile, syncToFile, syncBoth, rawConfig, settings }`; `enum PaletteHostAction { case connect, copy, reveal }`.

- [ ] **Step 1: Create `App/Sources/Views/CommandPalette.swift`**

```swift
import SwiftUI
import SwiftData
import SSHConfigCore

enum PaletteAction: CaseIterable, Identifiable {
    case newHost, syncFromFile, syncToFile, syncBoth, rawConfig, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .newHost: "New Host"
        case .syncFromFile: "Sync From File"
        case .syncToFile: "Sync To File"
        case .syncBoth: "Sync Both"
        case .rawConfig: "Raw Config"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .newHost: "plus"
        case .syncFromFile: "arrow.down.doc"
        case .syncToFile: "arrow.up.doc"
        case .syncBoth: "arrow.triangle.2.circlepath"
        case .rawConfig: "doc.plaintext"
        case .settings: "gearshape"
        }
    }
}

enum PaletteHostAction { case connect, copy, reveal }

private enum PaletteItem: Identifiable {
    case host(HostEntry)
    case action(PaletteAction)

    var id: String {
        switch self {
        case .host(let entry): "host-\(entry.host)"
        case .action(let action): "action-\(action.title)"
        }
    }
}

struct CommandPalette: View {
    let hosts: [HostEntry]
    let onHost: (HostEntry, PaletteHostAction) -> Void
    let onAction: (PaletteAction) -> Void
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private static let maxRows = 12

    private var results: [PaletteItem] {
        let ranked: [(PaletteItem, Int, Int)] = // (item, score, kindRank: hosts first)
            hosts.compactMap { entry in
                let target = entry.host + " " + (entry.properties.first("HostName") ?? "")
                guard let s = FuzzyMatcher.score(query, in: target) else { return nil }
                return (.host(entry), s, 0)
            }
            + PaletteAction.allCases.compactMap { action in
                guard let s = FuzzyMatcher.score(query, in: action.title) else { return nil }
                return (.action(action), s, 1)
            }
        return ranked
            .sorted { ($0.1, $1.2) > ($1.1, $0.2) } // score desc, hosts before actions on ties
            .prefix(Self.maxRows)
            .map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                TextField("Search hosts and commands…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(12)
                    .focused($fieldFocused)
                    .onSubmit { execute(at: selectedIndex, commandModifier: false) }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selectedIndex)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { execute(at: index, commandModifier: false) }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selectedIndex) { _, newValue in
                        proxy.scrollTo(newValue)
                    }
                }
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 24)
            .padding(.top, 80)
            .onKeyPress(.downArrow) {
                selectedIndex = min(selectedIndex + 1, max(0, results.count - 1)); return .handled
            }
            .onKeyPress(.upArrow) {
                selectedIndex = max(selectedIndex - 1, 0); return .handled
            }
            .onKeyPress(.escape) {
                isPresented = false; return .handled
            }
            .onKeyPress(.return, phases: .down) { press in
                execute(at: selectedIndex, commandModifier: press.modifiers.contains(.command))
                return .handled
            }
        }
        .onAppear {
            query = ""
            selectedIndex = 0
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    @ViewBuilder
    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .host(let entry):
                Image(systemName: entry.isConnectable ? "server.rack" : "rectangle.stack")
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.host)
                    Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.isConnectable ? "↩ connect · ⌘↩ copy" : "↩ reveal")
                    .font(.caption2).foregroundStyle(.tertiary)
            case .action(let action):
                Image(systemName: action.icon).frame(width: 20)
                Text(action.title)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear)
    }

    private func subtitle(_ entry: HostEntry) -> String {
        let hostName = entry.properties.first("HostName") ?? "—"
        if let user = entry.properties.first("User") { return "\(user)@\(hostName)" }
        return hostName
    }

    private func execute(at index: Int, commandModifier: Bool) {
        guard results.indices.contains(index) else { return }
        switch results[index] {
        case .host(let entry):
            if commandModifier {
                onHost(entry, .copy)
            } else if entry.isConnectable {
                onHost(entry, .connect)
            } else {
                onHost(entry, .reveal)
            }
        case .action(let action):
            onAction(action)
        }
        isPresented = false
    }
}
```

- [ ] **Step 2: Wire into `App/Sources/Views/MainWindow.swift`**

Add state `@State private var showPalette = false`. Wrap the existing `NavigationSplitView` in a ZStack (or use `.overlay`): after all existing modifiers on the split view, add:

```swift
        .overlay {
            if showPalette {
                CommandPalette(
                    hosts: hosts,
                    onHost: { entry, action in
                        switch action {
                        case .connect: model.connect(entry.host)
                        case .copy: model.copyCommand(entry)
                        case .reveal: selection = [entry.persistentModelID]
                        }
                    },
                    onAction: { action in
                        switch action {
                        case .newHost: formMode = .create
                        case .syncFromFile: model.runSync(.fromFile)
                        case .syncToFile: model.runSync(.toFile)
                        case .syncBoth: model.runSync(.both)
                        case .rawConfig: openWindow(id: "raw-config")
                        case .settings: showSettings = true
                        }
                    },
                    isPresented: $showPalette
                )
            }
        }
        .background {
            Button("") { showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
```

Adapt names to the file: `hosts` is the existing `@Query` array; `selection` is the `Set<PersistentIdentifier>` state; `showSettings` is whatever Bool currently presents `SettingsSheet` (use its real name); `openWindow` already exists. If `.reveal` needs the sidebar filter cleared to show the row, also clear `search = ""`.

- [ ] **Step 3: Build + test**

Run: `tuist generate --no-open && tuist build SSHConfig && swift test`
Expected: BUILD SUCCEEDED; 63/63.

- [ ] **Step 4: Commit**

```bash
git add App
git commit -m "feat(app): command palette with fuzzy host and action search"
```

---

### Task 4: Searchable window-style menu bar panel

**Files:**
- Modify: `App/Sources/Views/MenuBarView.swift` (full rework)
- Modify: `App/Sources/SSHConfigApp.swift` (`.menuBarExtraStyle(.window)`)

**Interfaces:**
- Consumes: `FuzzyMatcher` (Task 1), `AppModel.connect/copyCommand/runSync/preferredTerminal` (Task 2).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Rework `App/Sources/Views/MenuBarView.swift`**

Replace the whole file:

```swift
import SwiftUI
import SwiftData
import SSHConfigCore

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \HostEntry.host) private var hosts: [HostEntry]

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [HostEntry] {
        hosts
            .compactMap { entry -> (HostEntry, Int)? in
                let target = entry.host + " " + (entry.properties.first("HostName") ?? "")
                guard let score = FuzzyMatcher.score(query, in: target) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search hosts…", text: $query)
                .textFieldStyle(.plain)
                .padding(10)
                .focused($searchFocused)
            Divider()

            if hosts.isEmpty {
                Text("No hosts yet")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else if filtered.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            hostRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 340) // ~10 rows; scrolling replaces pagination
            }

            Divider()
            footer
        }
        .frame(width: 300)
        .onAppear {
            query = ""
            searchFocused = true
        }
    }

    @ViewBuilder
    private func hostRow(_ entry: HostEntry) -> some View {
        HStack(spacing: 6) {
            Button {
                if entry.isConnectable {
                    model.connect(entry.host)
                } else {
                    openMainWindow()
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.host)
                    Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.isConnectable
                  ? "Connect with \(model.preferredTerminal.name)"
                  : "Open in SSH Config")

            Button {
                model.copyCommand(entry)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy \(entry.sshCommand)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var footer: some View {
        HStack {
            Button("Sync Both") {
                openMainWindow()
                model.runSync(.both)
            }
            Spacer()
            Button("Open SSH Config") { openMainWindow() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(10)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func subtitle(_ entry: HostEntry) -> String {
        let hostName = entry.properties.first("HostName") ?? "—"
        if let user = entry.properties.first("User") { return "\(user)@\(hostName)" }
        return hostName
    }
}
```

- [ ] **Step 2: Switch the scene style in `App/Sources/SSHConfigApp.swift`**

Append `.menuBarExtraStyle(.window)` to the `MenuBarExtra` scene:

```swift
        MenuBarExtra("SSH Config", systemImage: "terminal") {
            MenuBarView()
                .environment(model)
                .modelContainer(AppModel.container)
        }
        .menuBarExtraStyle(.window)
```

- [ ] **Step 3: Build + test**

Run: `tuist generate --no-open && tuist build SSHConfig && swift test`
Expected: BUILD SUCCEEDED; 63/63.

- [ ] **Step 4: Commit**

```bash
git add App
git commit -m "feat(app): searchable window-style menu bar panel"
```

---

### Task 5: Wrap-up — version bump, verification, reinstall

**Files:**
- Modify: `Project.swift` (`CFBundleShortVersionString` 0.1.0 → 0.2.0)
- Modify: `README.md` (feature list additions)

- [ ] **Step 1: Bump version in `Project.swift`**

Change `"CFBundleShortVersionString": "0.1.0"` to `"CFBundleShortVersionString": "0.2.0"`.

- [ ] **Step 2: Update README feature list**

Add to the Features section of `README.md`:

```markdown
- ⌘K command palette: fuzzy search across hosts and app actions
- Terminal-aware Connect: detects Terminal, iTerm2, Warp, Ghostty, Alacritty,
  kitty, WezTerm, and Zetty; pick a default in Settings or one-off via
  "Connect with …"
- Searchable menu bar panel (window style) that stays usable with many hosts
```

- [ ] **Step 3: Full verification**

Run: `swift test && tuist generate --no-open && tuist build SSHConfig`
Expected: 63/63 tests pass, BUILD SUCCEEDED.

- [ ] **Step 4: Release build + reinstall to /Applications**

```bash
xcodebuild -workspace sshconfig.xcworkspace -scheme SSHConfig -configuration Release -derivedDataPath build-release build
ditto build-release/Build/Products/Release/SSHConfig.app /Applications/SSHConfig.app
codesign -v /Applications/SSHConfig.app && plutil -p /Applications/SSHConfig.app/Contents/Info.plist | grep ShortVersion
```

Expected: BUILD SUCCEEDED, signature OK, version 0.2.0. (The app may be running — quit it first with `osascript -e 'quit app "SSHConfig"'` or `pkill -x SSHConfig` before ditto.)

- [ ] **Step 5: Commit**

```bash
git add Project.swift README.md
git commit -m "chore: bump to 0.2.0 with palette, terminal-aware connect, menu bar search"
```

---

## Self-Review Notes

- **Spec coverage:** registry table + argv expansion (Task 1), matcher (Task 1), launcher incl. zetty CLI + detection + fallback preference (Task 2), Settings picker + split Connect button (Task 2), palette with hosts+actions/keys/ranking/reveal (Task 3), window-style searchable menu bar with capped scroll + footer (Task 4), error handling via existing `pendingError` (Task 2 code). Out-of-scope items untouched.
- **Known runtime risks for reviewers:** `onKeyPress` focus interplay with the palette TextField (arrow keys may need `.onKeyPress` on the field itself if the container doesn't receive events); `Menu(primaryAction:)` styling in a toolbar-less detail pane; `openApplication` args for Ghostty/kitty/WezTerm are per-app conventions verified only at runtime — manual QA items.
- **Type consistency:** `AppModel.connect(_:with:)` used by palette (`onHost .connect` → `model.connect(entry.host)`) and menu bar; `preferredTerminal` computed from `installedTerminals` + `preferredTerminalId`; palette consumes `FormMode`/`selection`/`showSettings` which exist in MainWindow (implementer adapts to real names per Task 3 Step 2 note).
