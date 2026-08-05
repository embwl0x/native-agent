import Foundation
import Observation
import PersistenceCore

// MARK: - Turn Inspector W3 — store (live subscription lifecycle + replay load)
//
// Owns the event buffer for the Inspector tab and the lifecycle of the live
// `TurnTraceBus` subscription. The bus is fire-and-forget + drop-on-backpressure
// (the U5 lesson is canon), so the store only ever CONSUMES — it never awaits
// into emission, and a slow UI can never apply backpressure to Agent's turn.
//
// LIFECYCLE CONTRACT (brief): subscribe on tab open, UNSUBSCRIBE on close — no
// leaked subscriptions. `start()` is idempotent; `stop()` tears the consume task
// down AND unsubscribes the bus sink (which also `.finish()`es the stream).

@MainActor
@Observable
final class TurnInspectorStore {

    enum Mode: String, CaseIterable, Identifiable {
        case live = "Live"
        case replay = "Replay"
        var id: String { rawValue }
    }

    // MARK: Observed state

    private(set) var mode: Mode = .live
    /// Newest-turn-first cards for the current mode's events.
    private(set) var cards: [InspectorTurnCard] = []
    /// Live drop count surfaced from the bus subscription (slow-consumer signal).
    private(set) var liveDropCount: Int = 0
    /// Replay diagnostics.
    private(set) var replayDate: Date = Date()
    private(set) var replaySkipped: Int = 0
    private(set) var replayLoading = false
    private(set) var replayFileExists = true

    // MARK: Internals

    /// Bounded live ring of recent events (newest kept). Bounds the UI's memory
    /// independent of the bus — a long-running tab can't grow without limit.
    private var liveEvents: [TurnTraceEvent] = []
    private static let liveEventCap = 4000

    private var replayEvents: [TurnTraceEvent] = []

    private var consumeTask: Task<Void, Never>?
    /// Monotonic generation: each `start()` bumps it. The consume task captures
    /// its generation and ignores events / drop-counts once superseded — closes
    /// the start/stop race where a teardown lands while `subscribe()` is still
    /// awaiting (a non-throwing actor call that cancellation can't abort).
    private var liveGeneration = 0
    private var replayGeneration = 0
    /// Resolved at read time via the persist lane so replay honors the SAME
    /// root (env / static override / instance) the live lane writes to. A nil
    /// `dataRootOverride` → the lane resolves the live/overridden root; tests
    /// pass an explicit root.
    private let replayLane: TurnTracePersistLane

    init(dataRootOverride: URL? = nil) {
        self.replayLane = TurnTracePersistLane(dataRootOverride: dataRootOverride)
    }

    // MARK: Live subscription

    /// Subscribe to the shared bus and begin draining events into `liveEvents`.
    /// Idempotent — a second call while already running is a no-op.
    ///
    /// The consume task OWNS the subscription end-to-end: it subscribes, and a
    /// `defer` unsubscribes on ANY exit (cancel, stream end, generation bump).
    /// Right after `subscribe()` returns it checks for cancellation / a stale
    /// generation and bails — so a `stop()` that raced the in-flight subscribe
    /// still tears the sink down rather than leaking it.
    func start() {
        guard consumeTask == nil else { return }
        liveGeneration += 1
        // Fresh subscription, fresh diagnostics (gpt-5.5 W3 review: a reopened
        // Inspector showed the PRIOR generation's drop count until the first
        // new event re-polled it).
        liveDropCount = 0
        let generation = liveGeneration
        consumeTask = Task { [weak self] in
            let sub = await TurnTraceBus.shared.subscribe()
            // Always release the sink on exit (the bus .finish()es the stream).
            defer { Task { await TurnTraceBus.shared.unsubscribe(sub.id) } }
            // Raced teardown: a stop()/restart bumped the generation (or the
            // task was cancelled) while we were awaiting subscribe(). Bail now;
            // the defer unsubscribes the just-created sink.
            if Task.isCancelled { return }
            let stale = await MainActor.run { [weak self] in
                self?.liveGeneration != generation
            }
            if stale { return }
            for await event in sub.stream {
                if Task.isCancelled { break }
                let keepGoing = await MainActor.run { [weak self] () -> Bool in
                    guard let self, self.liveGeneration == generation else { return false }
                    self.ingestLive(event, subscriptionId: sub.id)
                    return true
                }
                if !keepGoing { break }
            }
        }
    }

    /// Tear down the live subscription. Bumps the generation (so the in-flight
    /// consume task bails + unsubscribes via its `defer`) and cancels the task.
    /// The bus sink is removed by the task's `defer`, not here — that's the one
    /// place that always owns a valid sub.id. Safe to call repeatedly.
    func stop() {
        liveGeneration += 1
        consumeTask?.cancel()
        consumeTask = nil
        // Drop any pending drop-count poll from the now-dead subscription so a
        // stale count can't be re-armed under the next generation.
        pendingDropCheck = nil
        // Land whatever the debounce was holding. Dropping it instead would
        // leave `cards` missing the final events of the session AND leave
        // `cardsRefreshScheduled` latched true, so the next `start()` would
        // never schedule again.
        flushPendingCardsRefresh()
    }

    private func ingestLive(_ event: TurnTraceEvent, subscriptionId: UUID) {
        appendLive(event)
        // Tag the pending poll with the CURRENT generation so a poll queued by a
        // dead subscription can't survive a stop()/restart.
        pendingDropCheck = (subscriptionId, liveGeneration)
        scheduleDropRefresh()
    }

    /// Ring append + debounced regroup. Split out of `ingestLive` so the
    /// F12 debounce tests drive the PRODUCTION path rather than a re-typed
    /// copy of it — standing up a real bus subscription in a test would also
    /// push trace events through the shared persist lane, which is the
    /// hermeticity trap this repo already paid for once.
    private func appendLive(_ event: TurnTraceEvent) {
        liveEvents.append(event)
        // Bound the ring: drop oldest beyond the cap.
        if liveEvents.count > Self.liveEventCap {
            liveEvents.removeFirst(liveEvents.count - Self.liveEventCap)
        }
        if mode == .live { scheduleCardsRefresh() }
    }

    /// Test seam: the live-ingest path minus the bus subscription.
    func _appendLiveForTesting(_ event: TurnTraceEvent) {
        appendLive(event)
    }

    /// Coalesced drop-count poll: at most one in-flight bus query regardless of
    /// event volume (the per-event Task spawn the reviewer flagged is gone). The
    /// pending entry carries its generation; both the SCHEDULE and the APPLY are
    /// guarded so a stale count from a dead subscription never lands on the new
    /// live session.
    private var pendingDropCheck: (id: UUID, generation: Int)?
    private var dropRefreshInFlight = false
    private func scheduleDropRefresh() {
        guard !dropRefreshInFlight, let pending = pendingDropCheck else { return }
        // Stale pending (generation moved on) → discard, don't poll.
        guard pending.generation == liveGeneration else {
            pendingDropCheck = nil
            return
        }
        dropRefreshInFlight = true
        pendingDropCheck = nil
        let generation = pending.generation
        let id = pending.id
        Task { [weak self] in
            let drops = await TurnTraceBus.shared.dropCount(id)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.dropRefreshInFlight = false
                if self.liveGeneration == generation { self.liveDropCount = drops }
                // Pick up any drop check that arrived while this one was in flight.
                self.scheduleDropRefresh()
            }
        }
    }

    // MARK: Mode switching

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        // A live-ingest debounce still in flight would fire under the NEW mode
        // and regroup the wrong source. Drop it; both branches below recompute.
        cancelPendingCardsRefresh()
        mode = newMode
        if newMode == .replay {
            Task { await loadReplay(for: replayDate) }
        } else {
            recomputeCards()
        }
    }

    func clearLive() {
        // User-initiated: the list must empty NOW, not up to a debounce later.
        cancelPendingCardsRefresh()
        liveEvents.removeAll()
        if mode == .live { recomputeCards() }
    }

    // MARK: Replay

    /// Load the persisted per-day file for `date`, off the main actor, and
    /// regroup. Parse failures are skipped (counted), an absent file is an
    /// empty (not error) state. A generation token guards against overlapping
    /// loads (rapid date changes) applying out of order — only the NEWEST
    /// in-flight load is allowed to mutate state.
    func loadReplay(for date: Date) async {
        replayGeneration += 1
        let generation = replayGeneration
        replayDate = date
        replayLoading = true
        // Resolve the file under the SAME root the live lane writes to.
        let root = replayLane.resolvedDataRoot()
        let url = TurnTraceReplayReader.fileURL(for: date, root: root)
        // Read + parse off the main actor (file can be up to the 20k-line cap).
        let result = await Task.detached(priority: .userInitiated) {
            let exists = FileManager.default.fileExists(atPath: url.path)
            let parsed = TurnTraceReplayReader.read(url)
            return (exists: exists, events: parsed.events, skipped: parsed.skipped)
        }.value
        // A newer load superseded this one while we were reading — discard.
        guard generation == replayGeneration else { return }
        replayFileExists = result.exists
        replayEvents = result.events
        replaySkipped = result.skipped
        replayLoading = false
        if mode == .replay {
            // Same reason as `setMode`: a live-ingest debounce landing after
            // this would regroup with the wrong source.
            cancelPendingCardsRefresh()
            recomputeCards()
        }
    }

    // MARK: Card recompute

    /// Render-cost audit F12 — coalesced card recompute.
    ///
    /// `recomputeCards()` re-buckets, per-bucket-sorts, re-allocates every row
    /// and final-sorts the whole ring (cap 4000), then wholesale replaces the
    /// observed `cards` array — so every `Identifiable` row is a new object and
    /// the `ForEach` re-diffs the entire list. Firing that once per trace event
    /// is O(n log n) per event, i.e. O(n² log n) over a session, and while the
    /// Inspector tab is open during a live turn it was the hottest loop in the
    /// app.
    ///
    /// This is a trailing debounce with the same ownership shape as
    /// `scheduleDropRefresh()` above: one in-flight token, re-armed by the
    /// events that arrive during the window, so N events in a window cost ONE
    /// regroup instead of N.
    ///
    /// **Deliberately debounce-only.** Incremental append (the other half of
    /// F12) would change what the grouping produces and is held as a separate
    /// NEEDS-USER item. Debouncing changes only *when* rows appear — batched by
    /// at most `cardsDebounceSeconds` on a developer-gated diagnostics tab —
    /// and every user-initiated transition (`setMode`, `clearLive`,
    /// `loadReplay`, `stop`) cancels or flushes the pending window, so nothing
    /// the user asked for is ever deferred.
    private static let cardsDebounceSeconds: TimeInterval = 0.1
    private var cardsRefreshScheduled = false
    private var cardsRefreshTask: Task<Void, Never>?

    private func scheduleCardsRefresh() {
        guard !cardsRefreshScheduled else { return }
        cardsRefreshScheduled = true
        cardsRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.cardsDebounceSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.cardsRefreshTask = nil
            self.cardsRefreshScheduled = false
            self.recomputeCards()
        }
    }

    /// Drop a pending window without regrouping. The caller is about to
    /// recompute (or replace the source) itself.
    private func cancelPendingCardsRefresh() {
        cardsRefreshTask?.cancel()
        cardsRefreshTask = nil
        cardsRefreshScheduled = false
    }

    /// Drop a pending window and apply it immediately.
    private func flushPendingCardsRefresh() {
        guard cardsRefreshScheduled else { return }
        cancelPendingCardsRefresh()
        recomputeCards()
    }

    /// Test seam: drive the debounce to completion deterministically instead of
    /// racing `cardsDebounceSeconds` in a test.
    func _flushPendingCardsRefreshForTesting() {
        flushPendingCardsRefresh()
    }

    /// Test seam: true while a debounced regroup is armed.
    var _hasPendingCardsRefreshForTesting: Bool { cardsRefreshScheduled }

    private func recomputeCards() {
        let source = (mode == .live) ? liveEvents : replayEvents
        cards = TurnInspectorGrouping.group(source)
    }
}
