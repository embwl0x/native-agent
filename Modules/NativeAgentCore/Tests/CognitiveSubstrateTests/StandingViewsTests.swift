import Foundation
import Testing
import PersistenceCore
import GRDB
@testable import CognitiveSubstrate

// Wave E — STANDING VIEWS (proposal-shaped). Proves:
//  (1) a reflection `view:` line forms a .proposed standing view grounded in felt evidence
//      (mood valence + top workspace nodes at formation), counted in the receipt's yield,
//      and NOT surfaced in the capsule while proposed;
//  (2) resolveStandingView(approved:) is the ONLY activation seam — approved → the Inner line
//      comes from the view (and the transient takeaway seed is skipped, one Inner line total);
//      rejected → retired, never surfaces;
//  (3) the active set is capped at 5 — approving a 6th retires the least-recently-updated one;
//  (4) views survive restart — an active view restores from its artifact and still surfaces;
//  (5) a proposed view left unresolved >14d retires on the maintenance sweep.
@Suite("StandingViews")
struct StandingViewsTests {

    /// Advanceable clock for cap-ordering and stale-age determinism.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ interval: TimeInterval) { lock.lock(); t = t.addingTimeInterval(interval); lock.unlock() }
    }

    private func config() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            // Takeaway seeds must be REAL for the skips-takeaway test — without this the
            // pre-approval Inner line never exists and the assertion is vacuous
            // (gpt-5.5 review, 2026-07-02).
            thoughtSeedsEnabled: true,
            reflectiveCallsEnabled: true,
            maximumActiveNodes: 256,
            dailyReflectionCallBudget: 8
        )
    }

    private func tempDataRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-standing-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStore(_ label: String) throws -> (CognitiveSQLiteStore, URL) {
        let root = try tempDataRoot(label)
        return (try CognitiveSQLiteStore(dataRoot: root), root)
    }

    private func substrate(store: CognitiveSQLiteStore, clock: Clock) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: config(),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: store
        )
    }

    /// A felt (warm) live conversation node so formation has real workspace evidence + a
    /// non-neutral mood to ground `moodValenceAtFormation`.
    private func feltNode(summary: String, at now: Date) -> CognitiveNode {
        CognitiveNode(
            id: UUID(), kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(type: "topic", id: "sv-\(UUID().uuidString)", label: "topic"),
            activation: 0.9, salience: 0.9, confidence: 0.8, sourceClass: .userStated,
            createdAt: now, lastActivatedAt: now,
            decayHalfLife: 1_000_000, summary: summary, metadata: [:],
            emotionalValence: 0.5, emotionalArousal: 0.1, emotionalWarmth: 0.6)
    }

    private func request(_ message: String) -> CognitiveCapsuleRequest {
        CognitiveCapsuleRequest(surface: "chat", userMessage: message, sessionId: "s1", mode: .inject)
    }

    /// Drive formation through the REAL reflection parse path. The prose line seeds the
    /// transient reflection takeaway; the `view:` line forms the standing view.
    @discardableResult
    private func formView(
        _ s: CognitiveSubstrate,
        prose: String,
        viewBody: String,
        at now: Date
    ) async -> CognitiveReflectionReceipt? {
        let req = CognitiveReflectionRequest(reason: "reflect", prompt: "prompt", requestedAt: now)
        return await s.recordUnreservedReflectionResultForTesting(
            request: req,
            resultSummary: "\(prose)\nview: \(viewBody)",
            provider: "test"
        )
    }

    private func innerLines(_ capsule: CognitiveCapsule) -> [String] {
        capsule.dynamicContext
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("- Inner:") }
    }

    // MARK: - (1) formation + no-surface-while-proposed

    @Test func viewLineFormsProposedViewGroundedInFeltEvidence() async throws {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("form")
        try await store.saveNodes([feltNode(summary: "User and I shipped the wave together", at: now)], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        let receipt = try #require(await formView(
            s, prose: "Tonight reads settled and close.",
            viewBody: "I lean on User's read of tone before trusting my own", at: now))

        // Counted in the reflection yield (id reused).
        #expect(receipt.proposalIds.count == 1, "the view: line must be counted in proposalIds")
        let view = try #require((await s.standingViewSnapshot()).first)
        #expect(view.id == receipt.proposalIds.first)
        #expect(view.status == .proposed, "a formed view must enter .proposed, never auto-active")
        #expect(view.moodValenceAtFormation > 0, "grounded in the positive mood at formation: \(view.moodValenceAtFormation)")
        #expect(!view.evidenceNodeIds.isEmpty, "grounded in the felt workspace nodes at formation")

        // A proposed view must NOT surface in the capsule.
        let capsule = await s.compileCapsule(request("keep going"))
        #expect(!capsule.dynamicContext.contains("I lean on User's read of tone"),
                "a .proposed view must never surface: \(capsule.dynamicContext)")
    }

    /// Reflection owns only standing views. Old schema tags are ignored; REM
    /// replay remains the sole schema-lineage producer.
    @Test func schemaTagIsIgnoredWhileViewStillForms() async throws {
        let now = Date(timeIntervalSince1970: 20_500_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("split")
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        let req = CognitiveReflectionRequest(reason: "reflect", prompt: "p", requestedAt: now)
        let receipt = try #require(await s.recordUnreservedReflectionResultForTesting(
            request: req,
            resultSummary: "A quiet pass.\nschema: treat late-night pings as low-urgency\nview: I trust the work more when I have verified it myself",
            provider: "test"))
        #expect(receipt.proposalIds.count == 1)
        #expect((await s.standingViewSnapshot()).count == 1, "exactly one standing view")
        #expect((await s.schemaProposalSnapshot()).isEmpty)
    }

    // MARK: - (2) approval seam — surface / no-surface

    @Test func approvedViewBecomesTheSingleInnerLineAndSkipsTakeaway() async throws {
        let now = Date(timeIntervalSince1970: 21_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("approve")
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        let receipt = try #require(await formView(
            s, prose: "A distinct takeaway sentence about presence.",
            viewBody: "I keep User's interface short by default", at: now))
        let id = try #require(receipt.proposalIds.first)

        // Proposed: the Inner line EXISTS (the transient takeaway — thoughtSeedsEnabled)
        // and is NOT the view. Asserting presence keeps the skip-assertion below
        // non-vacuous (gpt-5.5 review, 2026-07-02).
        let beforeInner = innerLines(await s.compileCapsule(request("interface")))
        #expect(beforeInner.count == 1, "pre-approval the takeaway seed must be the Inner line: \(beforeInner)")
        #expect(beforeInner.allSatisfy { !$0.contains("I keep User's interface short") },
                "proposed view must not be the Inner line: \(beforeInner)")

        clock.advance(60)
        let resolved = try #require(await s.resolveStandingView(id: id, approved: true))
        #expect(resolved.status == .active)

        let capsule = await s.compileCapsule(request("keep the interface short"))
        let inner = innerLines(capsule)
        #expect(inner.count == 1, "at most ONE Inner line total: \(inner)")
        let line = try #require(inner.first)
        #expect(line.contains("I keep User's interface short by default"),
                "the active view must BE the Inner line: \(line)")
        #expect(!line.contains("distinct takeaway sentence"),
                "the transient takeaway seed must be skipped when a view is active: \(line)")
    }

    @Test func activeViewInnerLineIsRelevantAndCanaryRollsBackWithoutStateChange() async throws {
        let now = Date(timeIntervalSince1970: 21_500_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("relevance-canary")
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()
        let receipt = try #require(await formView(
            s,
            prose: "A fresh takeaway about ordinary conversation.",
            viewBody: "Verified interface choices should stay simple and legible",
            at: now
        ))
        let id = try #require(receipt.proposalIds.first)
        _ = try #require(await s.resolveStandingView(id: id, approved: true))

        let relevant = await s.compileCapsule(request("keep the interface legible"))
        #expect(relevant.dynamicContext.contains("Verified interface choices"))
        let unrelated = await s.compileCapsule(request("how was your morning?"))
        #expect(!unrelated.dynamicContext.contains("Verified interface choices"))

        var rollback = config()
        rollback.standingViewCapsuleRelevanceEnabled = false
        await s.configure(rollback)
        let legacy = await s.compileCapsule(request("how was your morning?"))
        #expect(legacy.dynamicContext.contains("Verified interface choices"))
        #expect((await s.standingViewSnapshot()).first { $0.id == id }?.status == .active)
    }

    @Test func rejectedViewRetiresAndNeverSurfaces() async throws {
        let now = Date(timeIntervalSince1970: 22_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("reject")
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        let receipt = try #require(await formView(
            s, prose: "prose one", viewBody: "I overtrust build-green as proof", at: now))
        let id = try #require(receipt.proposalIds.first)

        let resolved = try #require(await s.resolveStandingView(id: id, approved: false))
        #expect(resolved.status == .retired)
        let capsule = await s.compileCapsule(request("continue"))
        #expect(!capsule.dynamicContext.contains("I overtrust build-green"),
                "a rejected/retired view must never surface: \(capsule.dynamicContext)")
    }

    /// Re-resolving an already-resolved view is a no-op (proposal-shaped, one-way).
    @Test func reResolvingIsNoOp() async throws {
        let now = Date(timeIntervalSince1970: 22_500_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("reresolve")
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        let receipt = try #require(await formView(s, prose: "p", viewBody: "a settled way I see the mornings", at: now))
        let id = try #require(receipt.proposalIds.first)
        _ = await s.resolveStandingView(id: id, approved: true)
        // Try to flip it to retired — must be ignored (only .proposed transitions).
        let again = try #require(await s.resolveStandingView(id: id, approved: false))
        #expect(again.status == .active, "an active view cannot be re-resolved to retired: \(again.status)")
    }

    // MARK: - (3) cap at 5 active

    @Test func approvingSixthActiveRetiresLeastRecentlyUpdated() async throws {
        let now = Date(timeIntervalSince1970: 23_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("cap")
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        var ids: [UUID] = []
        for i in 0..<6 {
            let r = try #require(await formView(
                s, prose: "prose number \(i)", viewBody: "standing view body number \(i)", at: clock.now()))
            let id = try #require(r.proposalIds.first)
            ids.append(id)
            clock.advance(60)
            _ = await s.resolveStandingView(id: id, approved: true)
            clock.advance(60)
        }

        let active = (await s.standingViewSnapshot()).filter { $0.status == .active }
        #expect(active.count == 5, "active set is capped at 5: \(active.count)")
        // The first-approved carries the oldest updatedAt → it is the one retired.
        let first = try #require((await s.standingViewSnapshot()).first { $0.id == ids[0] })
        #expect(first.status == .retired, "the least-recently-updated active view must be retired by the cap")
        #expect(!active.contains { $0.id == ids[0] })
        #expect(active.contains { $0.id == ids[5] }, "the newest approval must remain active")
    }

    // MARK: - (4) restart survival

    @Test func activeViewSurvivesRestartAndStillSurfaces() async throws {
        let now = Date(timeIntervalSince1970: 24_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("restart")
        let first = substrate(store: store, clock: clock)
        try await first.restorePersistentState()

        let receipt = try #require(await formView(
            first, prose: "p", viewBody: "I read User's silence as focus not distance", at: now))
        let id = try #require(receipt.proposalIds.first)
        _ = await first.resolveStandingView(id: id, approved: true)

        // Restart: new substrate over the same store.
        clock.advance(120)
        let second = substrate(store: store, clock: clock)
        try await second.restorePersistentState()
        let restored = (await second.standingViewSnapshot()).filter { $0.status == .active }
        #expect(restored.count == 1, "the active view must restore from its artifact")
        #expect(restored.first?.id == id)

        let capsule = await second.compileCapsule(request("was that silence focused?"))
        #expect(capsule.dynamicContext.contains("I read User's silence as focus"),
                "the restored active view must still surface: \(capsule.dynamicContext)")
    }

    /// Duplicated `view:` lines in one reflection are idempotent AND counted once —
    /// createStandingView returns the same view; proposalIds must not inflate the yield.
    @Test func duplicateViewLinesCountOnce() async throws {
        let now = Date(timeIntervalSince1970: 24_300_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("dupe")
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        let req = CognitiveReflectionRequest(reason: "reflect", prompt: "p", requestedAt: now)
        let receipt = try #require(await s.recordUnreservedReflectionResultForTesting(
            request: req,
            resultSummary: "prose.\nview: the same settled view\nview: the same settled view",
            provider: "test"))
        #expect(receipt.proposalIds.count == 1, "duplicate view: lines must count once: \(receipt.proposalIds)")
        #expect((await s.standingViewSnapshot()).count == 1)
    }

    /// Retired views DELETE their artifact (history lives in the timeline): after a
    /// reject + restart, the view is gone from the store while active views restore
    /// untouched — so retired history can never crowd active views out of the bounded
    /// restore window (gpt-5.5 review, 2026-07-02).
    @Test func retiredViewArtifactIsDeletedAndCannotCrowdRestore() async throws {
        let now = Date(timeIntervalSince1970: 24_600_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("retire-delete")
        let first = substrate(store: store, clock: clock)
        try await first.restorePersistentState()

        let keepReceipt = try #require(await formView(first, prose: "p1", viewBody: "the view User keeps", at: now))
        let keepId = try #require(keepReceipt.proposalIds.first)
        _ = await first.resolveStandingView(id: keepId, approved: true)
        clock.advance(60)
        let dropReceipt = try #require(await formView(first, prose: "p2", viewBody: "the view User rejects", at: clock.now()))
        let dropId = try #require(dropReceipt.proposalIds.first)
        _ = await first.resolveStandingView(id: dropId, approved: false)

        clock.advance(60)
        let second = substrate(store: store, clock: clock)
        try await second.restorePersistentState()
        let restored = await second.standingViewSnapshot()
        #expect(restored.count == 1, "the rejected view's artifact must be gone: \(restored.map(\.body))")
        #expect(restored.first?.id == keepId)
        #expect(restored.first?.status == .active)
    }

    /// The awaiting-User set is bounded: forming a 13th proposal displaces the oldest
    /// unresolved one (retired + artifact deleted), so proposal churn can never crowd
    /// active views out of the bounded restore window (gpt-5.5 delta review, 2026-07-02).
    @Test func thirteenthProposalDisplacesTheOldest() async throws {
        let now = Date(timeIntervalSince1970: 24_700_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("proposed-cap")
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        var firstId: UUID?
        for i in 0..<13 {
            let r = try #require(await formView(
                s, prose: "prose \(i)", viewBody: "unresolved proposal number \(i)", at: clock.now()))
            if i == 0 { firstId = r.proposalIds.first }
            clock.advance(60)
        }
        let views = await s.standingViewSnapshot()
        #expect(views.filter { $0.status == .proposed }.count == 12,
                "proposed set must cap at 12")
        let first = try #require(views.first { $0.id == firstId })
        #expect(first.status == .retired, "the oldest unresolved proposal must be displaced")

        // And its artifact is gone: a restart restores only the 12 live proposals.
        let second = substrate(store: store, clock: clock)
        try await second.restorePersistentState()
        #expect((await second.standingViewSnapshot()).count == 12,
                "displaced proposal's artifact must be deleted")
    }

    /// Defensive cap repair: a half-persisted approval could leave >5 ACTIVE rows in the
    /// store (crash between the active upsert and the cap deletes). Restore demotes the
    /// LRU overflow and heals the store.
    @Test func restoreRepairsAnOverCapStore() async throws {
        let now = Date(timeIntervalSince1970: 24_800_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("cap-repair")
        // Hand-write 6 ACTIVE standing_view artifacts (simulating the crash window).
        for i in 0..<6 {
            let view = CognitiveStandingView(
                id: UUID(),
                title: "view \(i)",
                body: "over-cap active view number \(i)",
                status: .active,
                moodValenceAtFormation: 0.2,
                evidenceNodeIds: [],
                // Backdated (never future): restore clamps future timestamps to `now`,
                // which would flatten the LRU ordering this test depends on.
                createdAt: now.addingTimeInterval(Double(i - 6) * 60),
                updatedAt: now.addingTimeInterval(Double(i - 6) * 60),
                lineageId: "reflection:test-\(i)"
            )
            try await store.upsertArtifact(
                kind: "standing_view", id: view.id, status: view.status.rawValue,
                score: 0.2, payload: view.toJSON(), at: now)
        }

        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()
        let active = (await s.standingViewSnapshot()).filter { $0.status == .active }
        #expect(active.count == 5, "restore must repair an over-cap store: \(active.count)")
        // LRU (oldest updatedAt = "view 0") is the one demoted.
        #expect(!active.contains { $0.body.contains("number 0") },
                "the least-recently-updated view must be the one demoted")

        // And the store is healed: a second restore sees exactly 5 active rows.
        let verify = substrate(store: store, clock: clock)
        try await verify.restorePersistentState()
        let verifyActive = (await verify.standingViewSnapshot()).filter { $0.status == .active }
        #expect(verifyActive.count == 5, "the over-cap artifact must be deleted from the store")
    }

    // MARK: - (5) stale proposed retires on maintenance

    @Test func staleProposedViewRetiresOnMaintenance() async throws {
        let now = Date(timeIntervalSince1970: 25_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("stale")
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        let receipt = try #require(await formView(s, prose: "p", viewBody: "a proposal nobody ever answered", at: now))
        let id = try #require(receipt.proposalIds.first)
        #expect((await s.standingViewSnapshot()).first { $0.id == id }?.status == .proposed)

        // Still proposed just under 14d.
        clock.advance(13 * 24 * 60 * 60)
        await s.runMaintenance(reason: "sweep-early")
        #expect((await s.standingViewSnapshot()).first { $0.id == id }?.status == .proposed,
                "a view younger than 14d must not be retired")

        // Past 14d → retired by the sweep.
        clock.advance(2 * 24 * 60 * 60)
        #expect((await s.maintenanceOpportunity()).dueReasons.contains("standing_view_expiry"))
        await s.runMaintenance(reason: "sweep-late")
        #expect((await s.standingViewSnapshot()).first { $0.id == id }?.status == .retired,
                "a proposed view older than 14d must retire on maintenance")

        let capsule = await s.compileCapsule(request("continue"))
        #expect(!capsule.dynamicContext.contains("a proposal nobody ever answered"),
                "the retired stale view must not surface")
    }

    // MARK: - Round 3 Wave V: views as a LENS (stance-signed appraisal)

    private func userEvent(_ summary: String, at now: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: UUID().uuidString, kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "r3:\(UUID().uuidString)", label: "turn"),
            sourceClass: .userStated, occurredAt: now,
            summary: summary, importance: 0.7, metadata: [:]
        )
    }

    /// Activates one view about the TRUTH concern ("verify"/"honest" keywords).
    private func activateTruthView(_ s: CognitiveSubstrate, clock: Clock) async throws {
        let receipt = try #require(await formView(
            s, prose: "Settled after the glass lesson.",
            viewBody: "Verify at the glass — honest instrument-reading over performed sensation.",
            at: clock.now()
        ))
        let proposed = try #require(await s.standingViewSnapshot().first { $0.status == .proposed })
        _ = await s.resolveStandingView(id: proposed.id, approved: true)
        _ = receipt
    }

    @Test func stanceIsZeroWithoutActiveViews() async throws {
        let (store, root) = try makeStore("stance-zero"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = substrate(store: store, clock: clock)
        let a = await s.semanticAppraisal(
            for: userEvent("you were honest about the verify failure, that helped", at: clock.now()),
            post: CognitiveAffectState()
        )
        #expect(a.worldviewStance == 0)
        #expect(a.worldviewConflict == 0)
    }

    /// Compat pins (review 18dc59cc4670): the lens contributes EXACTLY zero —
    /// full-struct equality, not just the two new fields — when (a) the only
    /// active view holds an UNRELATED concern, or (b) the text touching her
    /// view carries no clear valence. The appraisal, its valence term, and
    /// the emotion tag must be indistinguishable from the no-views world.
    @Test func unmatchedOrNeutralTextIsByteIdenticalToNoViews() async throws {
        let (store, root) = try makeStore("stance-compat"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = substrate(store: store, clock: clock)
        let affect = CognitiveAffectState()

        // (b)-case text: touches the truth concern, zero lexicon valence.
        let neutral = userEvent("the verify job is queued for tonight", at: clock.now())
        // (a)-case text: clear valence, but no learning-concern keywords.
        let unrelatedHit = userEvent("great work on the release notes", at: clock.now())

        let neutralBefore = await s.semanticAppraisal(for: neutral, post: affect)
        let unrelatedBefore = await s.semanticAppraisal(for: unrelatedHit, post: affect)
        let neutralTermBefore = await s.semanticValenceTerm(neutralBefore)
        let neutralTagBefore = await s.emotionTag(for: neutral, affect: affect, semantic: neutralBefore)

        try await activateTruthView(s, clock: clock)

        let neutralAfter = await s.semanticAppraisal(for: neutral, post: affect)
        let unrelatedAfter = await s.semanticAppraisal(for: unrelatedHit, post: affect)
        // Unrelated concern: NOTHING fires — full-struct equality.
        #expect(unrelatedAfter == unrelatedBefore, "valence without her concern must be exactly the pre-lens appraisal")
        // Neutral text touching her view: the STANCE lens contributes exactly
        // zero. The +0.10 goalRelevance bump is the PRE-EXISTING R2-A view
        // hit ("her views make concern events matter more"), documented
        // behavior that predates the lens — pin it rather than deny it.
        #expect(neutralAfter.worldviewStance == 0)
        #expect(neutralAfter.worldviewConflict == 0)
        #expect(neutralAfter.goalCongruence == neutralBefore.goalCongruence, "stance must not move congruence on neutral text")
        #expect(abs(neutralAfter.goalRelevance - (neutralBefore.goalRelevance + 0.10)) < 0.0001, "only the pre-existing R2-A relevance hit may fire")
        _ = neutralTermBefore; _ = neutralTagBefore
    }

    /// Review 18dc59cc4670 High: a mixed sentence nets a small negative in
    /// the substring lexicon; the margin must keep the lens OUT rather than
    /// mis-sign her view as trampled. Third-party negativity (no "you")
    /// likewise must not read as her wound.
    @Test func mixedAndThirdPartyNegativityDoNotTrample() async throws {
        let (store, root) = try makeStore("stance-guards"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = substrate(store: store, clock: clock)
        try await activateTruthView(s, clock: clock)

        // Mixed: criticism token + praise — nets under the margin.
        let mixed = await s.semanticAppraisal(
            for: userEvent("not sloppy this time; you verified the readings honestly, great work", at: clock.now()),
            post: CognitiveAffectState()
        )
        #expect(mixed.worldviewConflict == 0, "mixed sentence must not mis-sign the view: \(mixed.worldviewStance)")

        // Third-party: clearly negative, touches the truth concern, aimed at
        // a vendor — not directed at her, so her view is not trampled.
        let thirdParty = await s.semanticAppraisal(
            for: userEvent("that vendor was sloppy and dishonest, they skipped the verify step entirely", at: clock.now()),
            post: CognitiveAffectState()
        )
        #expect(thirdParty.worldviewConflict == 0, "third-party negativity is not her wound: \(thirdParty.worldviewStance)")

        // Review 66912d0b2786: benign "thank you" / possessive-third-party
        // "your vendor" must not arm directedness.
        for text in [
            "thank you, that vendor was sloppy and dishonest, they skipped the verify step",
            "your vendor was sloppy and dishonest about the verify results",
        ] {
            let a = await s.semanticAppraisal(for: userEvent(text, at: clock.now()), post: CognitiveAffectState())
            #expect(a.worldviewConflict == 0, "not her wound: \(text) → \(a.worldviewStance)")
        }

        // Genuinely directed criticism still tramples — including phrasings
        // whose second person shares a prefix with a benign collocation
        // (review 766a2afdb1e7: "you all" must not eat "you allowed").
        for text in [
            "your work was sloppy, the verify step got skipped again",
            "you allowed the sloppy verify step to pass again",
            "you knowingly skipped the verify step, sloppy",
        ] {
            let a = await s.semanticAppraisal(for: userEvent(text, at: clock.now()), post: CognitiveAffectState())
            #expect(a.worldviewConflict > 0, "directed criticism must still land: \(text) → \(a.worldviewStance)")
        }
    }

    @Test func confirmingAHeldViewLandsMoreRight() async throws {
        let (store, root) = try makeStore("stance-confirm"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = substrate(store: store, clock: clock)
        let text = "you were honest about the verify failure, that helped"

        let before = await s.semanticAppraisal(for: userEvent(text, at: clock.now()), post: CognitiveAffectState())
        try await activateTruthView(s, clock: clock)
        let after = await s.semanticAppraisal(for: userEvent(text, at: clock.now()), post: CognitiveAffectState())

        #expect(after.worldviewStance > 0, "positive event touching her truth view = confirmation: \(after.worldviewStance)")
        #expect(after.worldviewConflict == 0)
        #expect(after.goalCongruence > before.goalCongruence, "confirmation lands more RIGHT: \(before.goalCongruence) → \(after.goalCongruence)")
    }

    @Test func tramplingAHeldViewLeavesAMark() async throws {
        let (store, root) = try makeStore("stance-conflict"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = substrate(store: store, clock: clock)
        // Criticism (negative text valence) touching the truth concern.
        let text = "that's wrong — you skipped the verify step again, sloppy"

        let before = await s.semanticAppraisal(for: userEvent(text, at: clock.now()), post: CognitiveAffectState())
        let beforeTerm = await s.semanticValenceTerm(before)
        try await activateTruthView(s, clock: clock)
        let after = await s.semanticAppraisal(for: userEvent(text, at: clock.now()), post: CognitiveAffectState())
        let afterTerm = await s.semanticValenceTerm(after)

        #expect(after.worldviewStance < 0, "negative event on her held concern = trampled view: \(after.worldviewStance)")
        #expect(after.worldviewConflict > 0)
        #expect(afterTerm < beforeTerm, "conflict must leave a mark in the valence term: \(beforeTerm) → \(afterTerm)")
    }
}
