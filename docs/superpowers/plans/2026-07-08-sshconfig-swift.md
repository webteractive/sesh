# SSH Config macOS App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Laravel SSH Config Manager (`~/Herd/sshconfig`) to a native SwiftUI macOS app with a SwiftData store, 3-mode sync, conflict resolution, backups, a main window, and a menu bar extra.

**Architecture:** A local SPM package `SSHConfigCore` (parser, writer, sync engine, conflicts, backups, settings — all unit-tested with swift-testing) plus a thin SwiftUI app target wired together by Tuist, mirroring `~/AI/zetty`'s layout. The store (SwiftData) is authoritative; the parser produces an ordered segment list so `Match`/`Include`/global directives survive round-trips.

**Tech Stack:** Swift (tools-version 6.0, language mode v5 for SwiftData ergonomics), SwiftUI, SwiftData, swift-testing (`import Testing`), Tuist 4.x, macOS 14.0+. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-07-08-sshconfig-swift-design.md` — read it before starting.

## Global Constraints

- Repo: `/Users/glenbangkila/AI/sshconfig-swift` (git repo, currently has zero commits).
- Bundle id `dev.more.sshconfig`, app name **SSH Config**, deployment target **macOS 14.0**.
- No sandbox, no third-party packages, no App Store provisions.
- Core logic lives in `Sources/SSHConfigCore/` and must not import SwiftUI/AppKit (exception: none). App code lives in `App/Sources/` and stays thin.
- Tests: swift-testing (`import Testing`, `@Test`, `#expect`), run with `swift test` from repo root.
- Build app with `tuist generate --no-open` then `tuist build SSHConfig`.
- **Git rules (user's global, non-negotiable):** NO `Co-Authored-By`, NO `Claude-Session:` lines in commit messages. The user has approved committing during this plan's execution, but never `git push` without asking.
- Writer output convention: segments joined by exactly one blank line; file ends with a single trailing newline; config file written `0600`, parent dir created `0700`.
- Round-trip guarantee is **parse equality**, not byte equality: `parse(write(parse(x))) == parse(x)` and a second write is byte-stable (idempotent).

---

### Task 1: Project scaffold (SPM package + Tuist project + app stub)

**Files:**
- Create: `Package.swift`
- Create: `Sources/SSHConfigCore/SSHConfigCore.swift`
- Create: `Tests/SSHConfigCoreTests/SmokeTests.swift`
- Create: `Tuist.swift`
- Create: `Project.swift`
- Create: `App/Sources/SSHConfigApp.swift`
- Create: `.gitignore`

**Interfaces:**
- Produces: buildable package `SSHConfigCore` + generatable Tuist app target `SSHConfig`. Later tasks add files under `Sources/SSHConfigCore/` and `App/Sources/` without touching build config (globs cover them).

- [ ] **Step 1: Create `.gitignore`**

```gitignore
.DS_Store
/.build
/build
/Derived
/dist
*.xcodeproj
*.xcworkspace
.swiftpm
```

- [ ] **Step 2: Create `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHConfigCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SSHConfigCore", targets: ["SSHConfigCore"]),
    ],
    targets: [
        .target(
            name: "SSHConfigCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SSHConfigCoreTests",
            dependencies: ["SSHConfigCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

(Language mode v5: SwiftData `@Model` classes are non-Sendable and fight Swift 6 strict concurrency; v5 keeps the port pragmatic.)

- [ ] **Step 3: Create `Sources/SSHConfigCore/SSHConfigCore.swift`**

```swift
/// SSHConfigCore — parsing, writing, syncing, and backing up ssh_config files.
public enum SSHConfigCoreInfo {
    public static let version = "0.1.0"
}
```

- [ ] **Step 4: Create `Tests/SSHConfigCoreTests/SmokeTests.swift`**

```swift
import Testing
@testable import SSHConfigCore

@Test func packageBuilds() {
    #expect(SSHConfigCoreInfo.version == "0.1.0")
}
```

- [ ] **Step 5: Run `swift test`**

Run: `swift test`
Expected: `Test run with 1 test passed`

- [ ] **Step 6: Create `Tuist.swift`** (matches zetty's)

```swift
import ProjectDescription

let config = Config()
```

- [ ] **Step 7: Create `Project.swift`**

```swift
import ProjectDescription

let project = Project(
    name: "sshconfig",
    packages: [
        .local(path: "."),
    ],
    targets: [
        .target(
            name: "SSHConfig",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.more.sshconfig",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleName": "SSH Config",
                "CFBundleDisplayName": "SSH Config",
                "CFBundleShortVersionString": "0.1.0",
                "LSMultipleInstancesProhibited": true,
            ]),
            sources: ["App/Sources/**"],
            dependencies: [
                .package(product: "SSHConfigCore"),
            ]
        ),
    ]
)
```

- [ ] **Step 8: Create `App/Sources/SSHConfigApp.swift`** (stub; replaced in Task 9)

```swift
import SwiftUI

@main
struct SSHConfigApp: App {
    var body: some Scene {
        WindowGroup {
            Text("SSH Config").padding()
        }
    }
}
```

- [ ] **Step 9: Generate and build the app**

Run: `tuist generate --no-open && tuist build SSHConfig`
Expected: BUILD SUCCEEDED. (If `tuist build` flags differ, check `tuist build --help`.)

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "chore: scaffold Tuist project with SSHConfigCore package and app stub"
```

---

### Task 2: Parser — `SSHProperty`, `Segment`, `SSHConfigParser`

**Files:**
- Create: `Sources/SSHConfigCore/SSHProperty.swift`
- Create: `Sources/SSHConfigCore/Segment.swift`
- Create: `Sources/SSHConfigCore/SSHConfigParser.swift`
- Test: `Tests/SSHConfigCoreTests/ParserTests.swift`

**Interfaces:**
- Produces:
  - `struct SSHProperty: Codable, Equatable, Sendable { var key: String; var values: [String] }`
  - `extension [SSHProperty]`: `func first(_ key: String) -> String?`, `mutating func set(_ key: String, _ value: String?)`, `var normalized: [String: [String]]`
  - `struct ParsedHost: Equatable, Sendable { var pattern: String; var properties: [SSHProperty]; var rawBlock: String }`
  - `enum Segment: Equatable, Sendable { case prologue(String), comment(String), include(String), matchBlock(String), hostBlock(ParsedHost) }`
  - `struct SSHConfigParser { init(); func parse(_ text: String) -> [Segment]; func parseFile(at path: String) -> [Segment]; func hosts(in segments: [Segment]) -> [ParsedHost] }`

Parsing rules (from ssh_config(5), see spec):
- `#`-lines and blank lines are comments; keywords case-insensitive; separator is whitespace or optional whitespace + exactly one `=`; property value is the remainder verbatim (quotes preserved in the value).
- `Host`/`Match` start blocks. Everything before the first block: one `.prologue`. A top-level `Include` line: `.include`. `Match` blocks are opaque (`.matchBlock` with verbatim text). Inside a Host block, comments interleaved between directives stay in `rawBlock`; **trailing** comment/blank lines after the block's last directive are pulled out into a `.comment` segment so they survive re-rendering.
- Repeated property keys accumulate into `values`.

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/ParserTests.swift`**

```swift
import Testing
@testable import SSHConfigCore

private let parser = SSHConfigParser()

@Test func parsesSimpleHostBlock() {
    let segs = parser.parse("""
    Host web
        HostName example.com
        User root
        Port 2222
    """)
    let hosts = parser.hosts(in: segs)
    #expect(hosts.count == 1)
    #expect(hosts[0].pattern == "web")
    #expect(hosts[0].properties.first("HostName") == "example.com")
    #expect(hosts[0].properties.first("user") == "root") // case-insensitive lookup
    #expect(hosts[0].properties.first("Port") == "2222")
}

@Test func parsesEqualsSeparatorAndKeywordCase() {
    let segs = parser.parse("""
    host web
        hostname=example.com
        Port = 2222
    """)
    let host = parser.hosts(in: segs)[0]
    #expect(host.pattern == "web")
    #expect(host.properties.first("HostName") == "example.com")
    #expect(host.properties.first("Port") == "2222")
}

@Test func preservesQuotedValueVerbatim() {
    let segs = parser.parse("""
    Host web
        IdentityFile "~/my keys/id_ed25519"
    """)
    #expect(parser.hosts(in: segs)[0].properties.first("IdentityFile")
            == "\"~/my keys/id_ed25519\"")
}

@Test func multiValueKeysAccumulate() {
    let segs = parser.parse("""
    Host web
        IdentityFile ~/.ssh/a
        IdentityFile ~/.ssh/b
    """)
    let props = parser.hosts(in: segs)[0].properties
    let idFiles = props.first { $0.key.caseInsensitiveCompare("IdentityFile") == .orderedSame }
    #expect(idFiles?.values == ["~/.ssh/a", "~/.ssh/b"])
}

@Test func multiPatternHostKeptAsOnePatternString() {
    let segs = parser.parse("Host web1 web2 *.example.com !bad\n    User root\n")
    #expect(parser.hosts(in: segs)[0].pattern == "web1 web2 *.example.com !bad")
}

@Test func prologueIsPreserved() {
    let segs = parser.parse("""
    # global settings
    ServerAliveInterval 60

    Host web
        User root
    """)
    guard case .prologue(let text) = segs[0] else { Issue.record("expected prologue"); return }
    #expect(text.contains("ServerAliveInterval 60"))
    #expect(text.contains("# global settings"))
    #expect(parser.hosts(in: segs).count == 1)
}

@Test func matchBlockIsOpaque() {
    let segs = parser.parse("""
    Host web
        User root

    Match host *.internal exec "corp-check"
        ProxyJump bastion
    """)
    #expect(parser.hosts(in: segs).count == 1)
    guard case .matchBlock(let text) = segs.last else { Issue.record("expected matchBlock"); return }
    #expect(text.contains("Match host *.internal"))
    #expect(text.contains("ProxyJump bastion"))
}

@Test func topLevelIncludeIsOwnSegment() {
    let segs = parser.parse("""
    Include ~/.ssh/config.d/*

    Host web
        User root
    """)
    guard case .include(let line) = segs[0] else { Issue.record("expected include"); return }
    #expect(line == "Include ~/.ssh/config.d/*")
}

@Test func includeInsideHostBlockBecomesProperty() {
    let segs = parser.parse("""
    Host web
        Include ~/.ssh/web-extras
        User root
    """)
    let props = parser.hosts(in: segs)[0].properties
    #expect(props.first("Include") == "~/.ssh/web-extras")
}

@Test func trailingCommentsAfterHostBlockBecomeCommentSegment() {
    let segs = parser.parse("""
    Host web
        User root
    # standalone note

    Host db
        User admin
    """)
    #expect(parser.hosts(in: segs).map(\.pattern) == ["web", "db"])
    let hasComment = segs.contains { if case .comment(let t) = $0 { return t.contains("standalone note") } else { return false } }
    #expect(hasComment)
    // and the comment is NOT inside web's raw block
    #expect(!parser.hosts(in: segs)[0].rawBlock.contains("standalone note"))
}

@Test func rawBlockKeepsOriginalLines() {
    let text = "Host web\n    HostName example.com # inline is part of value\n"
    let host = parser.hosts(in: parser.parse(text))[0]
    #expect(host.rawBlock.hasPrefix("Host web"))
    #expect(host.rawBlock.contains("HostName example.com"))
}

@Test func emptyAndMissingInput() {
    #expect(parser.parse("").isEmpty)
    #expect(parser.parseFile(at: "/nonexistent/path/config").isEmpty)
}

@Test func propertyListHelpers() {
    var props: [SSHProperty] = []
    props.set("HostName", "a.example.com")
    props.set("Port", "22")
    props.set("Port", "2200")           // replaces
    props.set("HostName", nil)          // removes
    #expect(props == [SSHProperty(key: "Port", values: ["2200"])])
    #expect(props.normalized == ["port": ["2200"]])
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test`
Expected: FAIL — `cannot find 'SSHConfigParser' in scope` (compile error counts as the failing state).

- [ ] **Step 3: Implement `Sources/SSHConfigCore/SSHProperty.swift`**

```swift
public struct SSHProperty: Codable, Equatable, Sendable {
    public var key: String
    public var values: [String]

    public init(key: String, values: [String]) {
        self.key = key
        self.values = values
    }
}

public extension [SSHProperty] {
    /// First value for a key, case-insensitive.
    func first(_ key: String) -> String? {
        first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.values.first
    }

    /// Replace all values for a key with a single value; nil/empty removes the key.
    mutating func set(_ key: String, _ value: String?) {
        if let value, !value.isEmpty {
            if let i = firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                self[i] = SSHProperty(key: self[i].key, values: [value])
            } else {
                append(SSHProperty(key: key, values: [value]))
            }
        } else {
            removeAll { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        }
    }

    /// Lowercased-key map for order-insensitive comparison (conflict detection).
    var normalized: [String: [String]] {
        var out: [String: [String]] = [:]
        for p in self { out[p.key.lowercased(), default: []].append(contentsOf: p.values) }
        return out
    }
}
```

- [ ] **Step 4: Implement `Sources/SSHConfigCore/Segment.swift`**

```swift
public struct ParsedHost: Equatable, Sendable {
    public var pattern: String
    public var properties: [SSHProperty]
    public var rawBlock: String

    public init(pattern: String, properties: [SSHProperty], rawBlock: String) {
        self.pattern = pattern
        self.properties = properties
        self.rawBlock = rawBlock
    }
}

public enum Segment: Equatable, Sendable {
    case prologue(String)
    case comment(String)
    case include(String)
    case matchBlock(String)
    case hostBlock(ParsedHost)
}
```

- [ ] **Step 5: Implement `Sources/SSHConfigCore/SSHConfigParser.swift`**

```swift
import Foundation

public struct SSHConfigParser {
    public init() {}

    /// Splits "keyword args" honoring the optional single '=' separator.
    /// Returns nil for blank/comment lines.
    static func directive(from line: String) -> (keyword: String, args: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var keyword = ""
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, !trimmed[idx].isWhitespace, trimmed[idx] != "=" {
            keyword.append(trimmed[idx])
            idx = trimmed.index(after: idx)
        }
        var rest = trimmed[idx...].drop(while: { $0.isWhitespace })
        if rest.first == "=" {
            rest = rest.dropFirst().drop(while: { $0.isWhitespace })
        }
        guard !keyword.isEmpty else { return nil }
        return (keyword, String(rest))
    }

    public func parse(_ text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }
        let lines = text.components(separatedBy: "\n")
        var segments: [Segment] = []

        enum State {
            case prologue(lines: [String])
            case host(pattern: String, props: [SSHProperty], raw: [String])
            case match(raw: [String])
        }
        var state: State = .prologue(lines: [])

        // Closes the current block. Trailing non-directive lines are split off
        // into a .comment segment so they survive host-block re-rendering.
        func flush() {
            switch state {
            case .prologue(let ls):
                let text = ls.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { segments.append(.prologue(text)) }
            case .host(let pattern, let props, var raw):
                var trailing: [String] = []
                while let last = raw.last, Self.directive(from: last) == nil {
                    trailing.insert(last, at: 0)
                    raw.removeLast()
                }
                segments.append(.hostBlock(ParsedHost(
                    pattern: pattern,
                    properties: props,
                    rawBlock: raw.joined(separator: "\n")
                )))
                let trailingText = trailing.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailingText.isEmpty { segments.append(.comment(trailingText)) }
            case .match(var raw):
                var trailing: [String] = []
                while let last = raw.last, Self.directive(from: last) == nil {
                    trailing.insert(last, at: 0)
                    raw.removeLast()
                }
                segments.append(.matchBlock(raw.joined(separator: "\n")))
                let trailingText = trailing.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailingText.isEmpty { segments.append(.comment(trailingText)) }
            }
        }

        for line in lines {
            let dir = Self.directive(from: line)
            let keyword = dir?.keyword.lowercased()

            switch keyword {
            case "host":
                flush()
                state = .host(pattern: dir!.args, props: [], raw: [line])
            case "match":
                flush()
                state = .match(raw: [line])
            case "include":
                // Top-level Include is its own segment; inside a block it belongs to the block.
                switch state {
                case .prologue:
                    flush()
                    segments.append(.include(line.trimmingCharacters(in: .whitespaces)))
                    state = .prologue(lines: [])
                case .host(let pattern, var props, var raw):
                    appendProperty(&props, keyword: dir!.keyword, value: dir!.args)
                    raw.append(line)
                    state = .host(pattern: pattern, props: props, raw: raw)
                case .match(var raw):
                    raw.append(line)
                    state = .match(raw: raw)
                }
            default:
                switch state {
                case .prologue(var ls):
                    ls.append(line)
                    state = .prologue(lines: ls)
                case .host(let pattern, var props, var raw):
                    if let dir { appendProperty(&props, keyword: dir.keyword, value: dir.args) }
                    raw.append(line)
                    state = .host(pattern: pattern, props: props, raw: raw)
                case .match(var raw):
                    raw.append(line)
                    state = .match(raw: raw)
                }
            }
        }
        flush()
        return segments
    }

    private func appendProperty(_ props: inout [SSHProperty], keyword: String, value: String) {
        guard !value.isEmpty else { return }
        if let i = props.firstIndex(where: { $0.key.caseInsensitiveCompare(keyword) == .orderedSame }) {
            props[i].values.append(value)
        } else {
            props.append(SSHProperty(key: keyword, values: [value]))
        }
    }

    public func parseFile(at path: String) -> [Segment] {
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else { return [] }
        return parse(text)
    }

    public func hosts(in segments: [Segment]) -> [ParsedHost] {
        segments.compactMap { if case .hostBlock(let h) = $0 { return h } else { return nil } }
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test`
Expected: all ParserTests PASS (plus smoke test).

- [ ] **Step 7: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): ssh_config parser with segment preservation"
```

---

### Task 3: `HostEntry` SwiftData model + form mapping

**Files:**
- Create: `Sources/SSHConfigCore/HostEntry.swift`
- Create: `Sources/SSHConfigCore/HostFormData.swift`
- Test: `Tests/SSHConfigCoreTests/HostEntryTests.swift`

**Interfaces:**
- Consumes: `SSHProperty`, `[SSHProperty].first/set` (Task 2).
- Produces:
  - `@Model final class HostEntry` — `init(host: String, properties: [SSHProperty], rawBlock: String?)`; stored: `host` (`@Attribute(.unique)`), `properties: [SSHProperty]`, `rawBlock: String?`, `createdAt: Date`, `updatedAt: Date`; computed: `var sshCommand: String` (`"ssh <host>"`), `var port: String` (Port or "22"), `var isConnectable: Bool` (pattern has no `*?! ` chars).
  - `struct HostFormData` — `var host, hostName, user, port, identityFile: String; var extras: [SSHProperty]`; `init()`, `init(entry: HostEntry)`, `func properties() -> [SSHProperty]`, `func validationError(existingHosts: Set<String>) -> String?`, `static let coreKeys: Set<String> = ["hostname", "user", "port", "identityfile"]`, `static let hostPatternRegex`.
  - Test helper `makeContext()` used by Tasks 6–7 tests.

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/HostEntryTests.swift`**

```swift
import Testing
import SwiftData
@testable import SSHConfigCore

@MainActor
func makeContext() throws -> ModelContext {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: HostEntry.self, configurations: config)
    return ModelContext(container)
}

@MainActor @Test func hostEntryPersistsAndComputes() throws {
    let ctx = try makeContext()
    let entry = HostEntry(host: "web", properties: [
        SSHProperty(key: "HostName", values: ["example.com"]),
        SSHProperty(key: "User", values: ["root"]),
    ], rawBlock: "Host web")
    ctx.insert(entry)
    try ctx.save()

    let fetched = try ctx.fetch(FetchDescriptor<HostEntry>())
    #expect(fetched.count == 1)
    #expect(fetched[0].sshCommand == "ssh web")
    #expect(fetched[0].port == "22")
    #expect(fetched[0].isConnectable)
}

@MainActor @Test func wildcardHostsAreNotConnectable() throws {
    #expect(!HostEntry(host: "*", properties: [], rawBlock: nil).isConnectable)
    #expect(!HostEntry(host: "web1 web2", properties: [], rawBlock: nil).isConnectable)
    #expect(!HostEntry(host: "!bad", properties: [], rawBlock: nil).isConnectable)
}

@Test func formDataRoundTrip() {
    let entry = HostEntry(host: "web", properties: [
        SSHProperty(key: "HostName", values: ["example.com"]),
        SSHProperty(key: "Port", values: ["2222"]),
        SSHProperty(key: "ProxyJump", values: ["bastion"]),
    ], rawBlock: nil)
    var form = HostFormData(entry: entry)
    #expect(form.hostName == "example.com")
    #expect(form.port == "2222")
    #expect(form.user == "")
    #expect(form.extras == [SSHProperty(key: "ProxyJump", values: ["bastion"])])

    form.user = "root"
    let props = form.properties()
    // Core keys first (HostName, User, Port, IdentityFile order), extras after.
    #expect(props.first("HostName") == "example.com")
    #expect(props.first("User") == "root")
    #expect(props.first("Port") == "2222")
    #expect(props.first("IdentityFile") == nil)
    #expect(props.last == SSHProperty(key: "ProxyJump", values: ["bastion"]))
}

@Test func formValidation() {
    var form = HostFormData()
    #expect(form.validationError(existingHosts: []) != nil)          // empty host

    form.host = "web prod-* !bad"                                     // patterns + wildcard ok
    #expect(form.validationError(existingHosts: []) == nil)

    form.host = "has/slash"
    #expect(form.validationError(existingHosts: []) != nil)           // invalid char

    form.host = "web"
    #expect(form.validationError(existingHosts: ["web"]) != nil)      // duplicate

    form.port = "70000"
    form.host = "ok"
    #expect(form.validationError(existingHosts: []) != nil)           // port range

    form.port = "22"
    #expect(form.validationError(existingHosts: []) == nil)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test`
Expected: FAIL — `cannot find 'HostEntry' in scope`.

- [ ] **Step 3: Implement `Sources/SSHConfigCore/HostEntry.swift`**

```swift
import Foundation
import SwiftData

@Model
public final class HostEntry {
    @Attribute(.unique) public var host: String
    public var properties: [SSHProperty]
    public var rawBlock: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(host: String, properties: [SSHProperty], rawBlock: String?) {
        self.host = host
        self.properties = properties
        self.rawBlock = rawBlock
        self.createdAt = .now
        self.updatedAt = .now
    }

    public var sshCommand: String { "ssh \(host)" }

    public var port: String { properties.first("Port") ?? "22" }

    /// A host is directly connectable only when its pattern is a single
    /// literal alias (no wildcards, negation, or multiple patterns).
    public var isConnectable: Bool {
        !host.isEmpty && !host.contains(where: { "*?! ".contains($0) })
    }
}
```

- [ ] **Step 4: Implement `Sources/SSHConfigCore/HostFormData.swift`**

```swift
import Foundation

/// Mirrors the Laravel form: 5 core fields + arbitrary extra properties.
public struct HostFormData: Equatable {
    public var host = ""
    public var hostName = ""
    public var user = ""
    public var port = ""
    public var identityFile = ""
    public var extras: [SSHProperty] = []

    public static let coreKeys: Set<String> = ["hostname", "user", "port", "identityfile"]

    /// Laravel's [a-zA-Z0-9._-]+ loosened to allow *, ?, ! and spaces between
    /// patterns so imported wildcard hosts stay editable (see spec).
    public static let hostPatternRegex = #/^[A-Za-z0-9._\-*?!]+( +[A-Za-z0-9._\-*?!]+)*$/#
    // (#/…/# delimiters required: bare /…/ regex literals don't parse in Swift 5 language mode)

    public init() {}

    public init(entry: HostEntry) {
        host = entry.host
        hostName = entry.properties.first("HostName") ?? ""
        user = entry.properties.first("User") ?? ""
        port = entry.properties.first("Port") ?? ""
        identityFile = entry.properties.first("IdentityFile") ?? ""
        extras = entry.properties.filter { !Self.coreKeys.contains($0.key.lowercased()) }
    }

    /// Rebuild the ordered property list: core keys first, extras after.
    public func properties() -> [SSHProperty] {
        var props: [SSHProperty] = []
        props.set("HostName", hostName)
        props.set("User", user)
        props.set("Port", port)
        props.set("IdentityFile", identityFile)
        props.append(contentsOf: extras.filter { !$0.key.isEmpty && !$0.values.allSatisfy(\.isEmpty) })
        return props
    }

    /// nil when valid; otherwise a user-facing message.
    public func validationError(existingHosts: Set<String>) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        if trimmedHost.isEmpty { return "Host is required." }
        if trimmedHost.wholeMatch(of: Self.hostPatternRegex) == nil {
            return "Host may only contain letters, numbers, dots, underscores, hyphens, and the wildcards * ? ! (separate multiple patterns with spaces)."
        }
        if existingHosts.contains(trimmedHost) { return "A host named '\(trimmedHost)' already exists." }
        if !port.isEmpty {
            guard let p = Int(port), (1...65535).contains(p) else {
                return "Port must be between 1 and 65535."
            }
        }
        return nil
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): HostEntry SwiftData model and form mapping"
```

---

### Task 4: Writer — render blocks, rebuild file, permissions

**Files:**
- Create: `Sources/SSHConfigCore/SSHConfigWriter.swift`
- Test: `Tests/SSHConfigCoreTests/WriterTests.swift`

**Interfaces:**
- Consumes: `Segment`, `ParsedHost`, `SSHProperty`, `SSHConfigParser` (Task 2).
- Produces:
  - `struct RenderableHost { var host: String; var properties: [SSHProperty] }` (lightweight input so the writer never touches SwiftData).
  - `struct SSHConfigWriter { init(); func render(host: String, properties: [SSHProperty]) -> String; func renderFile(segments: [Segment], entries: [RenderableHost]) -> String; func write(_ content: String, toPath path: String) throws }`
  - Semantics: host segments present in `entries` are re-rendered from the store version; host segments absent from `entries` are dropped (store is authoritative); entries not in the file are appended at the end; all other segments emitted verbatim in order; chunks joined by one blank line; trailing newline; file `0600`, parent dir `0700`.

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/WriterTests.swift`**

```swift
import Testing
import Foundation
@testable import SSHConfigCore

private let parser = SSHConfigParser()
private let writer = SSHConfigWriter()

@Test func rendersHostBlockWithIndentedProperties() {
    let out = writer.render(host: "web", properties: [
        SSHProperty(key: "HostName", values: ["example.com"]),
        SSHProperty(key: "IdentityFile", values: ["~/.ssh/a", "~/.ssh/b"]),
    ])
    #expect(out == """
    Host web
        HostName example.com
        IdentityFile ~/.ssh/a
        IdentityFile ~/.ssh/b
    """)
}

@Test func rebuildPreservesNonHostSegmentsAndOrder() {
    let source = """
    # globals
    ServerAliveInterval 60

    Include ~/.ssh/config.d/*

    Host web
        HostName old.example.com

    Match host *.internal
        ProxyJump bastion
    """
    let segments = parser.parse(source)
    let out = writer.renderFile(segments: segments, entries: [
        RenderableHost(host: "web", properties: [SSHProperty(key: "HostName", values: ["new.example.com"])]),
        RenderableHost(host: "db", properties: [SSHProperty(key: "User", values: ["admin"])]),
    ])
    // Order: prologue, include, web (updated), match, then appended db.
    let expected = """
    # globals
    ServerAliveInterval 60

    Include ~/.ssh/config.d/*

    Host web
        HostName new.example.com

    Match host *.internal
        ProxyJump bastion

    Host db
        User admin

    """
    #expect(out == expected)
}

@Test func hostsMissingFromStoreAreDropped() {
    let segments = parser.parse("Host gone\n    User x\n\nHost kept\n    User y\n")
    let out = writer.renderFile(segments: segments, entries: [
        RenderableHost(host: "kept", properties: [SSHProperty(key: "User", values: ["y"])]),
    ])
    #expect(!out.contains("Host gone"))
    #expect(out.contains("Host kept"))
}

@Test func roundTripParseEqualityAndIdempotentSecondWrite() {
    let source = """
    # top comment
    Compression yes

    Host web staging-*
        HostName example.com
        Port=2222
        IdentityFile "~/my keys/id"

    Match all
        ForwardAgent yes
    """
    let segs1 = parser.parse(source)
    let entries = parser.hosts(in: segs1).map { RenderableHost(host: $0.pattern, properties: $0.properties) }
    let written1 = writer.renderFile(segments: segs1, entries: entries)
    let segs2 = parser.parse(written1)
    let entries2 = parser.hosts(in: segs2).map { RenderableHost(host: $0.pattern, properties: $0.properties) }
    #expect(parser.hosts(in: segs2) .map(\.pattern) == parser.hosts(in: segs1).map(\.pattern))
    #expect(parser.hosts(in: segs2).map(\.properties) == parser.hosts(in: segs1).map(\.properties))
    let written2 = writer.renderFile(segments: segs2, entries: entries2)
    #expect(written1 == written2) // byte-stable after first write
}

@Test func writeCreatesDirectoryAndSetsPermissions() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).path
    let path = dir + "/inner/config"
    try writer.write("Host web\n    User root\n", toPath: path)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir + "/inner")
    #expect((dirAttrs[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "Host web\n    User root\n")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test`
Expected: FAIL — `cannot find 'SSHConfigWriter' in scope`.

- [ ] **Step 3: Implement `Sources/SSHConfigCore/SSHConfigWriter.swift`**

```swift
import Foundation

/// Store-side view of a host block, decoupled from SwiftData.
public struct RenderableHost: Equatable, Sendable {
    public var host: String
    public var properties: [SSHProperty]

    public init(host: String, properties: [SSHProperty]) {
        self.host = host
        self.properties = properties
    }
}

public struct SSHConfigWriter {
    public init() {}

    public func render(host: String, properties: [SSHProperty]) -> String {
        var lines = ["Host \(host)"]
        for property in properties {
            for value in property.values {
                lines.append("    \(property.key) \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func renderFile(segments: [Segment], entries: [RenderableHost]) -> String {
        var chunks: [String] = []
        var written = Set<String>()

        for segment in segments {
            switch segment {
            case .prologue(let text), .comment(let text), .include(let text), .matchBlock(let text):
                chunks.append(text)
            case .hostBlock(let parsed):
                if let entry = entries.first(where: { $0.host == parsed.pattern }) {
                    chunks.append(render(host: entry.host, properties: entry.properties))
                    written.insert(entry.host)
                }
                // else: dropped — the store is authoritative for host blocks.
            }
        }
        for entry in entries where !written.contains(entry.host) {
            chunks.append(render(host: entry.host, properties: entry.properties))
        }
        guard !chunks.isEmpty else { return "" }
        return chunks.joined(separator: "\n\n") + "\n"
    }

    public func write(_ content: String, toPath path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        let dir = (expanded as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try content.write(toFile: expanded, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expanded)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS. Note: `roundTripParseEqualityAndIdempotentSecondWrite` also proves `Port=2222` normalizes to `Port 2222` on write while quoted values survive.

- [ ] **Step 5: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): segment-preserving ssh_config writer with 0600 permissions"
```

---

### Task 5: `BackupManager`

**Files:**
- Create: `Sources/SSHConfigCore/BackupManager.swift`
- Test: `Tests/SSHConfigCoreTests/BackupTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct BackupManager { init(keepCount: Int = 20); @discardableResult func backup(configPath: String, now: Date = .now) throws -> String; func backupPaths(configPath: String) -> [String] }` — backup path is `<configPath>.backup.yyyy-MM-dd_HHmmss` (Laravel's `date('Y-m-d_His')`), pruning keeps the `keepCount` newest.

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/BackupTests.swift`**

```swift
import Testing
import Foundation
@testable import SSHConfigCore

@Test func backupCopiesWithTimestampName() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try "Host web\n".write(toFile: config, atomically: true, encoding: .utf8)

    let fixed = Date(timeIntervalSince1970: 1_780_000_000)
    let backupPath = try BackupManager().backup(configPath: config, now: fixed)

    #expect(backupPath.hasPrefix(config + ".backup."))
    let stamp = backupPath.replacingOccurrences(of: config + ".backup.", with: "")
    #expect(stamp.wholeMatch(of: #/\d{4}-\d{2}-\d{2}_\d{6}/#) != nil)
    #expect(try String(contentsOfFile: backupPath, encoding: .utf8) == "Host web\n")
}

@Test func backupThrowsWhenConfigMissing() {
    #expect(throws: (any Error).self) {
        try BackupManager().backup(configPath: "/nonexistent/config")
    }
}

@Test func prunesToKeepCount() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let config = dir + "/config"
    try "x\n".write(toFile: config, atomically: true, encoding: .utf8)

    let manager = BackupManager(keepCount: 3)
    for i in 0..<5 {
        _ = try manager.backup(configPath: config, now: Date(timeIntervalSince1970: 1_780_000_000 + Double(i)))
    }
    let remaining = manager.backupPaths(configPath: config)
    #expect(remaining.count == 3)
    // Newest three survive: the two oldest stamps (…_000000 offsets 0 and 1) are gone.
    let stamps = remaining.map { String($0.suffix(17)) }.sorted()
    #expect(stamps == stamps.sorted())
    #expect(!remaining.isEmpty && remaining == remaining.sorted(by: >)) // newest first
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test`
Expected: FAIL — `cannot find 'BackupManager' in scope`.

- [ ] **Step 3: Implement `Sources/SSHConfigCore/BackupManager.swift`**

```swift
import Foundation

public struct BackupManager {
    public let keepCount: Int

    public init(keepCount: Int = 20) {
        self.keepCount = keepCount
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Copies the config to `<config>.backup.<timestamp>` and prunes old backups.
    @discardableResult
    public func backup(configPath: String, now: Date = .now) throws -> String {
        let expanded = (configPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: expanded])
        }
        let backupPath = expanded + ".backup." + Self.formatter.string(from: now)
        if FileManager.default.fileExists(atPath: backupPath) {
            try FileManager.default.removeItem(atPath: backupPath)
        }
        try FileManager.default.copyItem(atPath: expanded, toPath: backupPath)
        try prune(configPath: expanded)
        return backupPath
    }

    /// All backup paths for a config, newest first.
    public func backupPaths(configPath: String) -> [String] {
        let expanded = (configPath as NSString).expandingTildeInPath
        let dir = (expanded as NSString).deletingLastPathComponent
        let prefix = (expanded as NSString).lastPathComponent + ".backup."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) }
            .sorted(by: >) // timestamp format sorts lexically
            .map { dir + "/" + $0 }
    }

    private func prune(configPath: String) throws {
        let paths = backupPaths(configPath: configPath)
        for path in paths.dropFirst(keepCount) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): timestamped config backups with pruning"
```

---

### Task 6: `SyncEngine` — the three sync modes

**Files:**
- Create: `Sources/SSHConfigCore/SyncEngine.swift`
- Test: `Tests/SSHConfigCoreTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: `SSHConfigParser` (Task 2), `HostEntry` + `makeContext()` (Task 3), `SSHConfigWriter`/`RenderableHost` (Task 4), `BackupManager` (Task 5).
- Produces:
  - `enum SyncAction: String, Sendable { case created, updated, addedToFile }`
  - `struct SyncItem: Equatable, Identifiable, Sendable { var host: String; var action: SyncAction; var id: String { host + action.rawValue } }`
  - `struct SyncEngine { init(); @MainActor func syncFromFile(path: String, context: ModelContext) throws -> [SyncItem]; @MainActor func syncToFile(path: String, context: ModelContext) throws; @MainActor func syncBoth(path: String, context: ModelContext) throws -> [SyncItem] }`
  - Semantics (Laravel parity): fromFile = upsert, file wins; toFile = backup (if file exists) then rebuild file where the store's host set is authoritative and non-host segments are preserved; both = fromFile, then toFile, reporting store-only hosts as `.addedToFile`.

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/SyncEngineTests.swift`**

```swift
import Testing
import Foundation
import SwiftData
@testable import SSHConfigCore

private func tempConfig(_ content: String?) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/config"
    if let content { try content.write(toFile: path, atomically: true, encoding: .utf8) }
    return path
}

@MainActor @Test func fromFileCreatesAndUpdates() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "web",
                         properties: [SSHProperty(key: "User", values: ["old"])],
                         rawBlock: nil))
    try ctx.save()
    let path = try tempConfig("Host web\n    User root\n\nHost db\n    User admin\n")

    let items = try SyncEngine().syncFromFile(path: path, context: ctx)

    #expect(Set(items.map(\.id)) == ["webupdated", "dbcreated"])
    let all = try ctx.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.host)]))
    #expect(all.map(\.host) == ["db", "web"])
    #expect(all[1].properties.first("User") == "root") // file wins
    #expect(all[1].rawBlock?.contains("Host web") == true)
}

@MainActor @Test func fromFileNoChangesReportsNothing() throws {
    let ctx = try makeContext()
    let path = try tempConfig("Host web\n    User root\n")
    _ = try SyncEngine().syncFromFile(path: path, context: ctx)
    let again = try SyncEngine().syncFromFile(path: path, context: ctx)
    #expect(again.isEmpty)
}

@MainActor @Test func fromFileMissingFileReturnsEmpty() throws {
    let ctx = try makeContext()
    let items = try SyncEngine().syncFromFile(path: "/nonexistent/config", context: ctx)
    #expect(items.isEmpty)
}

@MainActor @Test func toFileWritesStoreAndBacksUp() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "web",
                         properties: [SSHProperty(key: "HostName", values: ["example.com"])],
                         rawBlock: nil))
    try ctx.save()
    let path = try tempConfig("# keep me\nCompression yes\n\nHost stale\n    User x\n")

    try SyncEngine().syncToFile(path: path, context: ctx)

    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.contains("# keep me"))          // prologue preserved
    #expect(text.contains("Host web"))           // store host written
    #expect(!text.contains("Host stale"))        // file-only host dropped (Laravel parity)
    #expect(BackupManager().backupPaths(configPath: path).count == 1)
}

@MainActor @Test func toFileCreatesMissingFileWithoutBackup() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "web", properties: [], rawBlock: nil))
    try ctx.save()
    let path = try tempConfig(nil) // directory exists, file doesn't

    try SyncEngine().syncToFile(path: path, context: ctx)

    #expect(FileManager.default.fileExists(atPath: path))
    #expect(BackupManager().backupPaths(configPath: path).isEmpty)
}

@MainActor @Test func bothFileWinsAndStoreOnlyAppended() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "web",
                         properties: [SSHProperty(key: "User", values: ["stale"])],
                         rawBlock: nil))
    ctx.insert(HostEntry(host: "storeonly",
                         properties: [SSHProperty(key: "User", values: ["me"])],
                         rawBlock: nil))
    try ctx.save()
    let path = try tempConfig("Host web\n    User root\n")

    let items = try SyncEngine().syncBoth(path: path, context: ctx)

    #expect(Set(items.map(\.id)) == ["webupdated", "storeonlyaddedToFile"])
    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.contains("Host storeonly"))
    let web = try ctx.fetch(FetchDescriptor<HostEntry>()).first { $0.host == "web" }
    #expect(web?.properties.first("User") == "root") // file won
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test`
Expected: FAIL — `cannot find 'SyncEngine' in scope`.

- [ ] **Step 3: Implement `Sources/SSHConfigCore/SyncEngine.swift`**

```swift
import Foundation
import SwiftData

public enum SyncAction: String, Sendable {
    case created, updated, addedToFile
}

public struct SyncItem: Equatable, Identifiable, Sendable {
    public var host: String
    public var action: SyncAction
    public var id: String { host + action.rawValue }

    public init(host: String, action: SyncAction) {
        self.host = host
        self.action = action
    }
}

public struct SyncEngine {
    private let parser = SSHConfigParser()
    private let writer = SSHConfigWriter()
    private let backups = BackupManager()

    public init() {}

    /// File → store. Upserts every parsed host; the file wins on differences.
    @MainActor
    public func syncFromFile(path: String, context: ModelContext) throws -> [SyncItem] {
        let fileHosts = parser.hosts(in: parser.parseFile(at: path))
        guard !fileHosts.isEmpty else { return [] }
        let existing = try context.fetch(FetchDescriptor<HostEntry>())
        var byHost = Dictionary(uniqueKeysWithValues: existing.map { ($0.host, $0) })
        var items: [SyncItem] = []

        for fileHost in fileHosts {
            if let entry = byHost[fileHost.pattern] {
                if entry.properties.normalized != fileHost.properties.normalized {
                    entry.properties = fileHost.properties
                    entry.rawBlock = fileHost.rawBlock
                    entry.updatedAt = .now
                    items.append(SyncItem(host: fileHost.pattern, action: .updated))
                } else if entry.rawBlock != fileHost.rawBlock {
                    entry.rawBlock = fileHost.rawBlock
                }
            } else {
                let entry = HostEntry(host: fileHost.pattern,
                                      properties: fileHost.properties,
                                      rawBlock: fileHost.rawBlock)
                context.insert(entry)
                byHost[fileHost.pattern] = entry
                items.append(SyncItem(host: fileHost.pattern, action: .created))
            }
        }
        try context.save()
        return items
    }

    /// Store → file. Backs up first (when the file exists), preserves non-host
    /// segments, drops file hosts missing from the store, appends store-only hosts.
    @MainActor
    public func syncToFile(path: String, context: ModelContext) throws {
        let expanded = (path as NSString).expandingTildeInPath
        let entries = try context
            .fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.createdAt)]))
            .map { RenderableHost(host: $0.host, properties: $0.properties) }
        let segments = parser.parseFile(at: expanded)
        if FileManager.default.fileExists(atPath: expanded) {
            try backups.backup(configPath: expanded)
        }
        try writer.write(writer.renderFile(segments: segments, entries: entries), toPath: expanded)
    }

    /// Both directions, Laravel semantics: file wins on shared hosts, then the
    /// merged store is written back (store-only hosts reported as addedToFile).
    @MainActor
    public func syncBoth(path: String, context: ModelContext) throws -> [SyncItem] {
        let filePatterns = Set(parser.hosts(in: parser.parseFile(at: path)).map(\.pattern))
        var items = try syncFromFile(path: path, context: context)
        let all = try context.fetch(FetchDescriptor<HostEntry>())
        for entry in all where !filePatterns.contains(entry.host) {
            items.append(SyncItem(host: entry.host, action: .addedToFile))
        }
        try syncToFile(path: path, context: context)
        return items
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): three-mode sync engine with automatic backups"
```

---

### Task 7: `ConflictDetector` + `ConflictResolver`

**Files:**
- Create: `Sources/SSHConfigCore/Conflicts.swift`
- Test: `Tests/SSHConfigCoreTests/ConflictTests.swift`

**Interfaces:**
- Consumes: `SSHConfigParser`, `SSHProperty.normalized` (Task 2), `HostEntry` + `makeContext()` (Task 3).
- Produces:
  - `struct Conflict: Equatable, Identifiable, Sendable { enum Source: String, Sendable { case both, store, file }; var host: String; var source: Source; var fileProperties: [SSHProperty]?; var storeProperties: [SSHProperty]?; var id: String { host + source.rawValue } }`
  - `struct ConflictDetector { init(); @MainActor func detect(path: String, context: ModelContext) throws -> [Conflict] }`
  - `struct ConflictResolver { init(); @MainActor func rename(host: String, to newHost: String, updateExisting: Bool, context: ModelContext) throws; @MainActor func acceptFileVersion(_ conflict: Conflict, context: ModelContext) throws }`

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/ConflictTests.swift`**

```swift
import Testing
import Foundation
import SwiftData
@testable import SSHConfigCore

private func writeTemp(_ content: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/config"
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@MainActor @Test func detectsAllThreeConflictKinds() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "differs",
                         properties: [SSHProperty(key: "User", values: ["storeuser"])],
                         rawBlock: nil))
    ctx.insert(HostEntry(host: "storeonly", properties: [], rawBlock: nil))
    try ctx.save()
    let path = try writeTemp("""
    Host differs
        User fileuser

    Host fileonly
        User x
    """)

    let conflicts = try ConflictDetector().detect(path: path, context: ctx)
    let bySource = Dictionary(grouping: conflicts, by: \.source)

    #expect(bySource[.both]?.map(\.host) == ["differs"])
    #expect(bySource[.both]?[0].fileProperties?.first("User") == "fileuser")
    #expect(bySource[.both]?[0].storeProperties?.first("User") == "storeuser")
    #expect(bySource[.store]?.map(\.host) == ["storeonly"])
    #expect(bySource[.file]?.map(\.host) == ["fileonly"])
}

@MainActor @Test func identicalHostsProduceNoConflict() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "same",
                         properties: [SSHProperty(key: "User", values: ["root"])],
                         rawBlock: nil))
    try ctx.save()
    let path = try writeTemp("Host same\n    User root\n")
    #expect(try ConflictDetector().detect(path: path, context: ctx).isEmpty)
}

@MainActor @Test func renameUpdatesExistingEntry() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "old", properties: [], rawBlock: nil))
    try ctx.save()

    try ConflictResolver().rename(host: "old", to: "new", updateExisting: true, context: ctx)

    let hosts = try ctx.fetch(FetchDescriptor<HostEntry>()).map(\.host)
    #expect(hosts == ["new"])
}

@MainActor @Test func renameKeepBothDuplicates() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "old",
                         properties: [SSHProperty(key: "User", values: ["root"])],
                         rawBlock: nil))
    try ctx.save()

    try ConflictResolver().rename(host: "old", to: "new", updateExisting: false, context: ctx)

    let all = try ctx.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.host)]))
    #expect(all.map(\.host) == ["new", "old"])
    #expect(all[0].properties.first("User") == "root")
}

@MainActor @Test func renameMissingHostThrows() throws {
    let ctx = try makeContext()
    #expect(throws: (any Error).self) {
        try ConflictResolver().rename(host: "ghost", to: "x", updateExisting: true, context: ctx)
    }
}

@MainActor @Test func acceptFileVersionUpsertsStore() throws {
    let ctx = try makeContext()
    ctx.insert(HostEntry(host: "differs",
                         properties: [SSHProperty(key: "User", values: ["storeuser"])],
                         rawBlock: nil))
    try ctx.save()
    let conflict = Conflict(host: "differs", source: .both,
                            fileProperties: [SSHProperty(key: "User", values: ["fileuser"])],
                            storeProperties: nil)

    try ConflictResolver().acceptFileVersion(conflict, context: ctx)

    let entry = try ctx.fetch(FetchDescriptor<HostEntry>()).first
    #expect(entry?.properties.first("User") == "fileuser")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test`
Expected: FAIL — `cannot find 'ConflictDetector' in scope`.

- [ ] **Step 3: Implement `Sources/SSHConfigCore/Conflicts.swift`**

```swift
import Foundation
import SwiftData

public struct Conflict: Equatable, Identifiable, Sendable {
    public enum Source: String, Sendable {
        case both   // exists in both but properties differ
        case store  // store-only
        case file   // file-only
    }

    public var host: String
    public var source: Source
    public var fileProperties: [SSHProperty]?
    public var storeProperties: [SSHProperty]?
    public var id: String { host + source.rawValue }

    public init(host: String, source: Source,
                fileProperties: [SSHProperty]?, storeProperties: [SSHProperty]?) {
        self.host = host
        self.source = source
        self.fileProperties = fileProperties
        self.storeProperties = storeProperties
    }
}

public struct ConflictDetector {
    private let parser = SSHConfigParser()

    public init() {}

    @MainActor
    public func detect(path: String, context: ModelContext) throws -> [Conflict] {
        let fileHosts = parser.hosts(in: parser.parseFile(at: path))
        let filePatterns = Set(fileHosts.map(\.pattern))
        let storeEntries = try context.fetch(FetchDescriptor<HostEntry>(sortBy: [SortDescriptor(\.host)]))
        let storeByHost = Dictionary(uniqueKeysWithValues: storeEntries.map { ($0.host, $0) })
        var conflicts: [Conflict] = []

        for fileHost in fileHosts {
            if let entry = storeByHost[fileHost.pattern] {
                if entry.properties.normalized != fileHost.properties.normalized {
                    conflicts.append(Conflict(host: fileHost.pattern, source: .both,
                                              fileProperties: fileHost.properties,
                                              storeProperties: entry.properties))
                }
            } else {
                conflicts.append(Conflict(host: fileHost.pattern, source: .file,
                                          fileProperties: fileHost.properties,
                                          storeProperties: nil))
            }
        }
        for entry in storeEntries where !filePatterns.contains(entry.host) {
            conflicts.append(Conflict(host: entry.host, source: .store,
                                      fileProperties: nil,
                                      storeProperties: entry.properties))
        }
        return conflicts
    }
}

public struct ConflictResolver {
    public init() {}

    public enum ResolverError: LocalizedError {
        case hostNotFound(String)
        public var errorDescription: String? {
            if case .hostNotFound(let host) = self { return "Host '\(host)' not found." }
            return nil
        }
    }

    /// Laravel's ResolveSshConfigConflictAction: rename in place, or keep both
    /// by duplicating under the new name.
    @MainActor
    public func rename(host: String, to newHost: String, updateExisting: Bool,
                       context: ModelContext) throws {
        let all = try context.fetch(FetchDescriptor<HostEntry>())
        guard let existing = all.first(where: { $0.host == host }) else {
            throw ResolverError.hostNotFound(host)
        }
        if updateExisting {
            existing.host = newHost
            existing.updatedAt = .now
        } else {
            context.insert(HostEntry(host: newHost,
                                     properties: existing.properties,
                                     rawBlock: existing.rawBlock))
        }
        try context.save()
    }

    /// Overwrite (or create) the store entry with the file's version.
    @MainActor
    public func acceptFileVersion(_ conflict: Conflict, context: ModelContext) throws {
        guard let fileProps = conflict.fileProperties else { return }
        let all = try context.fetch(FetchDescriptor<HostEntry>())
        if let existing = all.first(where: { $0.host == conflict.host }) {
            existing.properties = fileProps
            existing.updatedAt = .now
        } else {
            context.insert(HostEntry(host: conflict.host, properties: fileProps, rawBlock: nil))
        }
        try context.save()
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): conflict detection and resolution"
```

---

### Task 8: `ConfigPathStore`

**Files:**
- Create: `Sources/SSHConfigCore/ConfigPathStore.swift`
- Test: `Tests/SSHConfigCoreTests/ConfigPathTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum PathValidation: Equatable { case success(String), failure(String) }` and `struct ConfigPathStore { init(defaults: UserDefaults = .standard); var path: String? { get nonmutating set }; static let defaultSuggestion = "~/.ssh/config"; static func validate(_ raw: String) -> PathValidation }` — `validate` trims, expands `~`, requires an absolute path whose parent directory exists; returns the expanded path or a message. Setter stores the expanded path; setting nil clears.

- [ ] **Step 1: Write failing tests — `Tests/SSHConfigCoreTests/ConfigPathTests.swift`**

```swift
import Testing
import Foundation
@testable import SSHConfigCore

@Test func storesAndClearsPath() {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let store = ConfigPathStore(defaults: defaults)
    #expect(store.path == nil)
    store.path = "/tmp/config"
    #expect(store.path == "/tmp/config")
    store.path = nil
    #expect(store.path == nil)
}

@Test func validateExpandsTildeAndChecksDirectory() {
    let home = NSHomeDirectory()
    switch ConfigPathStore.validate("~/.ssh/config") {
    case .success(let expanded): #expect(expanded == home + "/.ssh/config")
    case .failure(let msg): Issue.record("unexpected failure: \(msg)")
    }

    if case .success = ConfigPathStore.validate("relative/path") {
        Issue.record("relative paths must fail")
    }
    if case .success = ConfigPathStore.validate("/nonexistent-dir-xyz/config") {
        Issue.record("missing parent directory must fail")
    }
    if case .success = ConfigPathStore.validate("   ") {
        Issue.record("blank must fail")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test`
Expected: FAIL — `cannot find 'ConfigPathStore' in scope`.

- [ ] **Step 3: Implement `Sources/SSHConfigCore/ConfigPathStore.swift`**

```swift
import Foundation

/// Native analog of the Laravel settings table: the config path in UserDefaults.
public struct ConfigPathStore {
    public static let key = "sshConfigPath"
    public static let defaultSuggestion = "~/.ssh/config"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var path: String? {
        get { defaults.string(forKey: Self.key) }
        nonmutating set {
            if let newValue {
                defaults.set((newValue as NSString).expandingTildeInPath, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    /// Trim + expand ~; require absolute path with an existing parent directory.
    public static func validate(_ raw: String) -> PathValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure("Config path is required.") }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failure("Config path must be absolute (start with / or ~).")
        }
        let dir = (expanded as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return .failure("Directory does not exist: \(dir)")
        }
        return .success(expanded)
    }
}

/// Validation outcome (String payloads on both sides, so Result<_, Error> doesn't fit).
public enum PathValidation: Equatable {
    case success(String)
    case failure(String)
}
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS. Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SSHConfigCore Tests/SSHConfigCoreTests
git commit -m "feat(core): config path store with validation"
```

---

### Task 9: App shell — `AppModel`, scenes, main window with host list

**Files:**
- Modify: `App/Sources/SSHConfigApp.swift` (replace stub)
- Create: `App/Sources/AppModel.swift`
- Create: `App/Sources/Views/MainWindow.swift`
- Create: `App/Sources/Views/HostDetailView.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–8.
- Produces: `AppModel` (`@MainActor @Observable final class`) with `static let container: ModelContainer`, `var configPath: String?`, `var pendingError: String?`, `var syncItems: [SyncItem]?`, `var conflicts: [Conflict]`, `var showSyncSheet: Bool`, `var showFirstRun: Bool`, methods `func runSync(_ mode: SyncMode)`, `func autoSyncToFile()`, `func connect(_ host: String)`, `func copyCommand(_ entry: HostEntry)`, `func saveConfigPath(_ raw: String) -> String?`, `enum SyncMode { case fromFile, toFile, both }`. Later tasks add sheets that read these.

- [ ] **Step 1: Create `App/Sources/AppModel.swift`**

```swift
import AppKit
import Foundation
import Observation
import SwiftData
import SSHConfigCore

enum SyncMode: String, CaseIterable, Identifiable {
    case fromFile = "Sync From File"
    case toFile = "Sync To File"
    case both = "Sync Both"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: HostEntry.self)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }()

    private let pathStore = ConfigPathStore()
    private let engine = SyncEngine()
    private let detector = ConflictDetector()
    let resolver = ConflictResolver()

    var pendingError: String?
    var syncItems: [SyncItem]?
    var conflicts: [Conflict] = []
    var showSyncSheet = false
    var showFirstRun = false

    var context: ModelContext { Self.container.mainContext }
    var configPath: String? { pathStore.path }

    func onLaunch() {
        showFirstRun = (configPath == nil)
    }

    /// Returns an error message, or nil on success (mirrors SetConfigPathAction:
    /// store path, backup if the file exists, initial import).
    func saveConfigPath(_ raw: String) -> String? {
        switch ConfigPathStore.validate(raw) {
        case .failure(let message):
            return message
        case .success(let expanded):
            pathStore.path = expanded
            if FileManager.default.fileExists(atPath: expanded) {
                do {
                    try BackupManager().backup(configPath: expanded)
                    _ = try engine.syncFromFile(path: expanded, context: context)
                } catch {
                    pendingError = "Path saved, but backup or import failed: \(error.localizedDescription)"
                }
            }
            showFirstRun = false
            return nil
        }
    }

    func runSync(_ mode: SyncMode) {
        guard let path = configPath else { showFirstRun = true; return }
        do {
            switch mode {
            case .fromFile: syncItems = try engine.syncFromFile(path: path, context: context)
            case .toFile:  try engine.syncToFile(path: path, context: context); syncItems = []
            case .both:    syncItems = try engine.syncBoth(path: path, context: context)
            }
            conflicts = try detector.detect(path: path, context: context)
            showSyncSheet = true
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// Fire-and-forget store→file sync after every mutation (Laravel's
    /// rescue()-wrapped after() hooks): failures warn, never roll back.
    func autoSyncToFile() {
        guard let path = configPath else { return }
        do { try engine.syncToFile(path: path, context: context) }
        catch { pendingError = "Saved, but writing the config file failed: \(error.localizedDescription)" }
    }

    func refreshConflicts() {
        guard let path = configPath else { return }
        conflicts = (try? detector.detect(path: path, context: context)) ?? []
    }

    func connect(_ host: String) {
        guard let url = URL(string: "ssh://\(host)") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyCommand(_ entry: HostEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.sshCommand, forType: .string)
    }

    func rawConfigText() -> String {
        guard let path = configPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "No config file found."
        }
        return text
    }
}
```

- [ ] **Step 2: Replace `App/Sources/SSHConfigApp.swift`**

```swift
import SwiftUI
import SwiftData
import SSHConfigCore

@main
struct SSHConfigApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(model)
                .onAppear { model.onLaunch() }
        }
        .modelContainer(AppModel.container)

        MenuBarExtra("SSH Config", systemImage: "terminal") {
            Text("SSH Config") // replaced in Task 14
        }
    }
}
```

- [ ] **Step 3: Create `App/Sources/Views/MainWindow.swift`**

```swift
import SwiftUI
import SwiftData
import SSHConfigCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntry.updatedAt, order: .reverse) private var hosts: [HostEntry]
    @State private var search = ""
    @State private var selection: PersistentIdentifier?

    private var filtered: [HostEntry] {
        guard !search.isEmpty else { return hosts }
        return hosts.filter {
            $0.host.localizedCaseInsensitiveContains(search)
                || ($0.properties.first("HostName") ?? "").localizedCaseInsensitiveContains(search)
                || ($0.properties.first("User") ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(filtered, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.host).font(.headline)
                    Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(entry.persistentModelID)
            }
            .searchable(text: $search, prompt: "Search hosts")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let selection, let entry = hosts.first(where: { $0.persistentModelID == selection }) {
                HostDetailView(entry: entry)
            } else {
                ContentUnavailableView("No Host Selected",
                                       systemImage: "server.rack",
                                       description: Text("Select a host, or press ⌘N to add one."))
            }
        }
        .navigationTitle("SSH Config")
        .alert("SSH Config", isPresented: .init(
            get: { model.pendingError != nil },
            set: { if !$0 { model.pendingError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.pendingError ?? "")
        }
    }

    private func subtitle(_ entry: HostEntry) -> String {
        let hostName = entry.properties.first("HostName") ?? "—"
        if let user = entry.properties.first("User") { return "\(user)@\(hostName)" }
        return hostName
    }
}
```

- [ ] **Step 4: Create `App/Sources/Views/HostDetailView.swift`**

```swift
import SwiftUI
import SSHConfigCore

struct HostDetailView: View {
    @Environment(AppModel.self) private var model
    let entry: HostEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.host).font(.largeTitle.bold())

                GroupBox("Connection") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        row("HostName", entry.properties.first("HostName"))
                        row("User", entry.properties.first("User"))
                        row("Port", entry.port)
                        row("IdentityFile", entry.properties.first("IdentityFile"))
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                let extras = entry.properties.filter { !HostFormData.coreKeys.contains($0.key.lowercased()) }
                if !extras.isEmpty {
                    GroupBox("Other Options") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                            ForEach(extras, id: \.key) { prop in
                                row(prop.key, prop.values.joined(separator: ", "))
                            }
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        model.copyCommand(entry)
                    } label: {
                        Label(entry.sshCommand, systemImage: "doc.on.doc").font(.body.monospaced())
                    }
                    .help("Copy the ssh command")

                    if entry.isConnectable {
                        Button {
                            model.connect(entry.host)
                        } label: {
                            Label("Connect", systemImage: "terminal")
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }

                if let raw = entry.rawBlock, !raw.isEmpty {
                    GroupBox("Raw Block (as last imported)") {
                        Text(raw)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
                Spacer()
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "—").textSelection(.enabled)
        }
    }
}
```

- [ ] **Step 5: Build**

Run: `tuist generate --no-open && tuist build SSHConfig`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Smoke test**

Run the built app (`open $(find build -name "SSHConfig.app" | head -1)` or via Xcode). Expected: window opens with empty sidebar and "No Host Selected" placeholder. Quit.

- [ ] **Step 7: Commit**

```bash
git add App
git commit -m "feat(app): app shell with host list and detail pane"
```

---

### Task 10: Host form sheet — create, edit, duplicate, delete (+ auto-sync)

**Files:**
- Create: `App/Sources/Views/HostFormSheet.swift`
- Modify: `App/Sources/Views/MainWindow.swift` (toolbar + sheet wiring + row context menu)

**Interfaces:**
- Consumes: `HostFormData` (Task 3), `AppModel.autoSyncToFile()` (Task 9).
- Produces: `HostFormSheet(mode: FormMode)` with `enum FormMode: Identifiable { case create; case edit(HostEntry); var id: String { ... } }`; MainWindow gains `@State private var formMode: FormMode?` plus toolbar (New ⌘N, Sync menu placeholder wired in Task 11) and per-row context menu (Edit / Duplicate / Delete).

- [ ] **Step 1: Create `App/Sources/Views/HostFormSheet.swift`**

```swift
import SwiftUI
import SwiftData
import SSHConfigCore

enum FormMode: Identifiable {
    case create
    case edit(HostEntry)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let entry): "edit-\(entry.host)"
        }
    }
}

struct HostFormSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let mode: FormMode
    @State private var form = HostFormData()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isCreate ? "New Host" : "Edit Host")
                .font(.title2.bold())
                .padding()

            Form {
                TextField("Host", text: $form.host, prompt: Text("myserver"))
                TextField("HostName", text: $form.hostName, prompt: Text("example.com"))
                TextField("User", text: $form.user, prompt: Text("root"))
                TextField("Port", text: $form.port, prompt: Text("22"))
                TextField("IdentityFile", text: $form.identityFile, prompt: Text("~/.ssh/id_ed25519"))

                Section("Other Options") {
                    ForEach(form.extras.indices, id: \.self) { i in
                        HStack {
                            TextField("Option", text: $form.extras[i].key, prompt: Text("ProxyJump"))
                                .frame(width: 160)
                            TextField("Value", text: valueBinding(i), prompt: Text("bastion"))
                            Button(role: .destructive) {
                                form.extras.remove(at: i)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        form.extras.append(SSHProperty(key: "", values: [""]))
                    } label: {
                        Label("Add Option", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Button("Save") { save() }.keyboardShortcut(.return).buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear {
            if case .edit(let entry) = mode { form = HostFormData(entry: entry) }
        }
    }

    private var isCreate: Bool { if case .create = mode { true } else { false } }

    private func valueBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { form.extras[i].values.first ?? "" },
            set: { form.extras[i].values = [$0] }
        )
    }

    private func save() {
        let others = (try? context.fetch(FetchDescriptor<HostEntry>())) ?? []
        var existingHosts = Set(others.map(\.host))
        if case .edit(let entry) = mode { existingHosts.remove(entry.host) }

        if let message = form.validationError(existingHosts: existingHosts) {
            error = message
            return
        }
        let host = form.host.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .create:
            context.insert(HostEntry(host: host, properties: form.properties(), rawBlock: nil))
        case .edit(let entry):
            entry.host = host
            entry.properties = form.properties()
            entry.updatedAt = .now
        }
        do {
            try context.save()
        } catch {
            self.error = error.localizedDescription
            return
        }
        model.autoSyncToFile()
        dismiss()
    }
}
```

- [ ] **Step 2: Wire into `App/Sources/Views/MainWindow.swift`**

Add state and toolbar. Insert `@State private var formMode: FormMode?` next to the other `@State` vars, then add these modifiers after `.navigationTitle("SSH Config")` (keep the existing `.alert`):

```swift
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    formMode = .create
                } label: {
                    Label("New Host", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(item: $formMode) { mode in
            HostFormSheet(mode: mode)
        }
```

And add a context menu + delete/duplicate handling to the sidebar list row. Replace the `List(filtered, selection: $selection) { entry in ... }` row content's closing with a `.contextMenu`, so the row becomes:

```swift
            List(filtered, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.host).font(.headline)
                    Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(entry.persistentModelID)
                .contextMenu {
                    Button("Edit") { formMode = .edit(entry) }
                    Button("Duplicate") { duplicate(entry) }
                    Divider()
                    Button("Delete", role: .destructive) { delete(entry) }
                }
            }
```

Add these methods to `MainWindow` (below `subtitle`):

```swift
    @Environment(\.modelContext) private var context

    /// Laravel's DuplicateSshConfigAction: unique "-copy-N" suffix, then sync.
    private func duplicate(_ entry: HostEntry) {
        let existing = Set(hosts.map(\.host))
        var newHost = entry.host
        var counter = 1
        while existing.contains(newHost) {
            newHost = "\(entry.host)-copy-\(counter)"
            counter += 1
        }
        context.insert(HostEntry(host: newHost, properties: entry.properties, rawBlock: nil))
        try? context.save()
        model.autoSyncToFile()
    }

    private func delete(_ entry: HostEntry) {
        if selection == entry.persistentModelID { selection = nil }
        context.delete(entry)
        try? context.save()
        model.autoSyncToFile()
    }
}
```

(`@Environment(\.modelContext)` goes with the other property declarations at the top of the struct, not below `subtitle`.)

Also add an Edit button to `HostDetailView`'s action row. In `HostDetailView.swift`, add a callback property after `let entry: HostEntry`:

```swift
    var onEdit: (HostEntry) -> Void = { _ in }
```

and add to the `HStack` of action buttons:

```swift
                    Button {
                        onEdit(entry)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
```

then in MainWindow's detail branch pass it:

```swift
                HostDetailView(entry: entry, onEdit: { formMode = .edit($0) })
```

- [ ] **Step 3: Build**

Run: `tuist generate --no-open && tuist build SSHConfig`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Smoke test**

Launch the app. Create a host `testbox` with HostName `example.com` → appears in sidebar; right-click → Duplicate → `testbox-copy-1` appears; right-click → Delete removes it. (No config path is set yet, so `autoSyncToFile()` silently no-ops — correct.)

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "feat(app): host create/edit/duplicate/delete with auto-sync"
```

---

### Task 11: Sync menu + results & conflicts sheet

**Files:**
- Create: `App/Sources/Views/SyncSheet.swift`
- Modify: `App/Sources/Views/MainWindow.swift` (Sync toolbar menu + sheet)

**Interfaces:**
- Consumes: `AppModel.runSync/syncItems/conflicts/showSyncSheet`, `resolver` (Tasks 7, 9).
- Produces: `SyncSheet` view; toolbar Sync menu with the three modes.

- [ ] **Step 1: Create `App/Sources/Views/SyncSheet.swift`**

```swift
import SwiftUI
import SSHConfigCore

struct SyncSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var renameTarget: Conflict?
    @State private var newName = ""
    @State private var keepBoth = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Results").font(.title2.bold())

            if let items = model.syncItems {
                if items.isEmpty {
                    Text("Everything is already in sync.").foregroundStyle(.secondary)
                } else {
                    List(items) { item in
                        Label(item.host, systemImage: icon(item.action))
                            .badge(label(item.action))
                    }
                    .frame(minHeight: 120)
                }
            }

            if !model.conflicts.isEmpty {
                Text("Conflicts").font(.headline)
                List(model.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(conflict.host).font(.body.monospaced().bold())
                            Text(sourceLabel(conflict.source))
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        diffText(conflict)
                        HStack {
                            if conflict.fileProperties != nil {
                                Button("Use File Version") { acceptFile(conflict) }
                            }
                            if conflict.source != .file {
                                Button("Rename…") {
                                    renameTarget = conflict
                                    newName = conflict.host
                                }
                            }
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 160)
                Text("Store-only hosts are written to the file on the next Sync To File / Sync Both.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.return).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .sheet(item: $renameTarget) { conflict in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename '\(conflict.host)'").font(.headline)
                TextField("New host name", text: $newName)
                Toggle("Keep both (duplicate under the new name)", isOn: $keepBoth)
                HStack {
                    Spacer()
                    Button("Cancel") { renameTarget = nil }
                    Button("Rename") {
                        try? model.resolver.rename(host: conflict.host, to: newName,
                                                   updateExisting: !keepBoth, context: context)
                        model.autoSyncToFile()
                        model.refreshConflicts()
                        renameTarget = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    private func acceptFile(_ conflict: Conflict) {
        try? model.resolver.acceptFileVersion(conflict, context: context)
        model.autoSyncToFile()
        model.refreshConflicts()
    }

    private func icon(_ action: SyncAction) -> String {
        switch action {
        case .created: "plus.circle"
        case .updated: "arrow.triangle.2.circlepath"
        case .addedToFile: "arrow.up.doc"
        }
    }

    private func label(_ action: SyncAction) -> String {
        switch action {
        case .created: "added to store"
        case .updated: "updated from file"
        case .addedToFile: "written to file"
        }
    }

    private func sourceLabel(_ source: Conflict.Source) -> String {
        switch source {
        case .both: "differs"
        case .store: "store only"
        case .file: "file only"
        }
    }

    @ViewBuilder
    private func diffText(_ conflict: Conflict) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let file = conflict.fileProperties {
                Text("file:  " + summary(file)).font(.caption.monospaced())
            }
            if let store = conflict.storeProperties {
                Text("store: " + summary(store)).font(.caption.monospaced())
            }
        }
        .foregroundStyle(.secondary)
    }

    private func summary(_ props: [SSHProperty]) -> String {
        props.map { "\($0.key)=\($0.values.joined(separator: ","))" }.joined(separator: " ")
    }
}
```

- [ ] **Step 2: Add the Sync menu to `MainWindow`'s toolbar**

Inside the existing `.toolbar { ... }`, add before the New Host item:

```swift
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    ForEach(SyncMode.allCases) { mode in
                        Button(mode.rawValue) { model.runSync(mode) }
                    }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
```

And after the `.sheet(item: $formMode)` modifier add:

```swift
        .sheet(isPresented: $model.showSyncSheet) {
            SyncSheet()
        }
```

(`$model` works because the body already starts with `@Bindable var model = model`.)

- [ ] **Step 3: Build**

Run: `tuist generate --no-open && tuist build SSHConfig`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Smoke test (uses a scratch config, NOT ~/.ssh/config)**

```bash
mkdir -p /tmp/sshconfig-smoke && printf 'Host filehost\n    User root\n' > /tmp/sshconfig-smoke/config
```

Launch the app. First-run sheet isn't built yet (Task 12) — set the path via defaults for now:
`defaults write dev.more.sshconfig sshConfigPath /tmp/sshconfig-smoke/config` (quit app first, relaunch).
Toolbar → Sync → Sync From File → sheet shows `filehost added to store`. Add a host `apponly` in the app → Sync → Sync Both → sheet shows `apponly written to file`; `cat /tmp/sshconfig-smoke/config` shows both hosts; a `config.backup.*` file exists.

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "feat(app): sync menu with results and conflict resolution sheet"
```

---

### Task 12: First-run sheet (config path setup)

**Files:**
- Create: `App/Sources/Views/FirstRunSheet.swift`
- Modify: `App/Sources/Views/MainWindow.swift` (present when `model.showFirstRun`)

**Interfaces:**
- Consumes: `AppModel.saveConfigPath(_:)`, `showFirstRun` (Task 9), `ConfigPathStore.defaultSuggestion` (Task 8).
- Produces: `FirstRunSheet` view.

- [ ] **Step 1: Create `App/Sources/Views/FirstRunSheet.swift`**

```swift
import SwiftUI
import SSHConfigCore

struct FirstRunSheet: View {
    @Environment(AppModel.self) private var model
    @State private var path = ConfigPathStore.defaultSuggestion
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("SSH Config Path", systemImage: "gearshape")
                .font(.title2.bold())
            Text("Setting your SSH config path is required to use this app. It tells SSH Config where your configuration file lives. If the file exists it will be backed up and imported.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Config path", text: $path, prompt: Text("~/.ssh/config"))
                .font(.body.monospaced())

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Save") {
                    error = model.saveConfigPath(path)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
```

- [ ] **Step 2: Present it from `MainWindow`**

After the `.sheet(isPresented: $model.showSyncSheet)` modifier add:

```swift
        .sheet(isPresented: $model.showFirstRun) {
            FirstRunSheet()
        }
```

- [ ] **Step 3: Build**

Run: `tuist generate --no-open && tuist build SSHConfig`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Smoke test**

`defaults delete dev.more.sshconfig sshConfigPath`, launch → first-run sheet appears; enter `/tmp/sshconfig-smoke/config` → sheet closes, hosts imported (from Task 11's scratch file); a new backup file appears beside it. Entering `relative/x` or `/nope/config` shows inline errors.

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "feat(app): first-run config path setup with backup and import"
```

---

### Task 13: Raw config viewer window

**Files:**
- Create: `App/Sources/Views/RawConfigView.swift`
- Modify: `App/Sources/SSHConfigApp.swift` (add `Window` scene)
- Modify: `App/Sources/Views/MainWindow.swift` (toolbar button to open it)

**Interfaces:**
- Consumes: `AppModel.rawConfigText()` (Task 9).
- Produces: window scene id `"raw-config"`.

- [ ] **Step 1: Create `App/Sources/Views/RawConfigView.swift`**

```swift
import SwiftUI

struct RawConfigView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.configPath ?? "No config path set")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    text = model.rawConfigText()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                Text(text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear { text = model.rawConfigText() }
    }
}
```

- [ ] **Step 2: Add the scene in `SSHConfigApp.swift`**

After the `WindowGroup { ... }.modelContainer(...)` scene add:

```swift
        Window("Raw Config", id: "raw-config") {
            RawConfigView().environment(model)
        }
        .defaultSize(width: 560, height: 480)
```

- [ ] **Step 3: Add a toolbar button in `MainWindow`**

Add `@Environment(\.openWindow) private var openWindow` to `MainWindow`'s properties, and inside `.toolbar { ... }`:

```swift
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    openWindow(id: "raw-config")
                } label: {
                    Label("Raw Config", systemImage: "doc.plaintext")
                }
            }
```

- [ ] **Step 4: Build + smoke test**

Run: `tuist generate --no-open && tuist build SSHConfig`
Expected: BUILD SUCCEEDED. Launch → toolbar Raw Config opens a monospaced window showing `/tmp/sshconfig-smoke/config`'s contents; Refresh re-reads after editing the file externally.

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "feat(app): raw config viewer window"
```

---

### Task 14: Menu bar extra

**Files:**
- Create: `App/Sources/Views/MenuBarView.swift`
- Modify: `App/Sources/SSHConfigApp.swift` (real MenuBarExtra content)

**Interfaces:**
- Consumes: `AppModel.connect/copyCommand/runSync` (Task 9), `HostEntry.isConnectable` (Task 3).
- Produces: menu bar menu with per-host submenu (Connect / Copy ssh command), Sync Both, Open SSH Config, Quit.

- [ ] **Step 1: Create `App/Sources/Views/MenuBarView.swift`**

```swift
import SwiftUI
import SwiftData
import SSHConfigCore

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \HostEntry.host) private var hosts: [HostEntry]

    var body: some View {
        if hosts.isEmpty {
            Text("No hosts yet")
        }
        ForEach(hosts) { entry in
            Menu(entry.host) {
                if entry.isConnectable {
                    Button("Connect") { model.connect(entry.host) }
                }
                Button("Copy ssh Command") { model.copyCommand(entry) }
            }
        }
        Divider()
        Button("Sync Both") { model.runSync(.both) }
        Button("Open SSH Config") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}
```

- [ ] **Step 2: Update `SSHConfigApp.swift`**

Give the main `WindowGroup` an id and use the real menu content. The full file becomes:

```swift
import SwiftUI
import SwiftData
import SSHConfigCore

@main
struct SSHConfigApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .environment(model)
                .onAppear { model.onLaunch() }
        }
        .modelContainer(AppModel.container)

        Window("Raw Config", id: "raw-config") {
            RawConfigView().environment(model)
        }
        .defaultSize(width: 560, height: 480)

        MenuBarExtra("SSH Config", systemImage: "terminal") {
            MenuBarView()
                .environment(model)
                .modelContainer(AppModel.container)
        }
    }
}
```

- [ ] **Step 3: Build + smoke test**

Run: `tuist generate --no-open && tuist build SSHConfig`
Expected: BUILD SUCCEEDED. Launch → terminal icon in the menu bar lists hosts; Copy ssh Command puts `ssh <host>` on the pasteboard (`pbpaste` to verify); Connect on a real host opens the default terminal via `ssh://`. Sync Both opens the main window's sheet after syncing.

- [ ] **Step 4: Commit**

```bash
git add App
git commit -m "feat(app): menu bar extra with connect and copy actions"
```

---

### Task 15: Wrap-up — README, full verification

**Files:**
- Create: `README.md`

**Interfaces:** none new.

- [ ] **Step 1: Create `README.md`**

```markdown
# SSH Config

Native macOS app for managing your SSH config file (`~/.ssh/config`).
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
```

- [ ] **Step 2: Full verification**

Run: `swift test && tuist generate --no-open && tuist build SSHConfig`
Expected: all tests pass, BUILD SUCCEEDED.

- [ ] **Step 3: End-to-end smoke (scratch config)**

With `/tmp/sshconfig-smoke/config` from Task 11: fresh defaults (`defaults delete dev.more.sshconfig sshConfigPath`), launch → first-run → set path → hosts import → edit a host → `cat` the file shows the change and a new backup → add `Match all` + `ForwardAgent yes` manually to the file → Sync From File → edit any host → `cat` shows the Match block still present. This proves the segment-preservation guarantee end to end.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README with build and test instructions"
```

- [ ] **Step 5: Point the app at the real config**

Ask the user before switching their live `~/.ssh/config` over (the first sync will back it up automatically, but it's their call).

---

## Self-Review Notes

- **Spec coverage:** parser fidelity (Task 2), store + model (Task 3), segment-preserving writer + 0600 (Task 4), backups w/ pruning (Task 5), 3 sync modes (Task 6), conflicts (Task 7), config path + first-run (Tasks 8, 12), main window/CRUD/duplicate/copy (Tasks 9–10), sync UI (Task 11), raw viewer (Task 13), menu bar + connect (Task 14). "Host * ordering caveat surfaced in the UI" is covered by the SyncSheet's store-only footnote (Task 11).
- **Known simplification vs spec:** extras rows support single-value editing in the form (multi-value keys imported from the file are preserved untouched unless the user edits that key; editing collapses to one value). Acceptable for v1; parity with Laravel, which didn't edit extras at all.
- **Type consistency check:** `RenderableHost` (writer) vs `HostEntry` (SwiftData) conversion happens only in `SyncEngine.syncToFile`. `PathValidation` replaces the invalid `Result<String, String>` sketch (see Task 8 Step 3 note).
