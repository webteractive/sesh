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

@Test func formPreservesMultiValueCoreProperties() {
    let entry = HostEntry(host: "web", properties: [
        SSHProperty(key: "IdentityFile", values: ["~/.ssh/a", "~/.ssh/b"]),
    ], rawBlock: nil)
    let form = HostFormData(entry: entry)
    #expect(form.identityFile == "~/.ssh/a")
    #expect(form.extras == [SSHProperty(key: "IdentityFile", values: ["~/.ssh/b"])])

    let allIdentityFileValues = form.properties()
        .filter { $0.key.caseInsensitiveCompare("IdentityFile") == .orderedSame }
        .flatMap(\.values)
    #expect(allIdentityFileValues == ["~/.ssh/a", "~/.ssh/b"])
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
