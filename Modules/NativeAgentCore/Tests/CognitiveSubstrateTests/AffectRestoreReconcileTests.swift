import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger row `substrate.affect.restore` (core.substrate.affect).
//
// `restoreAffect` + `reconcileRestoredAffectWithRecentConversation`: on relaunch
// a LEGACY affect artifact (one written before temporal anchors existed) may be
// lifted to a warmth floor from the recent conversation. That heuristic is gated
// on `lastUserPresenceAt == nil`. If a future payload change stops writing that
// key, EVERY relaunch re-runs the bump and manufactures a warmth increase out of
// a restart — and nothing observes it, because the artifact is a single upserted
// row, so the before/after values are gone.
//
// The A/B below is the whole point: identical store, identical nodes, identical
// affect numbers, differing ONLY in the presence of `lastUserPresenceAt`.
@Suite("AffectRestoreReconcile")
struct AffectRestoreReconcileTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// Well inside the reconcile's 6h recency window, and 2 socialWarmth
    /// half-lives back so the restored value is unambiguously below any floor.
    private var conversationAt: Date { now.addingTimeInterval(-3 * 3_600) }

    private func makeStore(_ label: String) throws -> (CognitiveSQLiteStore, URL) {
        let root = try AffectFenceFixture.temporaryRoot(label)
        return (try CognitiveSQLiteStore(dataRoot: root), root)
    }

    private func affectPayload(socialWarmth: Double, carriesPresenceKey: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "arousal": .double(0.10),
            "uncertainty": .double(0.10),
            "taskPressure": .double(0.10),
            "socialWarmth": .double(socialWarmth),
            "updatedAt": .double(conversationAt.timeIntervalSince1970),
        ]
        if carriesPresenceKey {
            object["lastUserPresenceAt"] = .double(conversationAt.timeIntervalSince1970)
        }
        return .object(object)
    }

    private func seed(
        _ store: CognitiveSQLiteStore,
        summary: String,
        carriesPresenceKey: Bool,
        socialWarmth: Double = 0.02
    ) async throws {
        try await store.saveNodes(
            [AffectFenceFixture.node(
                summary: summary,
                metadata: ["turnKind": .string("live")],
                valence: 0.4, arousal: 0.3, warmth: 0.5,
                createdAt: conversationAt)],
            at: conversationAt)
        try await store.upsertArtifact(
            kind: "affect",
            id: UUID(),
            status: "current",
            score: 0.1,
            payload: affectPayload(socialWarmth: socialWarmth, carriesPresenceKey: carriesPresenceKey),
            at: conversationAt)
    }

    private func relaunch(on store: CognitiveSQLiteStore) async throws -> CognitiveAffectState {
        let substrate = AffectFenceFixture.substrate(
            clock: AffectFenceClock(now),
            configuration: AffectFenceFixture.configuration(persistenceEnabled: true),
            store: store)
        try await substrate.restorePersistentState()
        return await substrate.affectSnapshot()
    }

    private func storedWarmth(_ store: CognitiveSQLiteStore) async throws -> Double? {
        let artifacts = try await store.loadArtifacts(kindPrefix: "affect", limit: 1)
        guard case .object(let object)? = artifacts.first,
              case .double(let warmth)? = object["socialWarmth"] else { return nil }
        return warmth
    }

    /// THE NEGATIVE CONTROL, and the one the silent failure lives on: a modern
    /// payload carrying `lastUserPresenceAt` must come back EXACTLY as persisted
    /// (decayed to now) across two consecutive relaunches. A restart is not a
    /// warmth event.
    @Test func aModernPayloadIsRestartEquivalentAcrossTwoRelaunches() async throws {
        let (store, root) = try makeStore("modern")
        defer { try? FileManager.default.removeItem(at: root) }
        // The same warm conversation the legacy case below lifts on — so the
        // ONLY difference between the two cases is the presence key.
        try await seed(store, summary: "miss you — how are you feeling today?", carriesPresenceKey: true)
        let warmthBefore = try await storedWarmth(store)

        let first = try await relaunch(on: store)
        let second = try await relaunch(on: store)

        #expect(first.socialWarmth < 0.22,
                "a restart manufactured warmth: \(first.socialWarmth)")
        #expect(abs(first.socialWarmth - second.socialWarmth) < 1e-9,
                "relaunch is not idempotent: \(first.socialWarmth) -> \(second.socialWarmth)")
        let warmthAfter = try await storedWarmth(store)
        #expect(warmthBefore == warmthAfter,
                "a read-only restore rewrote the affect row: \(String(describing: warmthBefore)) -> \(String(describing: warmthAfter))")
    }

    /// The legacy path still WORKS — proving the negative control above is not
    /// passing because the whole reconcile is dead. A legacy payload plus recent
    /// warm conversation lifts warmth to the tier's floor, and no further.
    @Test func aLegacyPayloadIsLiftedToItsTierFloorAndNoHigher() async throws {
        // High tier (unambiguous affection) -> the higher floor.
        let (highStore, highRoot) = try makeStore("legacy-high")
        defer { try? FileManager.default.removeItem(at: highRoot) }
        try await seed(highStore, summary: "miss you — how are you feeling today?", carriesPresenceKey: false)
        let high = try await relaunch(on: highStore)

        // Low tier (mild warmth) -> the lower floor.
        let (lowStore, lowRoot) = try makeStore("legacy-low")
        defer { try? FileManager.default.removeItem(at: lowRoot) }
        try await seed(lowStore, summary: "thank you for sticking with this", carriesPresenceKey: false)
        let low = try await relaunch(on: lowStore)

        #expect(high.socialWarmth > 0.02, "the legacy reconcile is dead — nothing lifted")
        #expect(low.socialWarmth > 0.02, "the legacy reconcile is dead — nothing lifted")
        // A floor, not a ratchet: it lands ON the tier floor, never above it.
        #expect(high.socialWarmth <= 0.38 + 1e-9, "high tier overshot its floor: \(high.socialWarmth)")
        #expect(low.socialWarmth <= 0.22 + 1e-9, "low tier overshot its floor: \(low.socialWarmth)")
        // The tiers are ordered, so a mild thank-you can never read like affection.
        #expect(low.socialWarmth < high.socialWarmth,
                "the two warmth tiers collapsed into one: \(low.socialWarmth) vs \(high.socialWarmth)")
    }

    /// The lift is EXACTLY ONCE at a fixed instant: a second relaunch with the
    /// clock unmoved must not stack another bump on top of the first.
    @Test func theLegacyLiftDoesNotStackOnASecondRelaunch() async throws {
        let (store, root) = try makeStore("legacy-twice")
        defer { try? FileManager.default.removeItem(at: root) }
        try await seed(store, summary: "miss you — how are you feeling today?", carriesPresenceKey: false)

        let first = try await relaunch(on: store)
        let second = try await relaunch(on: store)
        #expect(second.socialWarmth <= first.socialWarmth + 1e-9,
                "warmth ratcheted on a second relaunch: \(first.socialWarmth) -> \(second.socialWarmth)")
    }

    /// The reconcile reads CONVERSATION, not machinery, and not stale history.
    @Test func onlyRecentLiveWarmConversationCanLift() async throws {
        // (a) a warm exchange older than the 6h window is not "recent".
        let (staleStore, staleRoot) = try makeStore("legacy-stale")
        defer { try? FileManager.default.removeItem(at: staleRoot) }
        try await staleStore.saveNodes(
            [AffectFenceFixture.node(
                summary: "miss you — how are you feeling today?",
                metadata: ["turnKind": .string("live")],
                valence: 0.4, arousal: 0.3, warmth: 0.5,
                createdAt: now.addingTimeInterval(-9 * 3_600))],
            at: now.addingTimeInterval(-9 * 3_600))
        try await staleStore.upsertArtifact(
            kind: "affect", id: UUID(), status: "current", score: 0.1,
            payload: affectPayload(socialWarmth: 0.02, carriesPresenceKey: false),
            at: conversationAt)
        let stale = try await relaunch(on: staleStore)
        #expect(stale.socialWarmth < 0.22,
                "a 9h-old exchange manufactured warmth on relaunch: \(stale.socialWarmth)")

        // (b) recent, but pure work — no genuine warmth in it.
        let (workStore, workRoot) = try makeStore("legacy-work")
        defer { try? FileManager.default.removeItem(at: workRoot) }
        try await seed(workStore, summary: "ok user lets fix the build and ship the diff", carriesPresenceKey: false)
        let work = try await relaunch(on: workStore)
        #expect(work.socialWarmth < 0.22,
                "a pure work session manufactured warmth on relaunch: \(work.socialWarmth)")
    }
}
