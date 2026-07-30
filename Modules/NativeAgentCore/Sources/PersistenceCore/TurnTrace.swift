import Foundation
import CryptoKit
import NativeAgentCore

// MARK: - Turn Inspector W1 (turn-inspector build plan, ledger d6143561)
//
// The turnId SPINE + in-process multicast BUS + persist lane that correlate
// every event of one chat turn into a single replayable story. This is the
// foundation the W2 emission points, W3 Mac Inspector tab, and W4 iOS summary
// lane all build on. W1 does NOT add new emission points — it threads turnId
// through the THREE existing emitters (llm.call, tool.dispatch, memory.commit)
// and mirrors each onto the bus.
//
// LIVES IN PersistenceCore because it is the lowest common module the three
// emitters can all see: `llm.call` is written from ProviderRouting, and
// `tool.dispatch` / `memory.commit` from ChatOrchestration — both depend on
// PersistenceCore, and PersistenceCore already owns `JSONValue`,
// `appendJSONLCapped`, `withFileLock`, and `defaultDataRoot()`.
//
// THE U5 LESSON IS CANON: a slow observer must NEVER slow the turn. Emission
// is fire-and-forget. The bus never awaits a subscriber; a subscriber whose
// bounded buffer is full drops the event (counted per subscriber). The persist
// lane runs on a detached utility task off the hot path.

// MARK: - TurnTraceContext (request-scoped turnId spine)

/// Task-local turn correlation id, bound ONCE per chat turn at the turn-engine
/// entry (SwiftNativeTurnEngine.streamTurn / .executeTurnWithToolLoop). Every
/// surface that runs a turn through the engine inherits it for free, and it
/// propagates into the unstructured `Task {}` / `AsyncThrowingStream` inner
/// tasks the same way `LLMCallContext.sessionId` does (the binding wraps the
/// synchronous work that creates the inner task; the task inherits the value
/// at creation).
///
/// Unbound (nil) → emitters tag rows with turnId "unknown" and the bus mirror
/// is skipped (an event with no turn has no story to join). This keeps any
/// non-turn caller (a direct tool dispatch, a background loop's LLM call)
/// byte-identical to pre-W1 behavior on the persist lane EXCEPT for the
/// additive turnId field, which reads "unknown".
public enum TurnTraceContext {
    @TaskLocal public static var turnId: String?
    /// Optional request-scoped bus override for hermetic tests and diagnostics.
    /// Production leaves this nil so context-based emitters mirror to `.shared`.
    @TaskLocal public static var bus: TurnTraceBus?

    /// Mint a fresh UUID-based turn id. Lowercased to match the row-id
    /// convention used across the trace writers.
    public static func mintTurnId() -> String {
        UUID().uuidString.lowercased()
    }

}

/// Correlates the Mac UI's first visible assistant bubble with the turn trace
/// without putting UI concerns into the provider loop. Entries are bounded and
/// single-claim: an old bubble or a later delta cannot emit a duplicate render.
public actor TurnFirstRenderRegistry {
    public static let shared = TurnFirstRenderRegistry()

    private struct Pending: Sendable {
        let turnId: String
        let surface: String
        let registeredAtUptimeNs: UInt64
    }

    private let maximumEntries: Int
    private var pendingBySession: [String: Pending] = [:]
    private var insertionOrder: [String] = []

    public init(maximumEntries: Int = 256) {
        self.maximumEntries = max(1, maximumEntries)
    }

    public func register(turnId: String, sessionId: String, surface: String) {
        let session = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !turnId.isEmpty, !session.isEmpty else { return }
        if pendingBySession[session] == nil { insertionOrder.append(session) }
        pendingBySession[session] = Pending(
            turnId: turnId,
            surface: surface,
            registeredAtUptimeNs: DispatchTime.now().uptimeNanoseconds
        )
        while insertionOrder.count > maximumEntries {
            pendingBySession.removeValue(forKey: insertionOrder.removeFirst())
        }
    }

    public func claimFirstRenderEvent(
        sessionId: String,
        observedBy: String
    ) -> TurnTraceEvent? {
        let session = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, let pending = pendingBySession.removeValue(forKey: session) else {
            return nil
        }
        insertionOrder.removeAll { $0 == session }
        let elapsedMs = Int64(
            (DispatchTime.now().uptimeNanoseconds &- pending.registeredAtUptimeNs) / 1_000_000
        )
        return TurnTraceEvent(
            turnId: pending.turnId,
            kind: "surface.firstRender",
            sessionId: session,
            surface: pending.surface,
            payload: .object([
                "schema": .string("turn.lifecycle.v1"),
                "milestone": .string("surface.firstRender"),
                "observedBy": .string(observedBy),
                "elapsedMs": .int(elapsedMs),
            ])
        )
    }
}

// MARK: - TurnTraceEvent (the canonical W1 event schema)

/// One event in a turn's story. Built at each tagged emitter and handed to
/// `TurnTraceBus.emit`, which mirrors it to live subscribers AND appends it to
/// the per-day persist lane.
///
/// PRIVACY (hard constraint, same discipline as the existing trace writers):
/// the payload is PRE-REDACTED at construction — never raw prompt/completion
/// bodies, never bot tokens. String fields are bounded to
/// `maxPayloadStringChars` so an oversized field can't bloat the feed.
public struct TurnTraceEvent: Sendable, Equatable {
    /// Per-string-field cap applied to every string LEAF in the payload.
    public static let maxPayloadStringChars = 2000
    /// Hard serialized-payload ceiling. A leaf cap alone does not bound arrays
    /// or objects with many individually small fields; one diagnostic result
    /// previously produced a 41 KB trace row despite every leaf being legal.
    public static let maxPayloadBytes = 12 * 1024
    private static let oversizedPreviewBytes = 6 * 1024

    public let turnId: String
    public let ts: Date
    public let kind: String
    public let sessionId: String?
    public let surface: String?
    /// Pre-redacted, bounded payload object. Construction runs every string
    /// leaf through `boundString`.
    public let payload: JSONValue

    public init(
        turnId: String,
        ts: Date = Date(),
        kind: String,
        sessionId: String? = nil,
        surface: String? = nil,
        payload: JSONValue = .object([:])
    ) {
        self.turnId = turnId
        self.ts = ts
        self.kind = kind
        self.sessionId = sessionId
        self.surface = surface
        self.payload = TurnTraceEvent.boundPayload(payload)
    }

    /// Bound every string leaf of a JSONValue tree to `maxPayloadStringChars`,
    /// then enforce a hard serialized byte ceiling over the whole payload.
    /// Oversized payloads retain stable lifecycle fields plus a bounded JSON
    /// preview, original byte count, and digest so truncation remains explicit
    /// without making the per-day ledger unbounded.
    static func boundPayload(_ value: JSONValue) -> JSONValue {
        let leafBound = boundLeaves(value)
        guard let serialized = try? leafBound.serializedData(pretty: false),
              serialized.count > maxPayloadBytes else {
            return leafBound
        }

        var summary: [String: JSONValue] = [
            "_truncated": .bool(true),
            "_originalBytes": .int(Int64(serialized.count)),
            "_sha256": .string(
                SHA256.hash(data: serialized)
                    .map { String(format: "%02x", $0) }
                    .joined()
            ),
            "_preview": .string(
                String(decoding: serialized.prefix(oversizedPreviewBytes), as: UTF8.self)
                + "…[payload byte limit]"
            ),
        ]
        if case .object(let object) = leafBound {
            let stableKeys = [
                "schema", "phase", "status", "name", "tool", "stage",
                "milestone", "provider", "model", "resultClass",
                "durationMs", "elapsedMs", "inputTokens", "outputTokens",
                "argKeys",
            ]
            for key in stableKeys {
                guard let field = object[key],
                      let bytes = try? field.serializedData(pretty: false),
                      bytes.count <= 1_024 else { continue }
                summary[key] = field
            }
        }
        let bounded = JSONValue.object(summary)
        if let data = try? bounded.serializedData(pretty: false),
           data.count <= maxPayloadBytes {
            return bounded
        }
        // Defensive fallback if future stable fields collectively grow. The
        // digest and byte count remain; only the preview shrinks.
        summary["_preview"] = .string(
            String(decoding: serialized.prefix(2 * 1024), as: UTF8.self)
            + "…[payload byte limit]"
        )
        return .object(summary)
    }

    private static func boundLeaves(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s):
            return .string(boundString(s))
        case .array(let arr):
            return .array(arr.map { boundLeaves($0) })
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(obj.count)
            for (k, v) in obj { out[k] = boundLeaves(v) }
            return .object(out)
        case .null, .bool, .int, .double:
            return value
        }
    }

    static func boundString(_ s: String) -> String {
        let cap = maxPayloadStringChars
        guard s.count > cap else { return s }
        // Keep the newest-truncation honest: prefix kept, marker appended.
        let prefix = String(s.prefix(cap))
        return prefix + "…[+\(s.count - cap) chars]"
    }

    /// Decode one persisted JSONL row back into a `TurnTraceEvent` — the inverse
    /// of `jsonRow`, used by the W3 replay lane to reconstruct events off disk.
    /// Returns nil for a malformed row (missing required field, bad ts) so the
    /// replay reader can SKIP it and keep going rather than crash on one bad
    /// line. `ts` parses ISO8601 (the format `jsonRow` writes); a row whose ts
    /// can't be parsed is rejected (a turn event with no honest timestamp can't
    /// be placed on the timeline).
    ///
    /// Note: re-bounds string leaves through the same `boundPayload` the
    /// `init` applies (defense in depth — a hand-edited or pre-cap row can't
    /// smuggle an oversized leaf into the live UI).
    public init?(jsonRow value: JSONValue) {
        guard case .object(let obj) = value,
              case .string(let turnId)? = obj["turnId"],
              case .string(let kind)? = obj["kind"],
              case .string(let tsString)? = obj["ts"],
              // Per-call formatter: ISO8601DateFormatter is NOT thread-safe, and
              // replay rows decode off concurrent tasks. Constructing one per
              // call is cheap relative to the bounded (≤20k-line) file.
              // Fractional first (current write format), plain second (rows
              // persisted before the sub-second fix).
              let ts = Self.parseISO8601(tsString)
        else { return nil }
        var sessionId: String? = nil
        if case .string(let s)? = obj["sessionId"] { sessionId = s }
        var surface: String? = nil
        if case .string(let s)? = obj["surface"] { surface = s }
        let payload = obj["payload"] ?? .object([:])
        self.init(
            turnId: turnId,
            ts: ts,
            kind: kind,
            sessionId: sessionId,
            surface: surface,
            payload: payload
        )
    }

    /// Parse a persisted ts: fractional-seconds ISO8601 (the current write
    /// format) with a plain-seconds fallback for rows persisted before the
    /// sub-second fix. Per-call formatters — ISO8601DateFormatter is not
    /// thread-safe.
    static func parseISO8601(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    /// The persisted JSONL row shape. Matches the {turnId, ts, kind,
    /// sessionId?, surface?, payload} schema in the W1 brief. `ts` is ISO8601
    /// WITH FRACTIONAL SECONDS: persistence off the bus is fire-and-forget, so
    /// file append order is NOT emission order — whole-second timestamps made
    /// same-second events tie and replay shuffled them (a begin rendered after
    /// its end, observed live 2026-06-12). Sub-second ts restores an honest
    /// chronological replay sort without relying on file order.
    public var jsonRow: JSONValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var obj: [String: JSONValue] = [
            "turnId": .string(turnId),
            // Inline formatter (per-call) — same pattern as the other trace
            // writers; ISO8601DateFormatter is not Sendable so it can't be a
            // shared static.
            "ts": .string(formatter.string(from: ts)),
            "kind": .string(kind),
            "payload": payload,
        ]
        if let sessionId { obj["sessionId"] = .string(sessionId) }
        if let surface { obj["surface"] = .string(surface) }
        return .object(obj)
    }
}

// MARK: - TurnTraceBus (in-process multicast, drop-on-backpressure)

/// In-process multicast for live turn events. Subscribers register a bounded
/// buffer; `emit` is fire-and-forget and NEVER awaits a subscriber. When a
/// subscriber's buffer is full the event is DROPPED for that subscriber and the
/// drop is counted — a slow observer (the Inspector tab on a busy turn) can
/// never apply backpressure to Agent's turn.
///
/// The bus is an `actor` so the subscriber table mutates safely under
/// concurrency, but `emit` hands off to the actor on a detached task and the
/// caller does NOT await it — the hot path pays only the cost of spawning the
/// hand-off (and the synchronous persist-lane enqueue, also detached).
public actor TurnTraceBus {
    public static let shared = TurnTraceBus()

    /// Default per-subscriber ring capacity. Bounded so a stalled consumer
    /// can't grow memory without limit.
    public static let defaultBufferCapacity = 512

    public struct Subscription: Sendable {
        public let id: UUID
        public let stream: AsyncStream<TurnTraceEvent>
        init(id: UUID, stream: AsyncStream<TurnTraceEvent>) {
            self.id = id
            self.stream = stream
        }
    }

    private struct Sink {
        let continuation: AsyncStream<TurnTraceEvent>.Continuation
        let capacity: Int
        var inFlight: Int
        var drops: Int
    }

    private var sinks: [UUID: Sink] = [:]

    /// Persistence is a separate, per-bus bounded FIFO. The global ingress
    /// pump must only wait for the actor's nonblocking live delivery; waiting
    /// for a flock'd disk append here let one diagnostic burst delay terminal
    /// traces for unrelated live turns by seconds.
    private nonisolated let persistPump: _PersistPump
    private let deliveryGate: (@Sendable () async -> Void)?

    public init(persistLane: TurnTracePersistLane = TurnTracePersistLane()) {
        self.persistPump = _PersistPump(lane: persistLane, capacity: 4096)
        self.deliveryGate = nil
    }

    /// Internal fault-injection seam used to prove that the public fire gate
    /// stays bounded when actor delivery is stalled. Production has no gate.
    init(
        persistLane: TurnTracePersistLane,
        deliveryGate: @escaping @Sendable () async -> Void
    ) {
        self.persistPump = _PersistPump(lane: persistLane, capacity: 4096)
        self.deliveryGate = deliveryGate
    }

    // MARK: Subscribe / unsubscribe

    /// Register a bounded subscriber. Returns a `Subscription` whose `stream`
    /// yields live events until `unsubscribe(id:)` is called or the consumer
    /// stops iterating (onTermination unregisters automatically).
    public func subscribe(
        capacity: Int = TurnTraceBus.defaultBufferCapacity
    ) -> Subscription {
        let id = UUID()
        let cap = max(1, capacity)
        let (stream, continuation) = AsyncStream<TurnTraceEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(cap)
        )
        sinks[id] = Sink(continuation: continuation, capacity: cap, inFlight: 0, drops: 0)
        continuation.onTermination = { [weak self] _ in
            // Consumer went away (cancel / break out of for-await). Detached so
            // we never await from the termination callback.
            Task { [weak self] in await self?.removeSink(id) }
        }
        return Subscription(id: id, stream: stream)
    }

    public func unsubscribe(_ id: UUID) {
        removeSink(id)
    }

    private func removeSink(_ id: UUID) {
        if let sink = sinks.removeValue(forKey: id) {
            sink.continuation.finish()
        }
    }

    /// Drop count observed for a subscriber so far (test + diagnostics hook).
    public func dropCount(_ id: UUID) -> Int {
        sinks[id]?.drops ?? 0
    }

    public var subscriberCount: Int { sinks.count }

    // MARK: Emit

    /// One bounded FIFO and at most one drain task replace the old one-detached-
    /// task-per-event handoff. Telemetry remains nonblocking and lossy under
    /// distress without allowing thousands of suspended task allocations.
    nonisolated static let emissionPump = _EmissionPump(capacity: 4096)

    final class _EmissionPump: @unchecked Sendable {
        struct Pending: Sendable {
            let event: TurnTraceEvent
            let bus: TurnTraceBus
        }
        private let lock = NSLock()
        private var queue: [Pending] = []
        private var head = 0
        private var draining = false
        private var dropped = 0
        let capacity: Int
        init(capacity: Int) { self.capacity = capacity }
        /// Returns true only when the caller must start the sole drain worker.
        func enqueue(_ pending: Pending) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard queue.count - head < capacity else {
                dropped += 1
                return false
            }
            queue.append(pending)
            guard !draining else { return false }
            draining = true
            return true
        }
        func next() -> Pending? {
            lock.lock(); defer { lock.unlock() }
            guard head < queue.count else {
                queue.removeAll(keepingCapacity: true)
                head = 0
                draining = false
                return nil
            }
            let value = queue[head]
            head += 1
            if head >= 256, head * 2 >= queue.count {
                queue.removeFirst(head)
                head = 0
            }
            return value
        }
        var snapshot: (inFlight: Int, dropped: Int) {
            lock.lock(); defer { lock.unlock() }
            return (queue.count - head, dropped)
        }
    }

    /// One writer task per bus, never one task per event. This preserves the
    /// persisted order for a turn while isolating a slow/test data root from
    /// every other bus using the process-wide ingress pump. Trace persistence
    /// remains explicitly lossy under sustained distress and bounded to 4096
    /// pending rows.
    private final class _PersistPump: @unchecked Sendable {
        private let lock = NSLock()
        private let lane: TurnTracePersistLane
        private let capacity: Int
        private var queue: [TurnTraceEvent] = []
        private var head = 0
        private var draining = false
        private var dropped = 0

        init(lane: TurnTracePersistLane, capacity: Int) {
            self.lane = lane
            self.capacity = capacity
        }

        func submit(_ event: TurnTraceEvent) {
            lock.lock()
            guard queue.count - head < capacity else {
                dropped += 1
                lock.unlock()
                return
            }
            queue.append(event)
            let shouldStart = !draining
            if shouldStart { draining = true }
            lock.unlock()

            guard shouldStart else { return }
            Task.detached(priority: .utility) { [self] in
                while let next = takeNext() {
                    await lane.append(next)
                }
            }
        }

        private func takeNext() -> TurnTraceEvent? {
            lock.lock(); defer { lock.unlock() }
            guard head < queue.count else {
                queue.removeAll(keepingCapacity: true)
                head = 0
                draining = false
                return nil
            }
            let value = queue[head]
            head += 1
            if head >= 256, head * 2 >= queue.count {
                queue.removeFirst(head)
                head = 0
            }
            return value
        }
    }

    /// Test/observability seam: current emission backlog + gate drops.
    public nonisolated static var emissionBacklog: (inFlight: Int, dropped: Int) {
        emissionPump.snapshot
    }

    /// Fire-and-forget emission entry. NEVER call from the hot path with
    /// `await` on the bus mutation — use this static shim, which spawns the
    /// actor hand-off detached so the caller pays only task-creation cost.
    /// In-flight emissions are BOUNDED (4096); over the cap the event drops
    /// at the gate so a stalled disk can never grow task backlog.
    ///
    /// The persist lane append is ALSO detached (off the caller's path). A
    /// nil-turnId event is dropped — it has no story to join (matches the
    /// "unbound → no mirror" contract of TurnTraceContext).
    public nonisolated static func fire(_ event: TurnTraceEvent, on bus: TurnTraceBus = .shared) {
        let shouldStart = emissionPump.enqueue(.init(event: event, bus: bus))
        guard shouldStart else { return }
        Task.detached(priority: .utility) {
            while let pending = emissionPump.next() {
                await pending.bus.deliver(pending.event)
            }
        }
    }

    /// Convenience: build + fire in one call, reading turnId/sessionId/surface
    /// off the ambient context when not supplied. Skips entirely when no turn
    /// is bound (the common non-turn caller).
    public nonisolated static func fireFromContext(
        kind: String,
        sessionId: String? = LLMCallContext.sessionId,
        surface: String? = LLMCallContext.surface,
        payload: JSONValue = .object([:]),
        on bus: TurnTraceBus? = nil
    ) {
        guard let turnId = TurnTraceContext.turnId else { return }
        let event = TurnTraceEvent(
            turnId: turnId,
            kind: kind,
            sessionId: sessionId,
            surface: surface,
            payload: payload
        )
        fire(event, on: bus ?? TurnTraceContext.bus ?? .shared)
    }

    /// Actor-isolated delivery: mirror to every live subscriber (drop-on-full,
    /// counted) and enqueue onto the persist lane. Subscribers are served
    /// synchronously within the actor but the per-subscriber yield is itself
    /// non-blocking (AsyncStream.yield never suspends).
    func deliver(_ event: TurnTraceEvent) async {
        if let deliveryGate { await deliveryGate() }
        for (id, var sink) in sinks {
            // `.bufferingNewest(cap)` means yield NEVER blocks; on overflow it
            // drops the OLDEST buffered value and reports `.dropped`. We also
            // track an explicit inFlight watermark so `drops` reflects the
            // backpressure even when the policy silently rotates the ring.
            let r = sink.continuation.yield(event)
            switch r {
            case .enqueued:
                sink.inFlight = min(sink.inFlight + 1, sink.capacity)
            case .dropped:
                sink.drops += 1
            case .terminated:
                sink.continuation.finish()
            @unknown default:
                break
            }
            sinks[id] = sink
        }
        // The per-bus writer owns disk ordering and backpressure. Enqueue is a
        // short lock operation; no disk await occurs on this actor or on the
        // process-wide ingress worker.
        persistPump.submit(event)
    }

    /// Test seam: drain — called by a subscriber after consuming N events to
    /// release the inFlight watermark. Production consumers don't need this;
    /// the watermark is advisory (the ring policy is the real bound).
    func releaseInFlight(_ id: UUID, _ n: Int = 1) {
        guard var sink = sinks[id] else { return }
        sink.inFlight = max(0, sink.inFlight - n)
        sinks[id] = sink
    }
}

// MARK: - TurnTracePersistLane (per-day capped JSONL)

/// Appends every emitted event to `<dataRoot>/data/turn_traces/<yyyy-MM-dd>.jsonl`
/// via the shared `appendJSONLCapped` helper (newest-20k cap, flock
/// discipline) — a 1:1 mirror of the emitMemoryCommitTrace pattern. Per-DAY
/// files keep any one file bounded and make the W3 replay lane a simple
/// date-keyed read.
///
/// Non-fatal: an IO failure logs to stderr and never propagates — a lost trace
/// row is acceptable; a turn that fails because telemetry couldn't write is not.
public struct TurnTracePersistLane: Sendable {
    // gpt-5.5 W1 review should-fix: per-DAY files with a 5000 cap could evict
    // a morning turn's events by evening (one turn emits dozens of rows),
    // making W3 replay lossy. 20k rows ≈ hundreds of turns per day — bounded
    // file size, replay-survivable. Revisit per-turn files in W3 if replay
    // needs hard guarantees.
    static let maxLines = 20_000
    static let maxBytes = JSONLLineCaps.turnTraceMaximumBytes
    static let trimToBytes = JSONLLineCaps.turnTraceTrimTargetBytes

    // MARK: - W3 test-override seam (W2 residual fix)
    //
    // The shared-bus W2 tests (TurnInspectorW2EmissionTests,
    // AnthropicStreamMessagesSSETests thinking tests) subscribe to
    // `TurnTraceBus.shared`, whose persist lane resolves `defaultDataRoot()`
    // and writes into the LIVE `data/turn_traces/<date>.jsonl` feed — so test
    // fixture events polluted the replay UI. This seam lets a test point the
    // SHARED lane (which it does not construct) at a tmp root WITHOUT touching
    // production. Resolution order at append time mirrors `defaultDataRoot`:
    //
    //   1. `NATIVE_AGENT_TURN_TRACE_ROOT` env var (literal, no tilde expand) —
    //      a hermetic-test escape hatch settable for the whole process.
    //   2. Per-instance `dataRootOverride` injection (direct-constructed lanes)
    //      — outranks the static so a global seam can't clobber an instance-
    //      injected hermetic lane (see `resolveRoot`).
    //   3. The process-wide `rootOverride` static (settable before first use) —
    //      redirects lanes with NO instance override, chiefly `.shared`.
    //   4. `defaultDataRoot()` (production).
    //
    // The static is resolved at APPEND time (not construction) so a test that
    // sets it before driving the already-constructed `.shared` lane is honored.
    private final class _RootOverrideBox: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        var value: URL? {
            get { lock.lock(); defer { lock.unlock() }; return url }
            set { lock.lock(); defer { lock.unlock() }; url = newValue }
        }
        /// Atomic set-if-nil. Returns the EFFECTIVE value after the call —
        /// the candidate when this call installed it, or the pre-existing
        /// value when another caller won the race.
        func setIfNil(_ candidate: URL) -> URL {
            lock.lock(); defer { lock.unlock() }
            if let existing = url { return existing }
            url = candidate
            return candidate
        }
    }
    private static let rootOverrideBox = _RootOverrideBox()

    /// Process-wide turn-trace root override. Honored at append time by every
    /// lane with no instance override, chiefly `.shared`'s. Production never
    /// sets this. Lower priority than `NATIVE_AGENT_TURN_TRACE_ROOT` so an
    /// env-pinned harness still wins.
    ///
    /// TEST DISCIPLINE (gpt-5.5 W3 review): in a test process this must be
    /// installed ONCE and NEVER reset — persistence off the bus is
    /// fire-and-forget, so a `defer { rootOverride = nil }` can restore nil
    /// while an emission is still resolving its path and leak the event into
    /// the LIVE feed. Suites use `installTestRootOverrideIfUnset(_:)`; the
    /// raw setter exists for the seam itself and must not be used to clear
    /// the override mid-process while shared-bus emissions may be in flight.
    public static var rootOverride: URL? {
        get { rootOverrideBox.value }
        set { rootOverrideBox.value = newValue }
    }

    /// Atomically install a process-wide test root IF none is set, returning
    /// the effective root (the pre-existing one when another suite won the
    /// race — any non-live tmp root satisfies the seam, so suites do not need
    /// their own). Never resets; the override lives for the process lifetime.
    @discardableResult
    public static func installTestRootOverrideIfUnset(_ candidate: URL) -> URL {
        rootOverrideBox.setIfNil(candidate)
    }

    /// The data root this lane resolves to RIGHT NOW (env → instance → static →
    /// default). Public so the W3 replay reader can read the SAME location the
    /// live lane writes to — including any env/static override — instead of
    /// re-deriving `defaultDataRoot()` and diverging from the live feed.
    public func resolvedDataRoot() -> URL {
        let automaticTestRoot = Self.automaticTestRoot()
        let instanceOverride = Self.testSafeInstanceOverride(
            dataRootOverride,
            automaticTestRoot: automaticTestRoot
        )
        return Self.resolveRoot(
            env: Self.envRootOverride(),
            staticOverride: Self.rootOverride,
            instanceOverride: instanceOverride,
            defaultRoot: automaticTestRoot ?? defaultDataRoot()
        )
    }

    /// A factory that explicitly threads `defaultDataRoot()` is still a
    /// production-root request in an XCTest process. Treating that value as a
    /// higher-priority custom override defeated the automatic safety fallback
    /// and let integration tests append to Agent's live calibration feed.
    static func testSafeInstanceOverride(
        _ instance: URL?,
        automaticTestRoot: URL?
    ) -> URL? {
        guard automaticTestRoot != nil,
              instance?.standardizedFileURL == defaultDataRoot().standardizedFileURL else {
            return instance
        }
        return nil
    }

    /// XCTest processes must never fall through to the developer's live data
    /// root merely because a shared-bus test forgot to install the legacy
    /// process override early enough. Explicit env/instance/static roots still
    /// outrank this fallback. The PID keeps parallel test processes isolated.
    static func automaticTestRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processName: String = ProcessInfo.processInfo.processName,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        let normalizedProcess = processName.lowercased()
        guard environment["XCTestConfigurationFilePath"] != nil
                || normalizedProcess.contains("xctest")
                || normalizedProcess.contains("swiftpm-testing-helper")
                || normalizedProcess.contains("packagetests") else {
            return nil
        }
        return temporaryDirectory
            .appendingPathComponent(
                "NativeAgent-TurnTraceTests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
    }

    /// Resolve the env-var override once (literal path, tilde preserved — same
    /// `URLComponents(scheme:"file")` trick as `defaultDataRoot`).
    private static func envRootOverride(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = environment["NATIVE_AGENT_TURN_TRACE_ROOT"], !raw.isEmpty else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "file"
        components.path = raw
        return components.url ?? URL(fileURLWithPath: raw)
    }

    /// Test injection. Production leaves nil → resolves through
    /// `defaultDataRoot()` at append time (env-var / stamped-repo / cwd
    /// resolution happens in the live process, not at construction).
    let dataRootOverride: URL?
    private let persistence = SwiftNativePersistenceCore()

    public init(dataRootOverride: URL? = nil) {
        self.dataRootOverride = dataRootOverride
    }

    /// Pure resolution of the data root from the four candidate sources, in
    /// priority order: env override → per-instance injection → process static →
    /// `defaultDataRoot()`.
    ///
    /// Per-instance injection OUTRANKS the process static deliberately: a
    /// directly-constructed hermetic lane (the W1 persist tests) that passes an
    /// explicit `dataRootOverride` must keep writing to ITS root even if some
    /// other test has the process-wide static set. The static only matters for
    /// lanes with NO instance override — chiefly `TurnTraceBus.shared`'s lane,
    /// which is exactly the one the W2 shared-bus tests need to redirect away
    /// from the live feed. So the static still does its job (redirect `.shared`)
    /// without clobbering instance-injected test lanes.
    ///
    /// Extracted as a pure function so the priority order is unit-testable
    /// WITHOUT mutating the process-wide static (which would race parallel
    /// tests). `defaultRoot` is an autoclosure so it is only evaluated when all
    /// three overrides are nil (the production path) — never eagerly.
    static func resolveRoot(
        env: URL?,
        staticOverride: URL?,
        instanceOverride: URL?,
        defaultRoot: @autoclosure () -> URL = defaultDataRoot()
    ) -> URL {
        env ?? instanceOverride ?? staticOverride ?? defaultRoot()
    }

    /// `<dataRoot>/turn_traces/<yyyy-MM-dd>.jsonl`. NOTE: `defaultDataRoot()`
    /// already returns the `.../data` directory (it resolves to the data root,
    /// not the repo root — see PersistenceCore.defaultDataRoot), so the file
    /// lands at `data/turn_traces/<date>.jsonl` as the brief specifies.
    public func path(for date: Date) -> URL {
        // Resolution order: env override → per-instance injection → process
        // static → defaultDataRoot (see resolveRoot for why instance outranks
        // the static). The static redirects the SHARED lane (no instance
        // override) away from the live feed for the W2 shared-bus tests.
        let automaticTestRoot = Self.automaticTestRoot()
        let instanceOverride = Self.testSafeInstanceOverride(
            dataRootOverride,
            automaticTestRoot: automaticTestRoot
        )
        let root = Self.resolveRoot(
            env: Self.envRootOverride(),
            staticOverride: Self.rootOverride,
            instanceOverride: instanceOverride,
            defaultRoot: automaticTestRoot ?? defaultDataRoot()
        )
        return root
            .appendingPathComponent("turn_traces", isDirectory: true)
            .appendingPathComponent("\(Self.dayFormatter.string(from: date)).jsonl")
    }

    /// Append one event row (capped + flock'd). Best-effort.
    public func append(_ event: TurnTraceEvent) async {
        let target = path(for: event.ts)
        // Ensure the directory exists — appendJSONLCapped writes the file but
        // not its parent dir.
        let dir = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try await appendJSONLCapped(
                event.jsonRow,
                to: target,
                using: persistence,
                maxLines: Self.maxLines,
                logLabel: "TurnTracePersistLane",
                // H3: this append runs on the chat turn path under the feed's
                // flock. Without a byte trigger the cap re-read the whole
                // day-file (up to ~18MB at the 20k-line cap) for every traced
                // row. Below the trigger the line count is never taken.
                trimWhenBytesExceed: JSONLLineCaps.turnTraceTrimTriggerBytes,
                maxBytes: Self.maxBytes,
                trimToBytes: Self.trimToBytes
            )
        } catch {
            FileHandle.standardError.write(
                Data("TurnTracePersistLane: append failed (turn \(event.turnId)): \(error)\n".utf8)
            )
        }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Bounded recent turn-trace reader

/// Reads the same per-day ledger resolved by `TurnTracePersistLane`. Keeping
/// path resolution here prevents diagnostics from drifting back to the legacy
/// aggregate trace ledger or bypassing writer root overrides.
public struct TurnTraceRecentReader: Sendable {
    public static let maxRows = 2_000
    public static let maxBytes = 8 * 1_024 * 1_024

    public struct Snapshot: Sendable {
        public let sourceURL: URL
        public let events: [TurnTraceEvent]

        public init(sourceURL: URL, events: [TurnTraceEvent]) {
            self.sourceURL = sourceURL
            self.events = events
        }
    }

    private let lane: TurnTracePersistLane
    private let persistence = SwiftNativePersistenceCore()

    public init(dataRootOverride: URL? = nil) {
        self.lane = TurnTracePersistLane(dataRootOverride: dataRootOverride)
    }

    /// Reads only the bounded tail of the current local-day trace file.
    /// A missing file is an honest empty snapshot; IO errors are surfaced.
    public func read(now: Date = Date()) async throws -> Snapshot {
        let sourceURL = lane.path(for: now)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw PersistenceCoreError.ioFailure(
                "turn trace path is a directory: \(sourceURL.path)"
            )
        }
        let rows = try await persistence.tailJSONL(
            sourceURL,
            limit: Self.maxRows,
            maxBytes: Self.maxBytes
        )
        return Snapshot(
            sourceURL: sourceURL,
            events: rows.compactMap(TurnTraceEvent.init(jsonRow:))
        )
    }
}
