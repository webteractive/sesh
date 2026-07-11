import Testing
@testable import SSHConfigCore

@Test func emptyQueryMatchesEverythingAtZero() {
    #expect(FuzzyMatcher.score("", in: "anything") == 0)
}

@Test func subsequenceHitAndMiss() {
    #expect(FuzzyMatcher.score("wb", in: "web-box") != nil)
    #expect(FuzzyMatcher.score("xyz", in: "web-box") == nil)
}

@Test func caseInsensitive() {
    #expect(FuzzyMatcher.score("WEB", in: "web") == FuzzyMatcher.score("web", in: "WEB"))
    #expect(FuzzyMatcher.score("WEB", in: "web") != nil)
}

@Test func rankingPrefersExactThenBoundaryThenScattered() {
    let exact = FuzzyMatcher.score("web", in: "web")!
    let boundary = FuzzyMatcher.score("web", in: "my-web-box")!
    let scattered = FuzzyMatcher.score("web", in: "workbench-eb")!
    #expect(exact > boundary)
    #expect(boundary > scattered)
}
