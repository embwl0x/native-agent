import Testing
@testable import ChatOrchestration

// 2026-07-19 Continuum incident: "Look through my Continuum repo on GitHub —
// files, README, issues…" matched builder(hinted)+files(2 tokens)+github(1
// token) and the 2-group cap EVICTED github — the explicitly named service.
// Pins: a named-service group survives the cap ahead of lexical/hinted groups.
struct ToolPreloadHeuristicsNamedServiceTests {
    @Test func explicitlyNamedServiceSurvivesTheGroupCap() {
        let prediction = ToolPreloadHeuristics.predict(
            userMessage: "Look through my Continuum repo on GitHub — the files, the README, the issues — and tell me what it is",
            residentGroupHints: ["builder"]
        )
        let groups = prediction?.groupNames ?? []
        #expect(groups.contains("github"),
                "the user literally named GitHub — its tools must survive the group cap")
        // "files" also matches its own name token, so it is legitimately
        // "named" too and may rank first on richer pattern count. The
        // invariant is PRESENCE under the cap, not position: the incident
        // failure was github being EVICTED entirely.
        #expect(!groups.contains("builder") || groups.contains("github"),
                "a resident hint must never displace an explicitly named service")
    }

    @Test func namedServiceRankStillHonorsCapBound() {
        let prediction = ToolPreloadHeuristics.predict(
            userMessage: "Look through my Continuum repo on GitHub — the files, the README, the issues — and tell me what it is",
            residentGroupHints: ["builder"]
        )
        #expect((prediction?.groupNames.count ?? 99) <= ToolPreloadHeuristics.maxGroupsPerTurn)
    }
}
