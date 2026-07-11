import Testing
@testable import SSHConfigCore

@Test func copiesBaseConfigOverridesUserAndIdentity() {
    let base: [SSHProperty] = [
        SSHProperty(key: "HostName", values: ["10.0.0.5"]),
        SSHProperty(key: "Port", values: ["2222"]),
        SSHProperty(key: "User", values: ["admin"]),
        SSHProperty(key: "IdentityFile", values: ["~/.ssh/admin"]),
        SSHProperty(key: "ProxyJump", values: ["bastion"]),
    ]
    let p = ProfileFactory.make(baseProperties: base, baseAlias: "web",
                                label: "deploy", user: "deploy",
                                identityFile: "~/.ssh/deploy", existingAliases: ["web"])
    #expect(p.alias == "web-deploy")
    #expect(p.properties.first("HostName") == "10.0.0.5")
    #expect(p.properties.first("Port") == "2222")
    #expect(p.properties.first("ProxyJump") == "bastion")
    #expect(p.properties.first("User") == "deploy")
    #expect(p.properties.first("IdentityFile") == "~/.ssh/deploy")
    // base's admin/identity must NOT leak through
    #expect(p.properties.filter { $0.key.caseInsensitiveCompare("User") == .orderedSame }.count == 1)
}

@Test func aliasCollisionGetsNumericSuffix() {
    let p = ProfileFactory.make(baseProperties: [], baseAlias: "web", label: "deploy",
                                user: "deploy", identityFile: nil,
                                existingAliases: ["web", "web-deploy", "web-deploy-2"])
    #expect(p.alias == "web-deploy-3")
}

@Test func labelSanitisedToAliasCharset() {
    let p = ProfileFactory.make(baseProperties: [], baseAlias: "web", label: "Ops Team!",
                                user: "ops", identityFile: nil, existingAliases: [])
    #expect(p.alias == "web-Ops-Team")
}

@Test func emptyIdentityOmitsKey() {
    let p = ProfileFactory.make(baseProperties: [], baseAlias: "web", label: "x",
                                user: "x", identityFile: "", existingAliases: [])
    #expect(p.properties.first("IdentityFile") == nil)
    #expect(p.properties.first("User") == "x")
}

@Test func producesSafeAliasFromUnsafeBase() {
    let p = ProfileFactory.make(baseProperties: [], baseAlias: "evil;touch$(id)", label: "x",
                                user: "x", identityFile: nil, existingAliases: [])
    #expect(HostValidation.isSafeToLaunch(p.alias) == true)
    for badChar in [";", "$", "(", ")"] {
        #expect(!p.alias.contains(badChar))
    }
}

@Test func sanitizesNonASCIILabel() {
    let p = ProfileFactory.make(baseProperties: [], baseAlias: "web", label: "café日本語",
                                user: "x", identityFile: nil, existingAliases: [])
    #expect(HostValidation.isSafeToLaunch(p.alias) == true)
}
