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
    #expect(TerminalRegistry.arguments(for: ghostty.launchPlan, host: "web") == ["-e", "ssh", "--", "web"])
    let kitty = TerminalRegistry.terminal(withId: "net.kovidgoyal.kitty")!
    #expect(TerminalRegistry.arguments(for: kitty.launchPlan, host: "db") == ["ssh", "--", "db"])
    let wez = TerminalRegistry.terminal(withId: "com.github.wez.wezterm")!
    #expect(TerminalRegistry.arguments(for: wez.launchPlan, host: "x") == ["start", "--", "ssh", "--", "x"])
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
