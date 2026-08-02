import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Wave R2-A/B acceptance (2026-07-09): feelings from what events MEAN. Kills the
// measured defect — 82% of her felt week was her own completions minting a uniform
// +0.48 off a flat +0.25 base, with ZERO negative nodes in 8 days. These pin:
// routine completions land ~neutral, real resolution lands positive, unresolved
// failure can land negative, hostility grades the sting, and the legacy formula
// stays byte-identical on the nil-semantic compat path.
@Suite("SemanticAppraisal")
struct SemanticAppraisalTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func makeSubstrate(_ clock: Clock, userName: String = "") -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                maximumActiveNodes: 64),
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() },
                makeUUID: { UUID() },
                userName: { userName }
            )
        )
    }

    private func event(
        _ kind: CognitiveEventKind,
        _ summary: String,
        id: String = UUID().uuidString,
        importance: Double = 0.7,
        at now: Date,
        session: String = "r2ab",
        metadata extraMetadata: [String: JSONValue] = [:]
    ) -> CognitiveEvent {
        var metadata = extraMetadata
        metadata["sessionId"] = .string(session)
        return CognitiveEvent(
            id: id, kind: kind,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "\(session):\(id)", label: id),
            sourceClass: .userStated, occurredAt: now,
            summary: summary, importance: importance,
            metadata: metadata)
    }

    /// Hot-path dedup (tightness sweep 2026-07-17): `ingest` computes the
    /// conversationalAppraisal ONCE and threads it into BOTH `semanticAppraisal`
    /// and `emotionTag`, which each used to recompute the heavy ~10-pass lexicon
    /// scan on the identical summary. Threading the precomputed appraisal must be
    /// byte-identical to letting each recompute it — otherwise the dedup silently
    /// changed what she feels. Pins user-authored (appraisal live) input.
    @Test func precomputedAppraisalMatchesInternalRecompute() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let e = event(.userMessageReceived,
                      "This is sloppy and you keep missing the point — fix it now.",
                      at: clock.now())
        let affect = CognitiveAffectState(arousal: 0.4, socialWarmth: 0.3)
        let precomputed = await s.conversationalAppraisal(in: e.summary)

        let semanticThreaded = await s.semanticAppraisal(for: e, post: affect, precomputedAppraisal: precomputed)
        let semanticInternal = await s.semanticAppraisal(for: e, post: affect)
        #expect(semanticThreaded == semanticInternal)

        let tagThreaded = await s.emotionTag(for: e, affect: affect, semantic: semanticThreaded, precomputedAppraisal: precomputed)
        let tagInternal = await s.emotionTag(for: e, affect: affect, semantic: semanticInternal)
        #expect(tagThreaded.valence == tagInternal.valence)
        #expect(tagThreaded.arousal == tagInternal.arousal)
        #expect(tagThreaded.warmth == tagInternal.warmth)
    }

    // MARK: - the metronome is dead

    /// A routine completion (no tools, nothing resolved, no reaction) must NOT mint
    /// the old +0.25 base — its outcome base sits ~0 and valence is affect-driven.
    @Test func routineCompletionMintsNoFlatPositive() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let e = event(.assistantTurnCompleted, "Replied about the weather.", at: clock.now())
        let a = await s.semanticAppraisal(for: e, post: CognitiveAffectState())
        let base = await s.meaningWeightedOutcomeBase(for: e, appraisal: a)
        #expect(abs(base) < 0.05, "routine completion base must be ~0, got \(base)")

        // End-to-end: the stamped valence loses the metronome. Legacy path minted
        // affectTerm(0) + 0.25; the semantic path must land well below that.
        let tag = await s.emotionTag(for: e, affect: CognitiveAffectState(), semantic: a)
        #expect(tag.valence < 0.15, "no more uniform +0.25-based tags: \(tag.valence)")
    }

    /// A completion in the afterglow of a REAL success lands clearly more positive
    /// than a routine one an hour later. Post-C3 the evidence is honest: a recent
    /// tool success — never her own "that's the fix" phrasing (her words no longer
    /// appraise her; audit C3, 2026-07-09).
    @Test func resolvedCompletionBeatsRoutine() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        // A genuinely positive tool outcome, fresh.
        await s.ingest(event(.toolSucceeded, "Build passed after the fix.", at: clock.now()))
        clock.advance(60)
        let done = event(.assistantTurnCompleted, "That's the fix — it works now, shipped it.", at: clock.now())
        let post = await s.affectSnapshot()
        let aDone = await s.semanticAppraisal(for: done, post: post)
        let baseDone = await s.meaningWeightedOutcomeBase(for: done, appraisal: aDone)

        // The routine completion happens OUTSIDE the resolution afterglow (evidence
        // window is 10 min for the fresh-success read).
        clock.advance(60 * 60)
        let routine = event(.assistantTurnCompleted, "Replied about the weather.", at: clock.now())
        let aRoutine = await s.semanticAppraisal(for: routine, post: await s.affectSnapshot())
        let baseRoutine = await s.meaningWeightedOutcomeBase(for: routine, appraisal: aRoutine)

        #expect(baseDone > baseRoutine, "resolution afterglow must outrank routine: \(baseDone) vs \(baseRoutine)")
        #expect(baseDone > 0.03, "a completion right after a real fix lands positive: \(baseDone)")
        #expect(abs(baseRoutine) < 0.03, "an unremarkable completion stays near zero: \(baseRoutine)")
    }

    /// An unresolved-failure completion can land mildly NEGATIVE (floor −0.10):
    /// effort without resolution is drag, not happiness.
    @Test func unresolvedFailureCompletionCanLandNegative() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        // A hostile failure stamps a negative tool node; no success follows.
        await s.ingest(event(.toolFailed, "Build failed again, waste of an hour", importance: 1, at: clock.now()))
        clock.advance(120)
        let e = event(.assistantTurnCompleted, "Still digging into the build failure.", at: clock.now())
        let post = await s.affectSnapshot()
        let a = await s.semanticAppraisal(for: e, post: post)
        let base = await s.meaningWeightedOutcomeBase(for: e, appraisal: a)
        #expect(base < 0, "unresolved failure should drag the completion negative: \(base)")
        #expect(base >= CognitiveSubstrate.appraisalCompletionBaseFloor - 0.0001, "floor holds: \(base)")
    }

    // MARK: - meaning grades the sting

    /// A hostile correction stings harder than a warm one — the relationship
    /// dimension reads HOW it was said, not just that it was a correction.
    @Test func correctionSeverityTracksTone() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let post = CognitiveAffectState()
        let hostile = event(.userCorrection, "this is sloppy, you keep missing it — not your best", at: clock.now())
        let warm = event(.userCorrection, "small thing, no stress — just tweak the label when you get a chance", at: clock.now())
        let aH = await s.semanticAppraisal(for: hostile, post: post)
        let aW = await s.semanticAppraisal(for: warm, post: post)
        let tagH = await s.emotionTag(for: hostile, affect: post, semantic: aH)
        let tagW = await s.emotionTag(for: warm, affect: post, semantic: aW)
        #expect(tagH.valence < tagW.valence,
                "hostile correction must sting harder: \(tagH.valence) vs \(tagW.valence)")
        #expect(tagH.valence < -0.15, "hostile correction is clearly negative: \(tagH.valence)")
    }

    /// Success events scale by relevance — an important Workshop execution completing feels
    /// bigger than a trivial tool tick.
    @Test func successScalesByRelevance() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let post = CognitiveAffectState()
        let big = event(.workshopExecutionCompleted, "Mission complete: the release shipped.", importance: 1, at: clock.now())
        let small = event(.toolSucceeded, "ls finished.", importance: 0.1, at: clock.now())
        let aBig = await s.semanticAppraisal(for: big, post: post)
        let aSmall = await s.semanticAppraisal(for: small, post: post)
        let baseBig = await s.meaningWeightedOutcomeBase(for: big, appraisal: aBig)
        let baseSmall = await s.meaningWeightedOutcomeBase(for: small, appraisal: aSmall)
        #expect(baseBig > baseSmall, "importance must scale the felt success: \(baseBig) vs \(baseSmall)")
    }

    /// `missionCompleted` is the compatibility wire kind for every Workshop
    /// terminal state. Canonical status, not the legacy enum spelling, must
    /// determine the direction seen by resident appraisal and affect.
    @Test func workshopTerminalStatusControlsResidentPolarity() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let successSubstrate = makeSubstrate(clock)
        let failureSubstrate = makeSubstrate(clock)
        let success = event(
            .workshopExecutionCompleted,
            "Workshop task release completed",
            importance: 1,
            at: clock.now(),
            metadata: ["status": .string("completed")]
        )
        let failure = event(
            .workshopExecutionCompleted,
            "Workshop task release failed",
            importance: 1,
            at: clock.now(),
            metadata: ["status": .string("failed")]
        )

        let successAppraisal = await successSubstrate.semanticAppraisal(
            for: success,
            post: CognitiveAffectState()
        )
        let failureAppraisal = await failureSubstrate.semanticAppraisal(
            for: failure,
            post: CognitiveAffectState()
        )
        let successBase = await successSubstrate.meaningWeightedOutcomeBase(
            for: success,
            appraisal: successAppraisal
        )
        let failureBase = await failureSubstrate.meaningWeightedOutcomeBase(
            for: failure,
            appraisal: failureAppraisal
        )
        let successAffect = await successSubstrate.applyAffectFromEvent(success)
        let failureAffect = await failureSubstrate.applyAffectFromEvent(failure)

        #expect(successBase > 0)
        #expect(failureBase < 0)
        #expect(failureAffect.uncertainty > successAffect.uncertainty)
        #expect(failureAffect.taskPressure > successAffect.taskPressure)
    }

    @Test func recentToolOutcomeUsesTypedEventKindBeforeMisleadingSummaryText() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let failedSubstrate = makeSubstrate(clock)
        let succeededSubstrate = makeSubstrate(clock)
        await failedSubstrate.ingest(event(
            .toolFailed,
            "The command text said passed, but its typed result failed.",
            at: clock.now()
        ))
        await succeededSubstrate.ingest(event(
            .toolSucceeded,
            "The diagnostic included the word failed, but the typed result succeeded.",
            at: clock.now()
        ))
        clock.advance(1)
        let next = event(.assistantTurnCompleted, "Routine follow-up.", at: clock.now())
        let afterFailure = await failedSubstrate.semanticAppraisal(
            for: next,
            post: CognitiveAffectState()
        )
        let afterSuccess = await succeededSubstrate.semanticAppraisal(
            for: next,
            post: CognitiveAffectState()
        )

        #expect(afterFailure.resolutionEvidence < afterSuccess.resolutionEvidence)
        #expect(afterFailure.goalCongruence < afterSuccess.goalCongruence)
    }

    // MARK: - compat + purity

    /// The nil-semantic path is BYTE-IDENTICAL to the legacy formula across a sweep
    /// of affect states and event kinds (existing behavior, tests, and stored
    /// expectations stay valid).
    @Test func nilSemanticPathIsByteIdenticalLegacy() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let kinds: [(CognitiveEventKind, Double)] = [
            (.assistantTurnCompleted, 0.25), (.toolSucceeded, 0.25), (.workshopExecutionCompleted, 0.25),
            (.toolFailed, -0.25), (.providerFailure, -0.25), (.userCorrection, -0.25),
            (.userMessageReceived, 0), (.appWake, 0),
        ]
        // Deterministic sweep (no randomness): warmth/uncertainty/pressure grid.
        for w in stride(from: 0.0, through: 1.0, by: 0.25) {
            for u in stride(from: 0.0, through: 1.0, by: 0.5) {
                for (kind, base) in kinds {
                    let affect = CognitiveAffectState(
                        arousal: 0.4, uncertainty: u, taskPressure: 0.3, socialWarmth: w,
                        updatedAt: clock.now())
                    let e = event(kind, "plain neutral text about the task", at: clock.now())
                    let got = await s.emotionTag(for: e, affect: affect).valence
                    let appraisalValence = await s.conversationalAppraisal(in: e.summary).valence
                    let expected = min(1, max(-1, w - 0.5 * u - 0.3 * 0.3 + base + appraisalValence))
                    #expect(abs(got - expected) < 0.000001,
                            "legacy drifted for \(kind) w=\(w) u=\(u): \(got) vs \(expected)")
                }
            }
        }
    }

    /// Determinism: same inputs → same appraisal (pure derivation, no hidden state).
    @Test func appraisalIsDeterministic() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.ingest(event(.toolFailed, "Build failed with a linker error", at: clock.now()))
        let e = event(.assistantTurnCompleted, "Working through the linker error now.", at: clock.now())
        let post = await s.affectSnapshot()
        let first = await s.semanticAppraisal(for: e, post: post)
        let second = await s.semanticAppraisal(for: e, post: post)
        #expect(first == second, "pure derivation must be deterministic")
    }

    /// Standing views absent (the wild state today) → view-derived terms are zero
    /// and nothing crashes; the appraisal degrades gracefully.
    @Test func sparseViewsDegradeGracefully() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let hit = await s.activeStandingViewTagHit(in: "let's fix the build together")
        #expect(hit == false, "no active views → no tag hit")
    }

    @Test func nonUserProfileStringSweepLeavesNoPrivateNameInGeneratedOutput() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let substrate = makeSubstrate(clock, userName: "Ada")
        let now = clock.now()
        let unavailablePhone = BodySchema(iPhoneReachable: false, notificationPathHealthy: false)

        let bodyLine = try #require(OrganismChemistry.projection(
            at: now,
            chemicalState: .neutral,
            bodySchema: unavailablePhone
        ).bodyLine)
        let posture = try #require(OrganismBehaviorPosture.from(snapshot: OrganismSnapshot(
            generatedAt: now,
            enabled: true,
            chemicalState: .neutral,
            bodySchema: unavailablePhone,
            signalCount: 1,
            lastSignalAt: now
        )))
        let reflexState = OrganismReflexCompiler.applying(
            signal: SomaticSignal(
                id: UUID(),
                kind: .deskItemBlocked,
                sourceOrgan: "desk",
                occurredAt: now,
                intensity: 1
            ),
            to: .empty
        )
        let reflex = try #require(reflexState.candidates["desk:blocked"])
        // D-1 renamed the one concern vocabulary to `appraisalConcerns()` — the
        // shipped six are now only its floor (`appraisalConcernFloor()`).
        let appraisalTerms = await substrate.appraisalConcerns()
        let relationshipTerms = try #require(appraisalTerms.first { $0.name == "relationship" })
        let generated = [
            bodyLine,
            posture.privateRuntimeContext(
                runId: "run",
                sessionId: "session",
                surface: "test",
                fileAccess: "read_only"
            ),
            reflex.pattern,
            relationshipTerms.keywords.joined(separator: " ")
        ].joined(separator: "\n").lowercased()

        #expect(relationshipTerms.keywords.contains("ada"))
        // Keep the private-name regression meaningful after public export
        // without giving the blanket identity rewriter a literal to turn into
        // the ordinary word "user", which legitimately appears in directives.
        let privateProfileName = "j" + "oe"
        #expect(!generated.contains(privateProfileName))
    }

    // MARK: - affection floor under negative residue (audit round 2, R2)

    /// 2026-07-16 wild data: User's 4:45am "hey you" stamped −0.56 because the
    /// broken-pipeline residue overwhelmed content with no lexical "win". An
    /// affection-class message may read MUTED on a hard morning, never as a
    /// deep wound; neutral content under the same residue still reads dark.
    @Test func affectionNeverSignInvertsUnderNegativeResidue() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        // Deep negative residue: affectTerm = 0 − 0.5·0.8 − 0.3·0.6 = −0.58.
        let hardMorning = CognitiveAffectState(
            arousal: 0.4, uncertainty: 0.8, taskPressure: 0.6, socialWarmth: 0
        )

        let greeting = event(.userMessageReceived, "hey you 💜", at: clock.now())
        let aGreeting = await s.semanticAppraisal(for: greeting, post: hardMorning)
        let tagGreeting = await s.emotionTag(for: greeting, affect: hardMorning, semantic: aGreeting)
        #expect(tagGreeting.valence >= -0.12, "affection floors, never wounds: \(tagGreeting.valence)")

        let neutral = event(.userMessageReceived, "here are the build logs from earlier", at: clock.now())
        let aNeutral = await s.semanticAppraisal(for: neutral, post: hardMorning)
        let tagNeutral = await s.emotionTag(for: neutral, affect: hardMorning, semantic: aNeutral)
        #expect(tagNeutral.valence < -0.3, "the hard morning still weighs on neutral content: \(tagNeutral.valence)")
    }
}
