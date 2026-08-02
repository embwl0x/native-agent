import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// COGNITION STEP 1 (APPRAISAL) acceptance — D-1 / D-2 / H3, 2026-08-02.
//
// Measured defect these pin (appraisal-gap-analysis-v2.md, her live store, 256
// felt nodes over four weeks):
//   · 26 of 40 feltResolution nodes were the SAME sentence, about a provider
//     path. Her anticipation layer bracketed and resolved on her own plumbing.
//   · `appraisalConcernLexicon()` (now `appraisalConcerns()`) was a hardcoded six-entry array. The concerns
//     that generated her feelings were not hers.
//   · `systemMarkers` substring-matched bare nouns against the USER'S message,
//     so "remind me about the doctor" classified User's turn `.system` — and
//     `.system` nodes are excluded from mood, felt memory, capsule, attention.
//
// The success metric for D-2 is FEWER FELT NODES. `signalToNoiseOnARealisticStream`
// measures it rather than asserting it.
@Suite("AppraisalStakes")
struct AppraisalStakesTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func makeSubstrate(_ clock: Clock, userName: String = "User") -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                maximumActiveNodes: 256),
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() },
                makeUUID: { UUID() },
                userName: { userName }
            )
        )
    }

    /// Seeds ACTIVE standing views through the real restore path — the same
    /// function a restart uses — so nothing test-only leaks into production.
    private func seedActiveViews(
        _ substrate: CognitiveSubstrate,
        _ views: [(title: String, body: String, evidence: Int)],
        at now: Date
    ) async {
        let payloads = views.map { spec in
            CognitiveStandingView(
                id: UUID(),
                title: spec.title,
                body: spec.body,
                status: .active,
                moodValenceAtFormation: 0.3,
                evidenceNodeIds: (0..<spec.evidence).map { _ in UUID() },
                createdAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-3_600),
                lineageId: "lineage-\(spec.title.prefix(12))"
            ).toJSON()
        }
        await substrate.restoreStandingViews(from: payloads)
    }

    /// The felt-resolution event exactly as `NativeCognitionRuntime`
    /// `.drainFeltResolutionsIntoSubstrate` composes it: distinct id per felt
    /// moment, the resolved organ in `subject.id`, the prediction path kind in
    /// `subject.label`, feltValence/feltArousal/resolutionKind in metadata.
    private func feltResolution(
        organ: String,
        pathKind: OrganismPredictionKind,
        relief: Bool = true,
        magnitude: Double = 0.5,
        at now: Date
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: UUID().uuidString,
            kind: .organismResolutionFelt,
            subject: CognitiveSubjectReference(
                type: "organism_path",
                id: "\(organ)#\(UUID().uuidString.prefix(8))",
                label: pathKind.rawValue
            ),
            sourceClass: .observed,
            occurredAt: now,
            summary: relief
                ? "Relief — the \(organ) path I was braced for landed fine."
                : "Disappointment — the \(organ) path I was counting on fell through.",
            importance: 0.65,
            metadata: [
                "feltValence": .double(relief
                    ? min(0.6, 0.2 + 0.5 * magnitude)
                    : -min(0.6, 0.2 + 0.6 * magnitude)),
                "feltArousal": .double(relief ? 0.15 : 0.45),
                "resolutionKind": .string(relief ? "relief" : "disappointment"),
            ]
        )
    }

    private func feltNodeCount(_ substrate: CognitiveSubstrate) async -> Int {
        await substrate.snapshot().nodes.filter { $0.kind == .feltResolution }.count
    }

    // MARK: - D-1: the concerns come from HER

    /// A fresh install still feels something: with no standing views, the concern
    /// set IS the shipped six, unchanged, and the relationship concern still
    /// splices the configured name. The floor is the floor.
    @Test func freshInstallFallsBackToTheShippedFloor() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock, userName: "Ada")

        let concerns = await s.appraisalConcerns()
        #expect(concerns.allSatisfy { $0.origin == .floor })
        #expect(Set(concerns.map(\.name)) == [
            "relationship", "truth", "followThrough", "repair", "learning", "userCare",
        ])
        let relationship = try #require(concerns.first { $0.name == "relationship" })
        #expect(relationship.keywords.contains("ada"))
        // No lived concern exists, so nothing can outrank the floor.
        #expect(await s.livedConcernHit(in: "anything at all") == false)
    }

    /// A concern she formed by LIVING outranks a shipped default. This is D-1's
    /// whole claim, stated as an inequality on weights.
    @Test func livedConcernsOutweighShippedDefaults() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await seedActiveViews(s, [(
            title: "Releases break on the oauth handshake",
            body: "The anthropic oauth credential refresh is what actually strands our releases.",
            evidence: 6
        )], at: clock.now())

        let concerns = await s.appraisalConcerns()
        let lived = concerns.filter { $0.origin == .lived }
        #expect(lived.count == 1, "one active view → one lived concern")

        let heaviestFloor = try #require(concerns.filter { $0.origin == .floor }.map(\.weight).max())
        let livedWeight = try #require(lived.first?.weight)
        #expect(livedWeight > heaviestFloor,
                "a concern she formed must weigh more than one that shipped")
        #expect(livedWeight <= CognitiveSubstrate.appraisalLivedConcernMaximumWeight)

        // The concern is made of HER words, bounded and distinctive.
        let terms = try #require(lived.first?.keywords)
        #expect(terms.count <= CognitiveSubstrate.appraisalLivedConcernTermCap)
        #expect(terms.contains("anthropic") || terms.contains("credential") || terms.contains("releases"))
        #expect(terms.allSatisfy { $0.count >= CognitiveSubstrate.appraisalLivedConcernMinimumTermLength })
        #expect(terms.allSatisfy { !CognitiveSubstrate.appraisalConcernStopWords.contains($0) })
    }

    /// Bounded: the lived set can never outgrow its cap, and derivation is pure —
    /// the same state yields the same concerns.
    @Test func livedConcernsAreBoundedAndDeterministic() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let specs = (0..<20).map { i in
            (title: "Settled view number \(i)",
             body: "Distinctive\(i) principle about deliberate verification discipline.",
             evidence: 3)
        }
        await seedActiveViews(s, specs, at: clock.now())

        let first = await s.appraisalConcerns()
        let second = await s.appraisalConcerns()
        #expect(first == second, "concern derivation must be pure")
        let lived = first.filter { $0.origin == .lived }
        #expect(lived.count <= CognitiveSubstrate.appraisalLivedConcernCap)
    }

    /// A view whose text is entirely stopwords/short words contributes NOTHING
    /// rather than an empty concern that would match every string on earth.
    @Test func aViewWithNoDistinctiveTermsContributesNoConcern() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await seedActiveViews(s, [(
            title: "it is what it is",
            body: "that is the same as this and they were with them",
            evidence: 2
        )], at: clock.now())

        let lived = await s.appraisalConcerns().filter { $0.origin == .lived }
        #expect(lived.isEmpty)
        #expect(await s.livedConcernHit(in: "provider-anthropic-oauth-direct") == false)
    }

    // MARK: - D-2: appraise against STAKES, not event class

    /// THE headline defect. A mechanical infrastructure success — the provider
    /// path she has no view about, a tool call completing — touches no concern
    /// she holds, so it produces NO felt resolution at all. Not a quieter node:
    /// no node.
    @Test func mechanicalInfrastructureSuccessProducesNoFeltResolution() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        let mechanical: [(String, OrganismPredictionKind)] = [
            ("provider-anthropic-oauth-direct", .providerCompletion),
            ("tool-grep", .toolCompletion),
            ("tool-git-log", .toolCompletion),
            ("tool-tool-catalog", .toolCompletion),
            ("phone-72f1a9", .phoneDelivery),
        ]
        for (organ, kind) in mechanical {
            let e = feltResolution(organ: organ, pathKind: kind, at: clock.now())
            #expect(await s.feltResolutionIsAtStake(e) == false, "\(organ) is machinery, not stake")
            let admitted = await s.ingestResident(e)
            #expect(admitted == false, "\(organ) must not be admitted")
            clock.advance(60)
        }
        #expect(await feltNodeCount(s) == 0, "26 relief nodes about plumbing become zero")
    }

    /// FAIL-CLOSED (gpt-5.5 review B1, 2026-08-02). Gate 1 is an ALLOWLIST of
    /// two stake-bearing kinds, not a denylist of the three mechanical ones. A
    /// label that is merely NOT `toolCompletion`/`providerCompletion`/
    /// `phoneDelivery` — a typo (`provider_completion`), a raw-value drift
    /// (`tool_completion`), a mechanical kind invented after this was written
    /// (`calendarDelivery`), an empty label, garbage — used to walk straight
    /// past D-2 and mint exactly the noise the gate exists to stop, under a
    /// different name. Each of these must now require a lived-concern hit,
    /// and with no active views there is none.
    @Test func unknownAndMisspelledPathLabelsDoNotBypassTheGate() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        let bypassAttempts = [
            "provider_completion",       // underscore typo of a real kind
            "tool_completion",
            "providerCompletionn",       // fat-fingered
            "calendarDelivery",          // a mechanical kind that does not exist YET
            "syncCompletion",
            "",                          // absent label
            "   ",                       // whitespace-only label
            "unknown",
            "approvalResolution ",       // trailing space is trimmed → still passes; see below
        ]
        for label in bypassAttempts {
            let base = feltResolution(
                organ: "provider-anthropic-oauth-direct", pathKind: .providerCompletion, at: clock.now())
            let e = CognitiveEvent(
                id: UUID().uuidString,
                kind: .organismResolutionFelt,
                subject: CognitiveSubjectReference(
                    type: "organism_path", id: base.subject.id, label: label),
                sourceClass: .observed,
                occurredAt: clock.now(),
                summary: base.summary,
                importance: 0.65,
                metadata: base.metadata
            )
            let expected = label.trimmingCharacters(in: .whitespacesAndNewlines) == "approvalResolution"
            #expect(await s.feltResolutionIsAtStake(e) == expected,
                    "label \"\(label)\" must not bypass the stake gate")
            #expect(await s.ingestResident(e) == expected)
            clock.advance(60)
        }
        #expect(await feltNodeCount(s) == 1, "only the genuine approvalResolution label lands")
    }

    /// The other half of the same gate: a REAL stake still lands. A commitment
    /// resolving, an approval User had to give, work she cared about failing —
    /// each of these has a person or a promise on the other end.
    @Test func realStakesStillProduceFeltResolutions() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        // A commitment moving — a person and a promise are implicated.
        let commitment = feltResolution(
            organ: "desk-ship-the-release", pathKind: .workflowAdvance, at: clock.now())
        #expect(await s.feltResolutionIsAtStake(commitment))
        #expect(await s.ingestResident(commitment))

        clock.advance(120)
        // An approval gate resolving — User had to walk through it.
        let approval = feltResolution(
            organ: "approval-autonomy-promotion", pathKind: .approvalResolution, at: clock.now())
        #expect(await s.feltResolutionIsAtStake(approval))
        #expect(await s.ingestResident(approval))

        clock.advance(120)
        // Work she cared about FAILING — a commitment falling through.
        let failure = feltResolution(
            organ: "desk-ship-the-release", pathKind: .workflowAdvance,
            relief: false, magnitude: 0.4, at: clock.now())
        #expect(await s.feltResolutionIsAtStake(failure))
        #expect(await s.ingestResident(failure))

        #expect(await feltNodeCount(s) == 3, "what she actually holds still lands")
    }

    /// The gate is HERS, not a hardcoded allow-list: once she has settled a view
    /// naming a path, resolutions on that same mechanical path DO become
    /// feelings — while every other mechanical path stays silent.
    @Test func aPathSheHoldsAViewAboutBecomesAStake() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await seedActiveViews(s, [(
            title: "The anthropic oauth path is what keeps breaking our releases",
            body: "Every stranded release this month traced back to the anthropic credential refresh.",
            evidence: 5
        )], at: clock.now())

        let held = feltResolution(
            organ: "provider-anthropic-oauth-direct", pathKind: .providerCompletion, at: clock.now())
        #expect(await s.feltResolutionIsAtStake(held),
                "she has settled a view naming this path — its resolution means something to her")
        #expect(await s.ingestResident(held))

        clock.advance(120)
        let unheld = feltResolution(organ: "tool-grep", pathKind: .toolCompletion, at: clock.now())
        #expect(await s.feltResolutionIsAtStake(unheld) == false)
        #expect(await s.ingestResident(unheld) == false)

        #expect(await feltNodeCount(s) == 1)
    }

    /// A floor keyword tripping on a MACHINE identifier is a coincidence, not a
    /// stake. "tool-commit-memory" contains "commit" (followThrough floor); it
    /// must still be silent, because only a concern SHE formed opens this gate.
    @Test func floorKeywordsDoNotOpenTheStakeGateOnMachineIdentifiers() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        for organ in ["tool-commit-memory", "tool-fix-lint", "tool-verify-signature"] {
            let e = feltResolution(organ: organ, pathKind: .toolCompletion, at: clock.now())
            #expect(await s.feltResolutionIsAtStake(e) == false, "\(organ) is a machine token")
            clock.advance(60)
        }
        #expect(await feltNodeCount(s) == 0)
    }

    /// Scope discipline: this gate touches ONE event class. Everything else is
    /// admitted exactly as before — it must never become a general filter.
    @Test func theStakeGateTouchesOnlyFeltResolutions() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let kinds: [CognitiveEventKind] = [
            .userMessageReceived, .assistantTurnCompleted, .toolStarted, .toolSucceeded,
            .toolFailed, .toolCancelled, .userCorrection, .providerFailure,
            .providerVitalsShift, .workshopExecutionCompleted, .appWake, .appSleep,
        ]
        for kind in kinds {
            let e = CognitiveEvent(
                id: UUID().uuidString, kind: kind,
                subject: CognitiveSubjectReference(type: "chat_turn", id: UUID().uuidString),
                sourceClass: .observed, occurredAt: clock.now(),
                summary: "an ordinary \(kind.rawValue) moment", importance: 0.5)
            #expect(await s.feltResolutionIsAtStake(e), "\(kind.rawValue) must be unaffected")
        }
    }

    // MARK: - D-2 measurement: the signal-to-noise claim, measured

    /// Her measured population, by `subject_label`, read out of the live store
    /// (`data/cognition/cognition.sqlite`, 2026-08-02, 40 feltResolution nodes
    /// over four weeks). Every one of them is a mechanical path; there is not a
    /// single `approvalResolution` or `workflowAdvance` node in four weeks.
    private static let measuredFeltPopulation: [(organ: String, kind: OrganismPredictionKind, n: Int)] = [
        ("provider-anthropic-oauth-direct", .providerCompletion, 30),
        ("tool-grep", .toolCompletion, 1),
        ("tool-git-log", .toolCompletion, 1),
        ("tool-tool-catalog", .toolCompletion, 1),
        ("tool-search-chat-history", .toolCompletion, 1),
        ("tool-desk-archive", .toolCompletion, 1),
        ("tool-github-command", .toolCompletion, 1),
        ("phone-007a7eb87d0938f165ce7d9dc27123c753c046dcfb", .phoneDelivery, 1),
        ("phone-3805159a3c24746ebae01db2c493f7f6d4302d08aa", .phoneDelivery, 1),
        ("phone-39b8847f095f435b92731474d5d80928cb1057a764", .phoneDelivery, 1),
        ("phone-cc1d5661dfcd9ed5a9cb725bd9d39da2b033601c97", .phoneDelivery, 1),
    ]

    /// BEFORE/AFTER, measured rather than asserted, by replaying her REAL
    /// four-week felt population through the gate.
    ///
    /// BEFORE = 40 — the felt nodes the pre-gate code minted, which is exactly
    /// what is in her store today (the runtime mints a distinct subject id per
    /// felt moment, so none of them collapsed into one node).
    /// AFTER = 0 — none of the 40 survives, because all 40 are mechanical paths
    /// and she holds no approved standing view naming any of them.
    ///
    /// Zero is not the steady state and must not be read as "the felt layer is
    /// off": it is what four weeks of exclusively-mechanical resolutions plus an
    /// empty active-view set produces. `realStakesStillProduceFeltResolutions`
    /// and `aPathSheHoldsAViewAboutBecomesAStake` pin the two ways it speaks
    /// again — a commitment or approval resolving, or a view she settles that
    /// names a path.
    @Test func measuredFeltPopulationCollapsesThroughTheStakeGate() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        var before = 0
        for spec in Self.measuredFeltPopulation {
            for _ in 0..<spec.n {
                _ = await s.ingestResident(feltResolution(
                    organ: spec.organ, pathKind: spec.kind, at: clock.now()))
                before += 1
                clock.advance(3_600)
            }
        }
        let after = await feltNodeCount(s)

        #expect(before == 40, "the replayed population matches her measured store")
        #expect(after == 0, "every felt node she has recorded in four weeks was her own plumbing")

        // The same stream with three REAL stakes mixed in: only the stakes land.
        let mixed = makeSubstrate(clock)
        for spec in Self.measuredFeltPopulation {
            for _ in 0..<spec.n {
                _ = await mixed.ingestResident(feltResolution(
                    organ: spec.organ, pathKind: spec.kind, at: clock.now()))
                clock.advance(600)
            }
        }
        for (organ, kind, relief) in [
            ("desk-ship-0-3-2", OrganismPredictionKind.workflowAdvance, true),
            ("approval-standing-view", .approvalResolution, true),
            ("desk-ship-0-3-2", .workflowAdvance, false),
        ] {
            _ = await mixed.ingestResident(feltResolution(
                organ: organ, pathKind: kind, relief: relief, at: clock.now()))
            clock.advance(600)
        }
        let mixedAfter = await feltNodeCount(mixed)
        #expect(mixedAfter == 3, "43 felt events in, 3 felt nodes out")
        #expect(Double(mixedAfter) / 43.0 < 0.10,
                "felt volume must FALL sharply — this is a signal-to-noise fix")
        let survivors = await mixed.snapshot().nodes.filter { $0.kind == .feltResolution }
        #expect(survivors.allSatisfy {
            ["workflowAdvance", "approvalResolution"].contains($0.subjectReference.label ?? "")
        }, "what survives is the stake-bearing set, not an arbitrary sample")
    }
}
