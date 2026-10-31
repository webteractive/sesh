import Testing
import Darwin
import Foundation
@testable import SSHConfigCore

private let hosts = [
    ControlRefs.HostCandidate(alias: "web", groupKey: "web", displayName: "Web Server"),
    ControlRefs.HostCandidate(alias: "db", groupKey: "db", displayName: "Database"),
    ControlRefs.HostCandidate(alias: "db-ro", groupKey: "db", displayName: "Database"),
    ControlRefs.HostCandidate(alias: "Api", groupKey: "Api", displayName: "Shared"),
    ControlRefs.HostCandidate(alias: "api-2", groupKey: "api-2", displayName: "Shared"),
]

@Test func hostRefsResolveByAliasGroupAndName() throws {
    #expect(try ControlRefs.hostKey("db-ro", in: hosts).get() == "db")
    #expect(try ControlRefs.hostKey("db", in: hosts).get() == "db")
    #expect(try ControlRefs.hostKey("web server", in: hosts).get() == "web")
    #expect(try ControlRefs.hostKey("api", in: hosts).get() == "Api")
}

@Test func hostRefsReportMissingAndAmbiguousNames() throws {
    #expect(throws: ControlFailure.self) { try ControlRefs.hostKey("nope", in: hosts).get() }
    let shared = ControlRefs.hostKey("shared", in: hosts)
    guard case .failure(let failure) = shared else { Issue.record("expected ambiguity"); return }
    #expect(failure.code == .ambiguous)
}

@Test func hostsEntryRefsResolveByIdPrefixAndHostname() throws {
    let a = UUID(uuidString: "0A1B2C3D-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "0A1B9999-0000-0000-0000-000000000002")!
    let entries = [(id: a, hostnames: ["api.test"]), (id: b, hostnames: ["web.test", "API.TEST"])]
    #expect(try ControlRefs.hostsEntryID(a.uuidString, in: entries).get() == a)
    #expect(try ControlRefs.hostsEntryID("0a1b2c", in: entries).get() == a)
    #expect(try ControlRefs.hostsEntryID("web.test", in: entries).get() == b)
    // Too short to be an id prefix, and two entries map the hostname.
    for ref in ["0a1", "0a1b", "api.test"] {
        guard case .failure = ControlRefs.hostsEntryID(ref, in: entries) else {
            Issue.record("\(ref) should not resolve"); continue
        }
    }
}

@Test func workspaceRefsIgnoreCase() throws {
    let id = UUID()
    #expect(try ControlRefs.workspaceID("clients", in: [(id: id, name: "Clients")]).get() == id)
    #expect(throws: ControlFailure.self) { try ControlRefs.workspaceID("other", in: [(id: id, name: "Clients")]).get() }
}

@Test func optionsParseAndRefuseWhatCantGoUnderAHost() throws {
    #expect(try ControlRefs.option("ServerAliveInterval=60").get() == SSHProperty(key: "ServerAliveInterval", values: ["60"]))
    #expect(try ControlRefs.option("ProxyJump bastion").get() == SSHProperty(key: "ProxyJump", values: ["bastion"]))
    for bad in ["NoValue", "Key=", "Match=exec evil", "Include=/tmp/x", "User=root", "HostName=x", "Bad-Key=1",
                "LocalCommand=a\nHost *"] {
        guard case .failure = ControlRefs.option(bad) else { Issue.record("\(bad) should be refused"); continue }
    }
}

@Test func commandsRoundTripThroughJSON() throws {
    let commands: [ControlCommand] = [
        .status,
        .addHost(HostSpec(name: "My Server", hostname: "1.2.3.4", user: "root", port: "2200",
                          options: [SSHProperty(key: "ServerAliveInterval", values: ["60"])], workspace: "Work")),
        .editHost(ref: "web", changes: HostChanges(name: "Web", profile: ProfileChanges(port: "", removeOptions: ["ProxyJump"]))),
        .moveHosts(refs: ["a", "b"], workspace: nil),
        .moveWorkspace(ref: "Work", placement: .onto("Home")),
        .setHostsEntries(refs: ["api.test"], enabled: false),
        .importArchive(SeshArchive(sshHosts: [], hostsEntries: [], exportedAt: Date(timeIntervalSince1970: 0))),
    ]
    for command in commands {
        let data = try ControlProtocol.encoder().encode(ControlRequest(command))
        let decoded = try ControlProtocol.decoder().decode(ControlRequest.self, from: data)
        #expect(decoded.command == command)
        #expect(decoded.version == ControlProtocol.version)
    }
}

@Test func responsesCarryAResultOrAnError() throws {
    let ok = try ControlProtocol.encoder().encode(ControlResponse(result: ActionResult("Done.", added: 2)))
    #expect(try ControlProtocol.decoder().decode(ControlResponse<ActionResult>.self, from: ok).result?.added == 2)
    let failed = try ControlProtocol.encoder().encode(ControlResponse<Int>(error: ControlFailure(.conflict, "Taken.")))
    let decoded = try ControlProtocol.decoder().decode(ControlResponse<ActionResult>.self, from: failed)
    #expect(decoded.result == nil)
    #expect(decoded.error == ControlFailure(.conflict, "Taken."))
}

@Test func socketExchangesOneMessageEachWay() throws {
    // Deep enough to exceed a socket address, which the socket must cope with.
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "sesh-control-test-\(UUID().uuidString)/" + String(repeating: "deep/", count: 16))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let path = dir.appending(path: "control.sock").path
    #expect(path.utf8.count > 104)

    #expect(throws: ControlSocketError.unreachable) { try ControlSocket.exchange(Data("hi".utf8), path: path) }

    let listener = try ControlSocket.listen(path: path)
    defer { close(listener) }
    var info = stat()
    #expect(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    let server = Thread {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        guard ControlSocket.peerIsCurrentUser(client), let request = try? ControlSocket.readAll(client) else { return }
        try? ControlSocket.writeAll(client, Data(request.reversed()))
    }
    server.start()
    let reply = try ControlSocket.exchange(Data("hello".utf8), path: path)
    #expect(String(decoding: reply, as: UTF8.self) == "olleh")
}

@Test func installScriptQuotesPathsAndNeverReplacesAFile() {
    let script = CommandLineInstall.privilegedLinkScript(target: #"/Apps/Se"sh\.app/Contents/Helpers/sesh"#)
    #expect(script.contains(#"set t to quoted form of "/Apps/Se\"sh\\.app/Contents/Helpers/sesh""#))
    #expect(script.contains("[ -L \" & l & \" ] || exit 3"))
    #expect(script.contains("with administrator privileges"))
}

@Test func installStateTellsALinkFromAFile() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sesh-install-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let link = dir.appending(path: "sesh").path
    #expect(CommandLineInstall.state(link: link, target: "/A/sesh") == .notInstalled)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/A/sesh")
    #expect(CommandLineInstall.state(link: link, target: "/A/sesh") == .installed)
    #expect(CommandLineInstall.state(link: link, target: "/B/sesh") == .linkedElsewhere("/A/sesh"))
    try FileManager.default.removeItem(atPath: link)
    FileManager.default.createFile(atPath: link, contents: Data())
    #expect(CommandLineInstall.state(link: link, target: "/A/sesh") == .blocked)
}
