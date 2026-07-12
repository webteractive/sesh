import Testing
@testable import SSHConfigCore

private func term(_ id: String, _ name: String) -> Terminal {
    Terminal(id: id, name: name, launchPlan: .sshURL)
}

@Test func systemDefaultIsTheSyntheticEntry() {
    #expect(TerminalRegistry.systemDefault.id == TerminalRegistry.systemDefaultId)
    #expect(TerminalRegistry.systemDefault.launchPlan == .systemDefault)
}

@Test func displayNameUsesOverrideThenFallback() {
    // The zetty bundle's own name is lowercase; we prettify it.
    #expect(TerminalRegistry.displayName(forBundleId: "co.webteractive.zetty", fallback: "zetty") == "Zetty")
    // Unknown apps keep whatever LaunchServices reports.
    #expect(TerminalRegistry.displayName(forBundleId: "com.example.newterm", fallback: "NewTerm") == "NewTerm")
}

@Test func sortPutsKnownTerminalsFirstThenAlphabetical() {
    let sorted = TerminalRegistry.sortForDisplay([
        term("com.example.zzz", "Zzz Term"),
        term("co.webteractive.zetty", "Zetty"),
        term("com.example.aaa", "Aaa Term"),
        term("com.apple.Terminal", "Terminal"),
    ])
    // Known ones lead in preferredOrder; unknowns trail, alphabetical by name.
    #expect(sorted.map(\.id) == [
        "com.apple.Terminal",
        "co.webteractive.zetty",
        "com.example.aaa",
        "com.example.zzz",
    ])
}
