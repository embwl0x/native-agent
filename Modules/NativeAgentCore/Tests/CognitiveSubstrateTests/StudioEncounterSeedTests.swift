import Foundation
import PersistenceCore
import Testing
@testable import CognitiveSubstrate

/// Desk 903 phase 1 — "Pressure-minted encounters."
///
/// "Pressure decides WHEN, intake decides WHAT. A seed mints only when an
/// unattended artifact is already in reach. No intake, no encounter. A due dream
/// beats an encounter for the same pressure; encounters never preempt."
@Suite("Pressure-minted studio encounters")
struct StudioEncounterSeedTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func substrate() -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                thoughtSeedsEnabled: true,
                maximumActiveNodes: 32
            ),
            dependencies: CognitiveSubstrateDependencies(
                now: { self.t0 }, makeUUID: { UUID() }, userName: { "" }
            )
        )
    }

    /// The load-bearing rule. Checked before pressure is even read, so an
    /// encounter can never be generated out of a feeling that it is time for one.
    @Test("no intake, no seed — at any pressure")
    func emptyIntakeNeverMints() async {
        let s = substrate()
        for pressure in [0.0, 0.5, 0.99, 1.0] {
            let decision = await s.mintStudioEncounterSeed(
                intake: [], pressure: pressure, dreamIsDue: false
            )
            #expect(decision.outcome == .noIntake)
            #expect(decision.seedID == nil)
        }
        #expect(await s.thoughtSeedSnapshot().isEmpty)
    }

    @Test("a due dream outranks an encounter at the same pressure")
    func dueDreamOutranks() async {
        let s = substrate()
        let decision = await s.mintStudioEncounterSeed(
            intake: [candidate(source: .named)], pressure: 0.95, dreamIsDue: true
        )
        #expect(decision.outcome == .dreamOutranks)
        #expect(await s.thoughtSeedSnapshot().isEmpty)
    }

    @Test("below the floor nothing mints even with something in reach")
    func belowPressureNeverMints() async {
        let s = substrate()
        let decision = await s.mintStudioEncounterSeed(
            intake: [candidate(source: .named)],
            pressure: CognitiveSubstrate.studioEncounterPressureFloor - 0.01,
            dreamIsDue: false
        )
        #expect(decision.outcome == .belowPressure)
    }

    @Test("with pressure and something in reach, one seed mints")
    func mintsOneSeed() async {
        let s = substrate()
        let decision = await s.mintStudioEncounterSeed(
            intake: [candidate(source: .named, reference: "/tmp/cover-a.png", originID: "consult_1")],
            pressure: 0.8,
            dreamIsDue: false
        )
        #expect(decision.outcome == .minted)
        #expect(decision.candidate?.source == .named)
        let seeds = await s.thoughtSeedSnapshot()
        #expect(seeds.count == 1)
        // ENCOUNTERS NEVER PREEMPT: `.openQuestion` carries the lowest
        // interruption boost of the four kinds, and the priority is capped well
        // under a pinned concern's 1.0.
        #expect(seeds.first?.kind == .openQuestion)
        #expect((seeds.first?.priority ?? 1) <= CognitiveSubstrate.studioEncounterMaximumPriority)
        // It states what is there. It does not instruct, and it does not nag.
        let text = seeds.first?.text ?? ""
        #expect(text.contains("/tmp/cover-a.png"))
        #expect(!text.lowercased().contains("you haven't"))
        #expect(!text.lowercased().contains("should"))
    }

    /// An encounter seed ranks below every kind that carries real urgency, so a
    /// live anomaly is always the more interrupting thought.
    @Test("an encounter never outranks an anomaly already waiting")
    func encounterRanksBelowAnAnomaly() async {
        let s = substrate()
        _ = await s.addThoughtSeed(kind: .anomaly, text: "The build broke twice in a row.", priority: 0.6)
        _ = await s.mintStudioEncounterSeed(
            intake: [candidate(source: .named)], pressure: 0.6, dreamIsDue: false
        )
        let suggestions = await s.thoughtSuggestionSnapshot(limit: 5, minimumInterruptionScore: 0)
        #expect(suggestions.count == 2)
        #expect(suggestions.first?.kind == .anomaly,
                "an invitation to look at something never preempts a live anomaly")
    }

    /// User's invitations come first — they are the only source where a person
    /// deliberately put something in front of her. Then the oldest thing still
    /// sitting there. No scoring: this is a queue, not a ranking of works.
    @Test("User's invitation is taken before anything else in reach")
    func namedSourceWinsThenAge() {
        let picked = CognitiveSubstrate.selectEncounter(from: [
            candidate(source: .unjournaledWork, originID: "w_old", noticedAt: "2026-01-01T00:00:00Z"),
            candidate(source: .named, originID: "c_new", noticedAt: "2026-09-01T00:00:00Z"),
            candidate(source: .named, originID: "c_old", noticedAt: "2026-08-01T00:00:00Z"),
        ])
        #expect(picked?.originID == "c_old")
    }

    /// The seam that must stay a seam: nothing in this build produces
    /// `crossedTheScreen`, but the ranking already knows where it sits, so the
    /// screen lane can be added without reopening this law.
    @Test("the crossed-the-screen source ranks between the other two")
    func crossedTheScreenSeamIsRanked() {
        let picked = CognitiveSubstrate.selectEncounter(from: [
            candidate(source: .unjournaledWork, originID: "w"),
            candidate(source: .crossedTheScreen, originID: "s"),
        ])
        #expect(picked?.originID == "s")
    }

    // MARK: - Fixtures

    private func candidate(
        source: StudioEncounterCandidate.Source,
        title: String? = nil,
        reference: String? = "/tmp/thing.png",
        originID: String = "origin",
        noticedAt: String = "2026-09-01T12:00:00.000000Z"
    ) -> StudioEncounterCandidate {
        StudioEncounterCandidate(
            source: source,
            title: title,
            creator: nil,
            reference: reference,
            originID: originID,
            noticedAt: noticedAt
        )
    }
}
