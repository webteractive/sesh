import Testing
@testable import SSHConfigCore

@Test func hostValidationAcceptsSafeAliases() {
    #expect(HostValidation.isSafeToLaunch("web"))
    #expect(HostValidation.isSafeToLaunch("web.example.com"))
    #expect(HostValidation.isSafeToLaunch("user_box-1"))
}

@Test func hostValidationRejectsUnsafeAliases() {
    #expect(!HostValidation.isSafeToLaunch(""))
    #expect(!HostValidation.isSafeToLaunch("evil;touch$(id)"))
    #expect(!HostValidation.isSafeToLaunch("-oProxyCommand=x"))
    #expect(!HostValidation.isSafeToLaunch("a b"))
    #expect(!HostValidation.isSafeToLaunch("web!"))
}
