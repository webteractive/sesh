import Testing
import SwiftData
@testable import SSHConfigCore

@MainActor @Test func hostsFileEntryPersists() throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: HostsFileEntry.self, configurations: config)
    let ctx = ModelContext(container)
    ctx.insert(HostsFileEntry(ip: "142.93.199.41", hostnames: ["bundy.webteractive.co"],
                              note: "prod", isEnabled: false, sortOrder: 3))
    try ctx.save()

    let fetched = try ctx.fetch(FetchDescriptor<HostsFileEntry>())
    #expect(fetched.count == 1)
    #expect(fetched[0].sortOrder == 3)
    #expect(fetched[0].line == HostsLine(ip: "142.93.199.41", hostnames: ["bundy.webteractive.co"],
                                         note: "prod", isEnabled: false))
}
