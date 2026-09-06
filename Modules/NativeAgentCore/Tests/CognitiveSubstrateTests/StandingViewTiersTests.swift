import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// TWO CHANGES TO THE STANDING-VIEW LIFECYCLE, 2026-09-02.
//
// (A) RETIREMENT. `resolveStandingView` only ever transitioned `.proposed`, so
//     the only route out of `.active` was LRU demotion by a sixth approval.
//     Agent found three of her five active views were three drafts of ONE
//     phrasing view and had no way to say so. A worldview you can enter but not
//     leave is a ratchet.
//
// (B) THE HELD TIER (User: "she should be able to have some views of her own").
//     A view she adopts herself: no signature, half the lean, ranked under
//     every signed view, retirable by the user who never signed it — and
//     mintable ONLY from her own live local turn.
@Suite("StandingViewTiers")
struct StandingViewTiersTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func config() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            reflectiveCallsEnabled: true,
            maximumActiveNodes: 256,
            dailyReflectionCallBudget: 32
        )
    }

    private func makeSubstrate(_ label: String, clock: Clock) throws -> CognitiveSubstrate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-tiers-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CognitiveSubstrate(
            configuration: config(),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: try CognitiveSQLiteStore(dataRoot: root))
    }

    /// Formation through the REAL reflection parse path — the only producer.
    private func formView(
        _ s: CognitiveSubstrate,
        body: String,
        at now: Date
    ) async -> UUID? {
        let receipt = await s.recordUnreservedReflectionResultForTesting(
            request: CognitiveReflectionRequest(reason: "reflect", prompt: "prompt", requestedAt: now),
            resultSummary: "A settled read of the night.\nview: \(body)",
            provider: "test")
        return receipt?.proposalIds.first
    }

    /// Her seat. In production this comes back from
    /// `StudioCanonSeatGate.liveTurnProvenance`, which reads task-locals the
    /// bridge tool runner, every executor and every replay cannot bind — so a
    /// complete one is a FACT about where the call came from, not a claim.
    private let seat = StudioCanonTurnProvenance(surface: "chat", turnID: "turn-1")

    // MARK: - (A) retirement

    @Test func retiringAnActiveViewFreesASlotAndIsIdempotent() async throws {
        let now = Date(timeIntervalSince1970: 21_000_000)
        let clock = Clock(now)
        let s = try makeSubstrate("retire", clock: clock)
        try await s.restorePersistentState()

        let id = try #require(await formView(s, body: "I keep User's interface short by default", at: now))
        #expect(try #require(await s.resolveStandingView(id: id, approved: true)).status == .active)

        clock.advance(60)
        let retired = try #require(await s.retireStandingView(id: id))
        #expect(retired.status == .retired, "an ACTIVE view must be retirable without a sixth approval")

        // A freed slot is a real slot: the active set is now empty.
        let active = (await s.standingViewSnapshot()).filter { $0.status == .active }
        #expect(active.isEmpty)

        // Idempotent — a second click is a no-op that reports the same state.
        clock.advance(60)
        let again = try #require(await s.retireStandingView(id: id))
        #expect(again.status == .retired)
        #expect(again.updatedAt == retired.updatedAt, "a no-op must not restamp the row")
    }

    /// Retire belongs to views she is LEANING on. A proposal is the resolve
    /// route's business, and quietly retiring one here would turn a review queue
    /// into a second, silent rejection path.
    @Test func retireNeverTouchesAProposedView() async throws {
        let now = Date(timeIntervalSince1970: 21_100_000)
        let clock = Clock(now)
        let s = try makeSubstrate("retire-proposed", clock: clock)
        try await s.restorePersistentState()

        let id = try #require(await formView(s, body: "I overtrust build-green as proof", at: now))
        let untouched = try #require(await s.retireStandingView(id: id))
        #expect(untouched.status == .proposed, "a proposed view is the resolve route's, not retire's")
        #expect(await s.retireStandingView(id: UUID()) == nil, "an unknown id is nil, not a crash")
    }

    /// A retired view stops leaning: the lived concern it minted is gone,
    /// because `livedAppraisalConcerns` derives them from the leaning set on
    /// every read rather than caching a set that would have to be invalidated.
    @Test func retiringAViewReMintsTheLivedConcerns() async throws {
        let now = Date(timeIntervalSince1970: 21_200_000)
        let clock = Clock(now)
        let s = try makeSubstrate("retire-concerns", clock: clock)
        try await s.restorePersistentState()

        let id = try #require(await formView(
            s, body: "Verified interface choices should stay simple and legible", at: now))
        _ = await s.resolveStandingView(id: id, approved: true)
        #expect(!(await s.livedAppraisalConcerns()).isEmpty, "an active view mints a lived concern")

        clock.advance(60)
        _ = await s.retireStandingView(id: id)
        #expect((await s.livedAppraisalConcerns()).isEmpty,
                "a retired view must stop minting the concern it minted")
    }

    // MARK: - (B) the held tier

    /// HER SEAT ONLY. An incomplete provenance is a REFUSAL, never a silent
    /// downgrade to a proposal — a fallback would let an unseated path mint
    /// views forever and the tier's whole meaning would be gone.
    @Test func holdRequiresACompleteLiveTurnSeat() async throws {
        let now = Date(timeIntervalSince1970: 21_300_000)
        let clock = Clock(now)
        let s = try makeSubstrate("hold-seat", clock: clock)
        try await s.restorePersistentState()

        let id = try #require(await formView(s, body: "Short answers respect the reader", at: now))
        for unseated in [
            StudioCanonTurnProvenance(surface: "", turnID: "turn-1"),
            StudioCanonTurnProvenance(surface: "chat", turnID: ""),
            StudioCanonTurnProvenance(surface: "  ", turnID: "  "),
        ] {
            #expect(await s.holdStandingView(id: id, seat: unseated) == nil,
                    "an incomplete seat must refuse, not downgrade")
        }
        #expect((await s.standingViewSnapshot()).first?.status == .proposed)

        let held = try #require(await s.holdStandingView(id: id, seat: seat))
        #expect(held.status == .held)
    }

    /// A held view leans at HALF the lean of a signed one. Halving the whole
    /// WEIGHT would be wrong: 1.0 is the neutral floor on that scale, so a
    /// halved weight would land a maxed held view exactly on it and "she can
    /// hold a view of her own" would silently mean "and it does nothing".
    @Test func aHeldViewLeansAtHalfStake() async throws {
        let now = Date(timeIntervalSince1970: 21_400_000)
        let clock = Clock(now)
        let s = try makeSubstrate("hold-weight", clock: clock)
        try await s.restorePersistentState()

        let signedId = try #require(await formView(
            s, body: "Verified interface choices should stay simple and legible", at: now))
        _ = await s.resolveStandingView(id: signedId, approved: true)
        let signedWeight = try #require(
            (await s.livedAppraisalConcerns()).first(where: { $0.origin == .lived })?.weight)

        clock.advance(60)
        _ = await s.retireStandingView(id: signedId)
        let heldId = try #require(await formView(
            s, body: "Verified interface choices should stay simple and legible too",
            at: clock.now()))
        _ = try #require(await s.holdStandingView(id: heldId, seat: seat))
        let heldWeight = try #require(
            (await s.livedAppraisalConcerns()).first(where: { $0.origin == .lived })?.weight)

        let factor = PersonalityDynamicsConfiguration.default.heldStandingViewWeightFactor
        #expect(heldWeight < signedWeight, "a held view must not weigh what a signed one weighs")
        #expect(heldWeight > 1.0, "…and must still lean at all")
        #expect(abs((heldWeight - 1.0) - (signedWeight - 1.0) * factor) < 0.0001,
                "the LEAN is what halves: held \(heldWeight) vs signed \(signedWeight)")
    }

    /// RANKED BELOW. However well a held view matches the message, it comes
    /// after every signed view that also matches.
    @Test func heldViewsRankUnderSignedOnes() async throws {
        let now = Date(timeIntervalSince1970: 21_500_000)
        let clock = Clock(now)
        let s = try makeSubstrate("hold-rank", clock: clock)
        try await s.restorePersistentState()

        let signedId = try #require(await formView(
            s, body: "Interface choices should stay legible", at: now))
        _ = await s.resolveStandingView(id: signedId, approved: true)
        clock.advance(60)
        // Held view formed LATER, so newest-first ordering would otherwise put
        // it in front — the tier, not recency, has to decide this.
        let heldId = try #require(await formView(
            s, body: "Interface legibility is worth a slower answer", at: clock.now()))
        _ = try #require(await s.holdStandingView(id: heldId, seat: seat))

        let lines = await s.activeStandingViewInnerLines(relevantTo: "keep the interface legible")
        #expect(lines.count == 2, "both tiers must be offered to the rotation: \(lines)")
        #expect(lines.first?.contains("should stay legible") == true,
                "the SIGNED view must lead: \(lines)")
        #expect(lines.last?.contains("worth a slower answer") == true)
    }

    /// The held cap is its own, LRU'd separately, so an overflowing held set can
    /// never evict a signed view.
    @Test func theHeldSetIsCappedAndNeverEvictsASignedView() async throws {
        let now = Date(timeIntervalSince1970: 21_600_000)
        let clock = Clock(now)
        let s = try makeSubstrate("hold-cap", clock: clock)
        try await s.restorePersistentState()

        let signedId = try #require(await formView(s, body: "Signed lens number one", at: now))
        _ = await s.resolveStandingView(id: signedId, approved: true)

        var heldIds: [UUID] = []
        for index in 0...CognitiveSubstrate.maximumHeldStandingViews {
            clock.advance(60)
            let id = try #require(await formView(
                s, body: "A view of my own, number \(index)", at: clock.now()))
            _ = try #require(await s.holdStandingView(id: id, seat: seat))
            heldIds.append(id)
        }

        let snapshot = await s.standingViewSnapshot()
        let held = snapshot.filter { $0.status == .held }
        #expect(held.count == CognitiveSubstrate.maximumHeldStandingViews,
                "the held tier must stay bounded: \(held.count)")
        #expect(snapshot.first(where: { $0.id == signedId })?.status == .active,
                "held overflow must never evict a signed view")
        #expect(snapshot.first(where: { $0.id == heldIds.first })?.status == .retired,
                "LRU drops the stalest held view")
    }

    /// The user may retire a view she never had to sign.
    @Test func theUserCanRetireAHeldView() async throws {
        let now = Date(timeIntervalSince1970: 21_700_000)
        let clock = Clock(now)
        let s = try makeSubstrate("hold-retire", clock: clock)
        try await s.restorePersistentState()

        let id = try #require(await formView(s, body: "A view of my own", at: now))
        _ = try #require(await s.holdStandingView(id: id, seat: seat))
        clock.advance(60)
        #expect(try #require(await s.retireStandingView(id: id)).status == .retired)
        #expect((await s.standingViewSnapshot()).first(where: { $0.id == id })?.status == .retired)
    }

    /// Holding is not a back door onto the ACTIVE tier: only `.proposed` can be
    /// held, and an already-active view is left exactly as it is rather than
    /// being quietly demoted.
    @Test func holdingOnlyEverTransitionsAProposal() async throws {
        let now = Date(timeIntervalSince1970: 21_800_000)
        let clock = Clock(now)
        let s = try makeSubstrate("hold-guard", clock: clock)
        try await s.restorePersistentState()

        let id = try #require(await formView(s, body: "A signed lens", at: now))
        _ = await s.resolveStandingView(id: id, approved: true)
        clock.advance(60)
        #expect(try #require(await s.holdStandingView(id: id, seat: seat)).status == .active,
                "holding an active view must not demote it")
    }
}
