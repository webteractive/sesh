import Testing
import Foundation
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

@Test func emptyAndMissingInput() throws {
    #expect(parser.parse("").isEmpty)
    #expect(try parser.parseFile(at: "/nonexistent/path/config").isEmpty)
}

@Test func latin1ConfigFileParsesInsteadOfEmptying() throws {
    // 0xE9 is 'é' in Latin-1 but is not valid standalone UTF-8, so a naive
    // UTF-8-only decode fails; the file must not be treated as unreadable
    // (and thus empty) just because it's an old Latin-1-encoded config.
    var bytes = Array("# caf".utf8)
    bytes.append(0xE9)
    bytes.append(contentsOf: Array(" note\n\nHost web\n    User root\n".utf8))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/config"
    try Data(bytes).write(to: URL(fileURLWithPath: path))

    let segs = try parser.parseFile(at: path)

    #expect(!segs.isEmpty)
    #expect(parser.hosts(in: segs).map(\.pattern) == ["web"])
}

@Test func parsesCRLFInput() {
    let segs = parser.parse("Host web\r\n    User root\r\n")
    let hosts = parser.hosts(in: segs)
    #expect(hosts[0].pattern == "web")
    #expect(hosts[0].properties.first("User") == "root")
}

@Test func includeInsideMatchStaysInRawText() {
    let segs = parser.parse("""
    Match host *.internal
        Include ~/.ssh/extra
        ProxyJump bastion
    """)
    let matchSegments = segs.compactMap { seg -> String? in
        if case .matchBlock(let text) = seg { return text } else { return nil }
    }
    #expect(matchSegments.count == 1)
    #expect(matchSegments[0].contains("Include ~/.ssh/extra"))
    let hasIncludeSegment = segs.contains { if case .include = $0 { return true } else { return false } }
    #expect(!hasIncludeSegment)
}

@Test func trailingCommentAfterMatchBlockBecomesCommentSegment() {
    let segs = parser.parse("""
    Match host *.internal
        ProxyJump bastion
    # note
    """)
    guard case .matchBlock(let text) = segs.first(where: { if case .matchBlock = $0 { return true } else { return false } }) else {
        Issue.record("expected matchBlock"); return
    }
    #expect(!text.contains("# note"))
    let hasComment = segs.contains { if case .comment(let t) = $0 { return t.contains("# note") } else { return false } }
    #expect(hasComment)
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
