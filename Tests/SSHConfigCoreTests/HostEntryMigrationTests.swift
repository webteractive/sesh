import Testing
import SwiftData
@testable import SSHConfigCore

@MainActor @Test func newGroupFieldsHaveSchemaDefaults() throws {
    let ctx = try makeContext()
    let e = HostEntry(host: "legacy", properties: [], rawBlock: nil)
    ctx.insert(e)
    try ctx.save()
    let fetched = try ctx.fetch(FetchDescriptor<HostEntry>())
    #expect(fetched[0].groupName == nil)
    #expect(fetched[0].isDefaultProfile == false)
}

@MainActor @Test func displayNameDefaultsNil() throws {
    let ctx = try makeContext()
    let e = HostEntry(host: "web", properties: [], rawBlock: nil)
    ctx.insert(e); try ctx.save()
    #expect(try ctx.fetch(FetchDescriptor<HostEntry>())[0].displayName == nil)
}

@MainActor @Test func workspaceIDDefaultsNil() throws {
    let ctx = try makeContext()
    let e = HostEntry(host: "web", properties: [], rawBlock: nil)
    ctx.insert(e); try ctx.save()
    #expect(try ctx.fetch(FetchDescriptor<HostEntry>())[0].workspaceID == nil)
}
