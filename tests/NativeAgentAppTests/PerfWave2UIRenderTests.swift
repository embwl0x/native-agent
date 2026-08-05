import AppKit
import Foundation
import Observation
import Testing
import NativeAgentShared
import PersistenceCore
@testable import NativeAgentApp

// Perf wave 2, Mac UI lane — render-cost audit findings F12, F1, F10, F13, F14
// follow-up, plus the three `Equatable` conformances that wave 1 had to leave
// ungated for a type reason.
//
// The through-line, same as wave 1: Swift Observation fires on *write*, not on
// *change*, and a recompute that runs per event costs O(n) per event. These
// tests pin the properties that make the fixes safe — not just "it got faster",
// but "and it still shows the same thing at the same time".

/// `withObservationTracking`'s onChange is an escaping @Sendable closure, so it
/// cannot capture a local `var`. (Same shape as `RenderCostAuditWaveTests`.)
private final class FireFlag: @unchecked Sendable {
    var fired = false
}

/// Shared fixtures for the self-improvement payload types.
enum PerfWave2Fixtures {
    static func trainingRun(id: String, verdict: String) -> TrainingRunSummary {
        TrainingRunSummary(
            run_id: id,
            started_at: nil,
            completed_at: nil,
            surface: nil,
            score: nil,
            max_score: nil,
            drift_summary: nil,
            proposals_staged: nil,
            verdict: verdict
        )
    }

    static func trainingProposal(id: String, status: String) -> TrainingProposalSummary {
        TrainingProposalSummary(
            proposal_id: id,
            staged_at: nil,
            source_run_id: nil,
            target_doc: "VOICE.md",
            change_type: "append",
            current: "",
            proposed: "something concrete",
            rationale: "because",
            expected_drift_addressed: nil,
            status: status,
            reviewed_at: nil,
            reject_reason: nil
        )
    }

    /// `PromotionCandidateSummary` hand-rolls `init(from:)` for the snake/camel
    /// wire aliases, so it has no memberwise init — build it the way production
    /// does, through the decoder.
    static func promotionCandidate(id: String, decision: String?) throws -> PromotionCandidateSummary {
        let decisionField = decision.map { "\"decision\":\"\($0)\"," } ?? ""
        let json = """
        {"candidate_id":"\(id)","source":"manual","tier":"B",\(decisionField)"status":"complete"}
        """
        return try JSONDecoder().decode(PromotionCandidateSummary.self, from: Data(json.utf8))
    }
}

// MARK: - F12: TurnInspectorStore coalesces the card regroup

@Suite("Perf wave 2 — F12 TurnInspector regroup debounce")
struct TurnInspectorRegroupDebounceTests {

    private func event(turn: String, kind: String, tsOffset: TimeInterval) -> TurnTraceEvent {
        TurnTraceEvent(
            turnId: turn,
            ts: Date(timeIntervalSince1970: 1_700_000_000 + tsOffset),
            kind: kind,
            sessionId: "sess-1",
            surface: "chat",
            payload: .object([:])
        )
    }

    /// The finding itself: a burst of events must cost ONE regroup, not N.
    @MainActor
    @Test func burst_of_events_defers_regroup_instead_of_running_it_per_event() {
        let store = TurnInspectorStore(dataRootOverride: URL(fileURLWithPath: NSTemporaryDirectory()))
        for i in 0..<50 {
            store._appendLiveForTesting(event(turn: "A", kind: "llm.call", tsOffset: Double(i)))
        }
        // Every one of those 50 used to run a full bucket + per-bucket sort +
        // row re-allocation + final sort and replace `cards` wholesale.
        #expect(store.cards.isEmpty, "regroup must be deferred, not run per event")
        #expect(store._hasPendingCardsRefreshForTesting, "a regroup must be armed")

        store._flushPendingCardsRefreshForTesting()
        #expect(store._hasPendingCardsRefreshForTesting == false)
        #expect(store.cards.count == 1)
        #expect(store.cards[0].rows.count == 50, "no event may be lost to the debounce")
    }

    /// Same output as the un-debounced path. Debouncing changes *when*, never
    /// *what* — incremental append (which would change *what*) is the held
    /// NEEDS-USER half of F12.
    @MainActor
    @Test func flushed_cards_are_identical_to_ungated_grouping() {
        let events = [
            event(turn: "A", kind: "assembly.stage", tsOffset: 0),
            event(turn: "A", kind: "llm.call", tsOffset: 5),
            event(turn: "B", kind: "assembly.stage", tsOffset: 100),
            event(turn: "B", kind: "tool.dispatch", tsOffset: 105),
            event(turn: "B", kind: "llm.call", tsOffset: 110),
        ]
        let store = TurnInspectorStore(dataRootOverride: URL(fileURLWithPath: NSTemporaryDirectory()))
        for e in events { store._appendLiveForTesting(e) }
        store._flushPendingCardsRefreshForTesting()

        let reference = TurnInspectorGrouping.group(events)
        #expect(store.cards.map(\.id) == reference.map(\.id))
        #expect(store.cards.map { $0.rows.map(\.kind) } == reference.map { $0.rows.map(\.kind) })
    }

    /// The debounce must actually FIRE on its own — a "can never fire" timer is
    /// the failure mode this class of fix ships most often. No manual flush.
    @MainActor
    @Test func debounce_fires_on_its_own_without_a_manual_flush() async throws {
        let store = TurnInspectorStore(dataRootOverride: URL(fileURLWithPath: NSTemporaryDirectory()))
        store._appendLiveForTesting(event(turn: "A", kind: "llm.call", tsOffset: 0))
        #expect(store.cards.isEmpty)

        // Comfortably past the 0.1 s window, bounded so a stuck debounce fails
        // the test rather than hanging the suite.
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(store._hasPendingCardsRefreshForTesting == false)
        #expect(store.cards.count == 1, "the debounced regroup never landed")
    }

    /// Re-arming: events arriving inside the window join the same regroup, and
    /// a SECOND burst after the first landed must arm a fresh one (i.e. the
    /// scheduled flag is not latched).
    @MainActor
    @Test func debounce_rearms_for_a_second_burst() async throws {
        let store = TurnInspectorStore(dataRootOverride: URL(fileURLWithPath: NSTemporaryDirectory()))
        store._appendLiveForTesting(event(turn: "A", kind: "llm.call", tsOffset: 0))
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(store.cards.count == 1)

        store._appendLiveForTesting(event(turn: "B", kind: "llm.call", tsOffset: 200))
        #expect(store._hasPendingCardsRefreshForTesting, "second burst must re-arm")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(store.cards.count == 2)
    }

    /// User-initiated transitions must never be deferred.
    @MainActor
    @Test func clearLive_empties_immediately_and_cancels_the_pending_regroup() {
        let store = TurnInspectorStore(dataRootOverride: URL(fileURLWithPath: NSTemporaryDirectory()))
        store._appendLiveForTesting(event(turn: "A", kind: "llm.call", tsOffset: 0))
        store._flushPendingCardsRefreshForTesting()
        #expect(store.cards.count == 1)

        store._appendLiveForTesting(event(turn: "B", kind: "llm.call", tsOffset: 10))
        store.clearLive()
        #expect(store.cards.isEmpty, "clear must be immediate, not debounced")
        #expect(store._hasPendingCardsRefreshForTesting == false)
    }

    /// `setMode` cancels a pending live regroup — otherwise it would land under
    /// the NEW mode and regroup the wrong source array.
    @MainActor
    @Test func setMode_to_live_recomputes_immediately_and_drops_the_pending_window() {
        let store = TurnInspectorStore(dataRootOverride: URL(fileURLWithPath: NSTemporaryDirectory()))
        store._appendLiveForTesting(event(turn: "A", kind: "llm.call", tsOffset: 0))
        store.setMode(.replay)
        #expect(store._hasPendingCardsRefreshForTesting == false)

        store.setMode(.live)
        #expect(store._hasPendingCardsRefreshForTesting == false)
        #expect(store.cards.count == 1, "mode switch must paint now, not after a debounce")
    }

    /// Tearing the tab down must LAND the pending window, not drop it — and
    /// must not leave the scheduled flag latched (which would mean the next
    /// `start()` never regroups again).
    @MainActor
    @Test func stop_flushes_the_pending_regroup_rather_than_dropping_it() {
        let store = TurnInspectorStore(dataRootOverride: URL(fileURLWithPath: NSTemporaryDirectory()))
        store._appendLiveForTesting(event(turn: "A", kind: "llm.call", tsOffset: 0))
        #expect(store.cards.isEmpty)

        store.stop()
        #expect(store.cards.count == 1, "stop() must not eat the last events")
        #expect(store._hasPendingCardsRefreshForTesting == false, "flag must not latch")
    }
}

// MARK: - F13: the sidebar badge is one derived scalar

@Suite("Perf wave 2 — F13 sidebar badge scalar")
@MainActor
struct SidebarBadgeScalarTests {

    private func approval(id: String, status: String) -> ApprovalRequest {
        ApprovalRequest(id: id, title: "t", action: "a", risk: "low", status: status)
    }

    private func inboxItem(id: String, status: String) throws -> InboxItemRecord {
        let json = """
        {"id":"\(id)","created_at":"2026-08-05T00:00:00Z","source":"test",
         "severity":"actionable","title":"t","summary":"s","actions":[],
         "status":"\(status)"}
        """
        return try JSONDecoder().decode(InboxItemRecord.self, from: Data(json.utf8))
    }

    private func memoryProposal(id: String, status: String) -> MemoryProposalRecord {
        MemoryProposalRecord(
            proposal_id: id,
            fact_text: "f",
            display_text: nil,
            supporting_session_ids: [],
            recurrence_count: 1,
            first_seen: "2026-08-05",
            last_seen: "2026-08-05",
            status: status,
            staged_at: "2026-08-05",
            resolved_at: nil,
            rejection_reason: nil
        )
    }

    private func trainingProposal(id: String, status: String) -> TrainingProposalSummary {
        PerfWave2Fixtures.trainingProposal(id: id, status: status)
    }

    /// `PromotionCandidateSummary` hand-rolls `init(from:)` for the
    /// snake/camel wire aliases, so there is no memberwise init — build it the
    /// way production does, through the decoder.
    private func promotionCandidate(id: String, decision: String?) throws -> PromotionCandidateSummary {
        try PerfWave2Fixtures.promotionCandidate(id: id, decision: decision)
    }

    /// The staleness invariant, source by source. Every one of the five
    /// collections that feeds the sum must re-derive the scalar on write — no
    /// matter which code path performed the write. This is the test that has to
    /// fail if someone adds a sixth source without its `didSet`.
    @Test func every_backing_collection_updates_the_scalar_on_write() throws {
        let model = AppModel()
        #expect(model.pendingActivityCount == 0)
        #expect(model.pendingActivityCount == model.computedPendingActivityCount)

        model.approvals = [approval(id: "a1", status: "pending"), approval(id: "a2", status: "approved")]
        #expect(model.pendingActivityCount == model.computedPendingActivityCount)
        #expect(model.pendingActivityCount == 1)

        model.inboxItems = [try inboxItem(id: "i1", status: "unread"), try inboxItem(id: "i2", status: "read")]
        #expect(model.pendingActivityCount == model.computedPendingActivityCount)
        #expect(model.pendingActivityCount == 2)

        model.memoryProposals = [memoryProposal(id: "m1", status: "pending")]
        #expect(model.pendingActivityCount == model.computedPendingActivityCount)
        #expect(model.pendingActivityCount == 3)

        model.trainingProposals = [trainingProposal(id: "t1", status: "pending")]
        #expect(model.pendingActivityCount == model.computedPendingActivityCount)
        #expect(model.pendingActivityCount == 4)

        model.promotionCandidates = [try promotionCandidate(id: "p1", decision: "STAGE_FOR_HUMAN")]
        #expect(model.pendingActivityCount == model.computedPendingActivityCount)
        #expect(model.pendingActivityCount == 5)
    }

    /// Draining works too — the scalar must fall, not just rise. (A scalar that
    /// only ever increments is the classic derived-count bug.)
    @Test func resolving_items_lowers_the_scalar() throws {
        let model = AppModel()
        model.approvals = [approval(id: "a1", status: "pending"), approval(id: "a2", status: "pending")]
        model.inboxItems = [try inboxItem(id: "i1", status: "unread")]
        #expect(model.pendingActivityCount == 3)

        model.approvals = [approval(id: "a1", status: "approved"), approval(id: "a2", status: "denied")]
        #expect(model.pendingActivityCount == 1)
        model.inboxItems = []
        #expect(model.pendingActivityCount == 0)
        #expect(model.pendingActivityCount == model.computedPendingActivityCount)
    }

    /// Mutating a collection in place (not just replacing it) still fires the
    /// `didSet` — this is how the inbox patches a row to "read" locally
    /// (`InboxView` comment at the `status` field).
    @Test func in_place_element_mutation_updates_the_scalar() throws {
        let model = AppModel()
        model.inboxItems = [try inboxItem(id: "i1", status: "unread")]
        #expect(model.pendingActivityCount == 1)

        model.inboxItems[0].status = "read"
        #expect(model.pendingActivityCount == 0)
        #expect(model.pendingActivityCount == model.computedPendingActivityCount)
    }

    /// The actual win: a collection write that does not change the badge no
    /// longer invalidates the root. Before F13, `ContentView.body` read the
    /// computed `pendingActivityCount`, which registered a dependency on all
    /// five collections — so this write re-ran the whole `NavigationSplitView`
    /// including `case .chat: ChatView()`.
    @Test func collection_write_that_does_not_change_the_badge_does_not_invalidate_the_root() {
        let model = AppModel()
        model.approvals = [approval(id: "a1", status: "pending")]

        let flag = FireFlag()
        withObservationTracking {
            _ = model.pendingActivityCount
        } onChange: {
            flag.fired = true
        }

        // A real change to the collection — but not to the pending count.
        model.approvals = [approval(id: "a1", status: "pending"), approval(id: "a2", status: "approved")]

        #expect(flag.fired == false, "root must not re-render for an unchanged badge")
        #expect(model.pendingActivityCount == 1)
    }

    /// …and it still invalidates when the badge genuinely moves.
    @Test func badge_change_still_invalidates_the_root() {
        let model = AppModel()
        let flag = FireFlag()
        withObservationTracking {
            _ = model.pendingActivityCount
        } onChange: {
            flag.fired = true
        }

        model.approvals = [approval(id: "a1", status: "pending")]

        #expect(flag.fired == true)
        #expect(model.pendingActivityCount == 1)
    }

    /// Guard test: the scalar's sum and its `didSet` sources must not drift
    /// apart. Adding a term to `computedPendingActivityCount` without adding a
    /// `didSet` on its backing collection is the one way to reintroduce a
    /// staleness window, and it is invisible at runtime until a user sees a
    /// wrong badge.
    @Test func every_term_in_the_sum_has_a_didSet_on_its_backing_collection() throws {
        let source = try AppSourceScraping.appSource("AppModel.swift")
        let sumBody = try AppSourceScraping.functionBody(
            named: "computedPendingActivityCount", in: source.replacingOccurrences(
                of: "var computedPendingActivityCount", with: "func computedPendingActivityCount"
            )
        )
        // The five collections the sum reaches through its component counts.
        let backing = [
            "approvals": "var approvals: [ApprovalRequest] = []",
            "inboxItems": "var inboxItems: [InboxItemRecord] = []",
            "memoryProposals": "var memoryProposals: [MemoryProposalRecord] = []",
            "trainingProposals": "var trainingProposals: [TrainingProposalSummary] = []",
            "promotionCandidates": "var promotionCandidates: [PromotionCandidateSummary] = []",
        ]
        for (name, decl) in backing {
            guard let declRange = source.range(of: decl) else {
                Issue.record("Declaration for `\(name)` changed shape; update this guard test.")
                continue
            }
            let tail = source[declRange.upperBound...].prefix(160)
            #expect(
                tail.contains("didSet { recomputePendingActivityCount() }"),
                "`\(name)` feeds pendingActivityCount but lost its didSet — the badge can now go stale."
            )
        }
        // Four component terms; if a fifth appears, this test must be revisited
        // along with the didSet list above.
        let terms = sumBody.components(separatedBy: "+").count
        #expect(terms == 4, "the sum gained or lost a term — re-audit the didSet coverage")
    }
}

// MARK: - Equatable conformances + refreshAll gating

@Suite("Perf wave 2 — self-improvement payload equality gates")
@MainActor
struct SelfImprovementEqualityGateTests {

    @Test func identical_training_and_promotion_payloads_perform_no_write() throws {
        let model = AppModel()
        let runs = [PerfWave2Fixtures.trainingRun(id: "r1", verdict: "PASS")]
        let proposals = [PerfWave2Fixtures.trainingProposal(id: "p1", status: "pending")]
        let candidates = [try PerfWave2Fixtures.promotionCandidate(id: "c1", decision: "STAGE_FOR_HUMAN")]
        model.trainingRuns = runs
        model.trainingProposals = proposals
        model.promotionCandidates = candidates

        let flag = FireFlag()
        withObservationTracking {
            _ = model.trainingRuns
            _ = model.trainingProposals
            _ = model.promotionCandidates
        } onChange: {
            flag.fired = true
        }

        model.setIfChanged(\.trainingRuns, runs)
        model.setIfChanged(\.trainingProposals, proposals)
        model.setIfChanged(\.promotionCandidates, candidates)

        #expect(flag.fired == false, "an unchanged refreshAll must not redraw Self-Improvement")
    }

    @Test func changed_payload_still_writes() {
        let model = AppModel()
        model.trainingRuns = [PerfWave2Fixtures.trainingRun(id: "r1", verdict: "PASS")]

        let flag = FireFlag()
        withObservationTracking {
            _ = model.trainingRuns
        } onChange: {
            flag.fired = true
        }

        model.setIfChanged(\.trainingRuns, [PerfWave2Fixtures.trainingRun(id: "r1", verdict: "REGRESSION")])

        #expect(flag.fired == true)
        #expect(model.trainingRuns.first?.verdict == "REGRESSION")
    }

    /// Guard: `refreshAll` must not regain a bare assignment for these three.
    @Test func refreshAll_routes_all_three_through_setIfChanged() throws {
        let source = try AppSourceScraping.appSource("AppModel+Refresh.swift")
        for field in ["trainingRuns", "trainingProposals", "promotionCandidates"] {
            #expect(
                source.contains("setIfChanged(\\.\(field),"),
                "\(field) lost its equality gate in refreshAll"
            )
            #expect(
                source.range(of: "\n        \(field) = fetched") == nil,
                "\(field) regained a bare (ungated) assignment in refreshAll"
            )
        }
    }
}

// MARK: - F14 follow-up: whatsRunning writer coalescing

@Suite("Perf wave 2 — whatsRunning idle-poll coalescing")
@MainActor
struct WhatsRunningCoalescingTests {

    private func status(
        attempt: TimeInterval,
        success: TimeInterval?,
        failed: [String]
    ) -> AppModel.PanelRefreshStatus {
        AppModel.PanelRefreshStatus(
            lastAttemptAt: Date(timeIntervalSince1970: attempt),
            lastSuccessAt: success.map { Date(timeIntervalSince1970: $0) },
            failedEndpoints: failed
        )
    }

    /// The whole reason the helper is safe here: `WhatsRunningPresentation`
    /// projects exactly three things off the status — nil-ness, `isStale`, and
    /// `lastSuccessAt != nil`. This walks every transition and asserts the
    /// coalesced status renders IDENTICALLY to the always-stamp version.
    @Test func coalesced_status_renders_identically_across_every_transition() {
        let snapshot = WhatsRunning(items: [], count: 0)
        let transitions: [(previous: AppModel.PanelRefreshStatus?, failed: [String])] = [
            (nil, []),                                                  // first-ever success
            (nil, ["running work"]),                                    // first-ever failure
            (status(attempt: 100, success: 100, failed: []), []),       // idle success → success
            (status(attempt: 100, success: 100, failed: []), ["running work"]), // success → failure
            (status(attempt: 100, success: 100, failed: ["running work"]), ["running work"]), // failure → same failure, had a last-good
            (status(attempt: 100, success: nil, failed: ["running work"]), ["running work"]), // failure → same failure, never succeeded
            (status(attempt: 100, success: nil, failed: ["running work"]), []), // failure → recovery
        ]
        let now = Date(timeIntervalSince1970: 500)

        for (previous, failed) in transitions {
            let alwaysStamp = AppModel.nextRefreshStatus(
                previous: previous, failedEndpoints: failed, at: now
            )
            let toStore = AppModel.staleFlagOnlyStatusToStore(
                previous: previous, failedEndpoints: failed, at: now
            )
            // What the field actually holds after the coalesced write.
            let coalesced = toStore ?? previous

            #expect(
                WhatsRunningPresentation.make(snapshot: snapshot, status: coalesced)
                    == WhatsRunningPresentation.make(snapshot: snapshot, status: alwaysStamp),
                "coalescing changed what the panel renders for failed=\(failed), previous=\(String(describing: previous?.failedEndpoints))"
            )
        }
    }

    /// The waste being removed: an idle, fully-successful poll writes nothing.
    @Test func idle_successful_poll_stores_nothing() {
        let previous = status(attempt: 100, success: 100, failed: [])
        #expect(AppModel.staleFlagOnlyStatusToStore(
            previous: previous, failedEndpoints: [], at: Date(timeIntervalSince1970: 500)
        ) == nil)
    }

    /// Guard: the snapshot write must stay equality-gated too. Gating only the
    /// status would buy nothing — `WhatsRunningPanel` reads `whatsRunning`
    /// directly, so the snapshot write is what was redrawing it.
    @Test func loadWhatsRunning_gates_both_the_snapshot_and_the_status() throws {
        let source = try AppSourceScraping.appSource("AppModel+HealthEmbeddings.swift")
        let body = try #require(AppSourceScraping.looseFunctionBody(named: "loadWhatsRunning", in: source))
        #expect(body.contains("if whatsRunning != fetched { whatsRunning = fetched }"),
                "the whatsRunning snapshot lost its equality gate")
        #expect(body.contains("staleFlagOnlyStatusToStore"),
                "the whatsRunning status writer lost its coalescing")
        #expect(!body.contains("whatsRunningRefreshStatus = Self.nextRefreshStatus"),
                "an unconditional status stamp came back")
    }

    @MainActor
    @Test func identical_snapshot_performs_no_observable_write() {
        let model = AppModel()
        let snapshot = WhatsRunning(items: [], count: 0)
        model.whatsRunning = snapshot

        let flag = FireFlag()
        withObservationTracking {
            _ = model.whatsRunning
        } onChange: {
            flag.fired = true
        }
        if model.whatsRunning != snapshot { model.whatsRunning = snapshot }
        #expect(flag.fired == false)
    }
}

// MARK: - F10: shared, byte-bounded attachment image cache

@Suite("Perf wave 2 — F10 shared image cache")
struct ChatImageCacheTests {

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    /// Same pixels: a hit returns the exact object the miss stored — no
    /// downsample, no re-encode.
    @Test func store_then_fetch_returns_the_same_decoded_image() throws {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let key = "unit-test-identity-\(UUID().uuidString)"
        ChatImageCache.store(image, forKey: key)
        let hit = try #require(ChatImageCache.image(forKey: key))
        #expect(hit === image)
    }

    /// Bounded BY BYTES: cost is decoded pixel bytes, so a big image costs more
    /// than a small one by area — an entry-count bound would treat them alike.
    @Test func cost_is_pixel_bytes_not_entry_count() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("na-imgcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let small = dir.appendingPathComponent("small.png")
        let large = dir.appendingPathComponent("large.png")
        try writePNG(to: small, width: 8, height: 8)
        try writePNG(to: large, width: 64, height: 64)

        let smallImage = try #require(NSImage(contentsOf: small))
        let largeImage = try #require(NSImage(contentsOf: large))
        let smallCost = ChatImageCache.pixelByteCost(smallImage)
        let largeCost = ChatImageCache.pixelByteCost(largeImage)

        #expect(smallCost == 8 * 8 * 4)
        #expect(largeCost == 64 * 64 * 4)
        #expect(largeCost > smallCost)
    }

    /// Never zero-cost — a zero-cost NSCache entry is never evicted by the byte
    /// budget, which is how a "bounded" cache quietly becomes unbounded.
    @Test func degenerate_image_still_carries_a_nonzero_cost() {
        #expect(ChatImageCache.pixelByteCost(NSImage(size: .zero)) >= 1)
    }

    /// Correctness of the key: a file rewritten in place must MISS, or the
    /// bubble would render the old pixels forever.
    @Test func identity_key_changes_when_the_file_contents_change() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("na-imgkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("shot.png")
        try writePNG(to: url, width: 8, height: 8)
        let first = try #require(ChatImageCache.identityKey(for: url))

        try writePNG(to: url, width: 64, height: 64)
        let second = try #require(ChatImageCache.identityKey(for: url))

        #expect(first != second, "same path, different bytes must not share a cache entry")
        #expect(first.hasPrefix(url.path))
    }

    /// A file that cannot be stat'd yields no key, so the caller skips the
    /// cache instead of storing under a guessed one.
    @Test func missing_file_has_no_identity_key() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("na-absent-\(UUID().uuidString).png")
        #expect(ChatImageCache.identityKey(for: url) == nil)
    }
}

// MARK: - F1: detached panel scroll throttle (structural guard)

@Suite("Perf wave 2 — F1 detached panel scroll throttle")
struct DetachedPanelScrollThrottleTests {

    /// Throttle-only. The panel must route streaming deltas through the shared
    /// coordinator AND must not gain the `autoFollow` disarm, which is the held
    /// NEEDS-USER behavior change.
    @Test func panel_throttles_streaming_deltas_without_adding_disarm() throws {
        let source = try AppSourceScraping.appSource("DetachedChatPanelView.swift")
        #expect(source.contains("@State private var scrollCoordinator = ChatScrollCoordinator()"))
        #expect(source.contains("scrollCoordinator.scrollToBottom("),
                "streaming deltas must go through the coordinator")
        #expect(source.contains("scrollCoordinator.markViewDisappeared()"),
                "a scheduled scroll must be invalidated when the panel closes")
        // Executable calls only — the file's own doc comment NAMES the held
        // behavior ("nothing in this panel ever calls disarmFollow()"), so a
        // raw substring check would fail on the explanation of the rule.
        #expect(AppSourceScraping.executableCalls(named: "disarmFollow", in: source).isEmpty,
                "autoFollow disarm is a behavior change held as NEEDS-USER — it must not land here")
        #expect(AppSourceScraping.executableCalls(named: "forceFollow", in: source).isEmpty,
                "forceFollow is part of the same held disarm/rearm behavior")
    }

    /// The coordinator's `autoFollow` gate is a no-op in the panel only because
    /// it starts armed and nothing there disarms it. If that default ever
    /// flips, the panel silently stops following the stream.
    @MainActor
    @Test func coordinator_starts_armed_so_the_gate_is_a_noop_for_the_panel() {
        #expect(ChatScrollCoordinator().autoFollow == true)
    }

    /// The throttle floor: non-animated scrolls are spaced ≥0.16 s, i.e. ≤~6 Hz
    /// against the ~14 Hz coalesced delta rate.
    @MainActor
    @Test func nonanimated_scroll_floor_is_at_most_six_hertz() throws {
        let source = try AppSourceScraping.appSource("ChatViewStateCoordinators.swift")
        let body = try AppSourceScraping.functionBody(named: "scrollToBottom", in: source)
        #expect(body.contains("animated ? 0.12 : 0.16"))
        #expect(1.0 / 0.16 <= 6.25)
    }
}

// MARK: - RenderAudit instrumentation

@Suite("Perf wave 2 — render-audit instrumentation")
struct RenderAuditInstrumentationTests {

    /// Zero cost when off: `bump` must return on the env flag before touching
    /// the lock or the dictionary. The suite runs without the env var set.
    @Test func bump_is_inert_when_the_env_gate_is_off() {
        #expect(RenderAudit.shared.enabled == false,
                "the test suite must not run with NATIVE_AGENT_RENDER_AUDIT=1")
        // Non-crashing, allocation-free no-op. If the guard were removed this
        // would still pass, so the guard itself is asserted structurally below.
        for _ in 0..<1000 { RenderAudit.bump("perf-wave-2-inert-probe") }
    }

    @Test func bump_guards_on_enabled_before_doing_any_work() throws {
        let source = try AppSourceScraping.appSource("ChatMessageListView.swift")
        let body = try AppSourceScraping.functionBody(named: "_bump", in: source)
        let guardIndex = try #require(body.range(of: "guard enabled else { return }")).lowerBound
        let lockIndex = try #require(body.range(of: "lock.lock()")).lowerBound
        #expect(guardIndex < lockIndex, "the env gate must precede all work in _bump")
    }

    /// The counters that make the wave measurable rather than argued.
    @Test func root_and_selfimprovement_bodies_are_instrumented() throws {
        let contentView = try AppSourceScraping.appSource("ContentView.swift")
        #expect(contentView.contains("RenderAudit.bump(\"contentview.body\")"))
        let selfImprovement = try AppSourceScraping.appSource("SelfImprovementView.swift")
        #expect(selfImprovement.contains("RenderAudit.bump(\"selfimprovement.body\")"))
    }
}
