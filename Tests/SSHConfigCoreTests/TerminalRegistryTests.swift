import Testing
@testable import SSHConfigCore

@Test func knownTerminalsAreSshURLCapableWithSystemDefaultFirst() {
    let ids = TerminalRegistry.known.map(\.id)
    #expect(ids.first == TerminalRegistry.systemDefaultId)
    #expect(Set(ids).count == ids.count)
    #expect(ids == ["system-default", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.more.zetty"])
    // Zetty is back as an ssh:// handler; argv-only terminals stay out.
    #expect(TerminalRegistry.terminal(withId: "dev.more.zetty")?.launchPlan == .sshURL)
    #expect(!ids.contains("com.mitchellh.ghostty"))
}

@Test func lookupByIdAndMiss() {
    #expect(TerminalRegistry.terminal(withId: "com.apple.Terminal")?.name == "Terminal")
    #expect(TerminalRegistry.terminal(withId: "nope") == nil)
}

@Test func launchPlansAreUrlBased() {
    #expect(TerminalRegistry.terminal(withId: "system-default")?.launchPlan == .systemDefault)
    #expect(TerminalRegistry.terminal(withId: "com.apple.Terminal")?.launchPlan == .sshURL)
}
