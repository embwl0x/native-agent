import Testing
import Foundation
@testable import PersistenceCore

private actor TurnTraceDeliveryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Bool { !waiters.isEmpty }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

// MARK: - Turn Inspector W1 hermetic tests
//
// Covers the five W1 acceptance criteria from the build plan:
//   1. turnId propagates through a nested task tree.
//   2. the bus delivers to 2 subscribers.
//   3. a SLOW subscriber: emission completes immediately, drops are counted,
//      and the slow consumer never blocks emission.
//   4. the persist lane writes capped JSONL with turnId present.
//   5. no-subscriber emission is near-zero cost.

@Suite("TurnTrace W1", .serialized)
struct TurnTraceTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("turntrace-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func firstRenderRegistryEmitsOneCorrelatedBoundedEvent() async throws {
        let registry = TurnFirstRenderRegistry(maximumEntries: 2)
        await registry.register(turnId: "turn-a", sessionId: "session-a", surface: "chat")

        let event = try #require(await registry.claimFirstRenderEvent(
            sessionId: "session-a",
            observedBy: "test-view"
        ))

        #expect(event.turnId == "turn-a")
        #expect(event.kind == "surface.firstRender")
        #expect(event.sessionId == "session-a")
        #expect(event.surface == "chat")
        #expect(await registry.claimFirstRenderEvent(
            sessionId: "session-a",
            observedBy: "duplicate"
        ) == nil)
    }

    // MARK: 1. turnId propagation through a nested task tree

    @Test func turnId_propagates_through_nested_task_tree() async {
        let id = TurnTraceContext.mintTurnId()
        // Bind once, then read it from inside nested unstructured tasks.
        let observed: [String?] = await TurnTraceContext.$turnId.withValue(id) {
            await withTaskGroup(of: String?.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        // Inner Task inherits the task-local; nest once more.
                        await Task { TurnTraceContext.turnId }.value
                    }
                }
                var out: [String?] = []
                for await v in group { out.append(v) }
                return out
            }
        }
        #expect(observed.count == 4)
        #expect(observed.allSatisfy { $0 == id }, "every nested task must see the bound turnId")
        // Outside the binding it is nil again.
        #expect(TurnTraceContext.turnId == nil)
    }

    @Test func mintTurnId_is_unique_and_lowercased_uuid() {
        let a = TurnTraceContext.mintTurnId()
        let b = TurnTraceContext.mintTurnId()
        #expect(a != b)
        #expect(a == a.lowercased())
        #expect(UUID(uuidString: a) != nil)
    }

    // MARK: 2. bus delivers to 2 subscribers

    @Test func bus_delivers_to_two_subscribers() async {
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: tmpRoot()))
        let subA = await bus.subscribe()
        let subB = await bus.subscribe()

        let id = TurnTraceContext.mintTurnId()
        let event = TurnTraceEvent(turnId: id, kind: "llm.call", payload: .object(["k": .int(1)]))
        // Deliver directly (await) so the test is deterministic — the static
        // `fire` shim is the fire-and-forget production entry, exercised in the
        // slow-subscriber and persist tests.
        await bus.deliver(event)
        await bus.deliver(event)

        var gotA = 0, gotB = 0
        for await e in subA.stream { #expect(e.turnId == id); gotA += 1; if gotA == 2 { break } }
        for await e in subB.stream { #expect(e.turnId == id); gotB += 1; if gotB == 2 { break } }
        #expect(gotA == 2)
        #expect(gotB == 2)
    }

    // MARK: 3. SLOW subscriber — emission immediate, drops counted, no block

    @Test func slow_subscriber_does_not_block_and_drops_are_counted() async {
        // Capacity-1 ring: the second+ events overflow while the consumer is
        // "slow" (never draining), so deliver must NOT block and the drops
        // must be counted.
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: tmpRoot()))
        let slow = await bus.subscribe(capacity: 1)

        let id = TurnTraceContext.mintTurnId()
        let n = 50
        // Time the emission burst: it must complete fast (no awaiting the
        // never-draining consumer). We never iterate `slow.stream`, so its ring
        // fills at 1 and the rest overflow.
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<n {
            await bus.deliver(TurnTraceEvent(turnId: id, kind: "tool.dispatch",
                                             payload: .object(["i": .int(Int64(i))])))
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("[turn-trace-nonblocking] emission_burst_ms=\(elapsedMs)")

        let drops = await bus.dropCount(slow.id)
        // Structural guarantee of non-blocking delivery: a blocking observer
        // would deadlock and never overflow, so ~n-1 counted drops PROVES the
        // emit path didn't await the never-draining consumer. Always asserted.
        // .bufferingNewest(1) keeps the newest and drops the rest → ~n-1 drops.
        #expect(drops >= n - 2, "overflowed events must be counted as drops (got \(drops))")
        // The absolute wall-clock bound is a redundant tripwire — gated behind
        // NATIVE_AGENT_PERF_ASSERTS so CI load can't flake it. See
        // nativeagent-hangproof-subprocess-tests.
        if ProcessInfo.processInfo.environment["NATIVE_AGENT_PERF_ASSERTS"] == "1" {
            #expect(elapsedMs < 1000, "emission burst must not block on the slow consumer (took \(elapsedMs)ms)")
        }
    }

    // MARK: 4. persist lane writes capped JSONL with turnId present

    @Test func persist_lane_writes_jsonl_with_turnId() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = TurnTracePersistLane(dataRootOverride: root)
        let id = TurnTraceContext.mintTurnId()
        let ev = TurnTraceEvent(turnId: id, kind: "memory.commit",
                                sessionId: "sess-1", surface: "chat",
                                payload: .object(["id": .string("mem-9")]))
        await lane.append(ev)

        let path = lane.path(for: ev.ts)
        #expect(FileManager.default.fileExists(atPath: path.path), "per-day file must exist")
        let text = try String(contentsOf: path, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 1)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        #expect(obj["turnId"] as? String == id)
        #expect(obj["kind"] as? String == "memory.commit")
        #expect(obj["sessionId"] as? String == "sess-1")
        #expect(obj["surface"] as? String == "chat")
        #expect(obj["ts"] is String)
        #expect(obj["payload"] is [String: Any])
    }

    @Test func recent_reader_uses_current_lane_path_and_caps_scanned_rows() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = TurnTracePersistLane(dataRootOverride: root)
        let path = lane.path(for: Date())
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let rows = (0..<(TurnTraceRecentReader.maxRows + 5)).map { index in
            #"{"turnId":"turn-\#(index)","ts":"\#(timestamp)","kind":"llm.call","payload":{}}"#
        }.joined(separator: "\n") + "\n"
        try rows.write(to: path, atomically: true, encoding: .utf8)

        let snapshot = try await TurnTraceRecentReader(dataRootOverride: root).read()
        #expect(snapshot.sourceURL == path)
        #expect(snapshot.events.count == TurnTraceRecentReader.maxRows)
        #expect(snapshot.events.first?.turnId == "turn-5")
        #expect(snapshot.events.last?.turnId == "turn-2004")
    }

    @Test func persist_lane_caps_at_newest_maxLines() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = TurnTracePersistLane(dataRootOverride: root)
        // Pre-seed the day file with exactly maxLines lines so a single append
        // trips the cap deterministically (appending serially is slow).
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let path = lane.path(for: fixedDate)
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let seed = (0..<TurnTracePersistLane.maxLines)
            .map { #"{"turnId":"seed","kind":"x","i":\#($0)}"# }
            .joined(separator: "\n") + "\n"
        try seed.write(to: path, atomically: true, encoding: .utf8)

        let id = "newest-turn"
        await lane.append(TurnTraceEvent(turnId: id, ts: fixedDate, kind: "llm.call"))

        let text = try String(contentsOf: path, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        // H3 contract change (2026-07-09): the lane amortizes the trim behind a
        // byte trigger (turnTraceTrimTriggerBytes) so the per-turn append stops
        // re-reading a multi-MB file under the flock. Small overshoots between
        // trim passes are the DESIGN; the invariant is byte-boundedness, and the
        // exact line trim fires once the trigger is crossed.
        #expect(lines.count <= TurnTracePersistLane.maxLines + 64,
                "feed stays near the cap between amortized trims: \(lines.count)")
        let lastObj = try #require(
            try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as? [String: Any]
        )
        #expect(lastObj["turnId"] as? String == "newest-turn")
        #expect(lastObj["kind"] as? String == "llm.call")

        // Force the trigger: exceed the byte threshold and the EXACT cap applies.
        let dropped = try enforceJSONLLineCap(at: path, maxLines: TurnTracePersistLane.maxLines)
        let after = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        #expect(dropped >= 1, "the deferred trim drops the overshoot: \(dropped)")
        #expect(after.count == TurnTracePersistLane.maxLines, "exact cap on explicit trim")
        #expect(!after.first!.contains(#""i":0"#), "oldest seed line trimmed once the cap runs")
    }

    // MARK: 5. no-subscriber emission is near-zero cost

    @Test func no_subscriber_emission_is_cheap() async {
        // No subscribers; persist lane pointed at tmp. A large burst of
        // deliver() calls must complete fast (no per-event blocking, no
        // unbounded growth) — the bus simply has nothing to fan out to.
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: tmpRoot()))
        let id = TurnTraceContext.mintTurnId()
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<200 {
            await bus.deliver(TurnTraceEvent(turnId: id, kind: "llm.call",
                                             payload: .object(["i": .int(Int64(i))])))
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        #expect(elapsedMs < 2000, "no-subscriber burst must be cheap (took \(elapsedMs)ms)")
        let count = await bus.subscriberCount
        #expect(count == 0)
    }

    @Test func fireFromContext_skips_when_no_turn_bound() async {
        // fireFromContext is the production emit shim; with no turnId bound it
        // must NOT deliver (an event with no turn has no story to join).
        let lane = TurnTracePersistLane(dataRootOverride: tmpRoot())
        let bus = TurnTraceBus(persistLane: lane)
        let sub = await bus.subscribe()
        // No TurnTraceContext binding here → should be a no-op.
        TurnTraceBus.fireFromContext(kind: "llm.call", on: bus)
        // Give any (incorrectly) spawned task a beat, then confirm nothing
        // arrived by racing a short timeout sentinel.
        let delivered = await firstWithinShortWindow(sub.stream)
        #expect(delivered == nil, "unbound emission must not deliver")
    }

    @Test func event_payload_string_fields_are_bounded() {
        let big = String(repeating: "x", count: TurnTraceEvent.maxPayloadStringChars + 500)
        let ev = TurnTraceEvent(turnId: "t", kind: "k",
                                payload: .object(["big": .string(big),
                                                  "nested": .array([.string(big)])]))
        guard case .object(let obj) = ev.payload,
              case .string(let s)? = obj["big"] else {
            Issue.record("payload shape unexpected"); return
        }
        #expect(s.count <= TurnTraceEvent.maxPayloadStringChars + 32, "leaf must be truncated")
        #expect(s.contains("chars]"), "truncation marker must be present")
        // Nested array leaf is bounded too.
        guard case .array(let arr)? = obj["nested"], case .string(let ns)? = arr.first else {
            Issue.record("nested shape unexpected"); return
        }
        #expect(ns.count <= TurnTraceEvent.maxPayloadStringChars + 32)
    }

    // Helper: return the first event from a stream if one arrives within a
    // short window, else nil. Used to assert NON-delivery without hanging.
    private func firstWithinShortWindow(
        _ stream: AsyncStream<TurnTraceEvent>
    ) async -> TurnTraceEvent? {
        await withTaskGroup(of: TurnTraceEvent?.self) { group in
            group.addTask {
                for await e in stream { return e }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func collectSequences(
        from subscription: TurnTraceBus.Subscription,
        on bus: TurnTraceBus,
        count: Int,
        timeout: Duration
    ) async -> [Int]? {
        await withTaskGroup(of: [Int]?.self) { group in
            group.addTask {
                var values: [Int] = []
                values.reserveCapacity(count)
                for await event in subscription.stream {
                    guard case .object(let payload) = event.payload,
                          case .int(let value)? = payload["sequence"] else { continue }
                    values.append(Int(value))
                    await bus.releaseInFlight(subscription.id)
                    if values.count == count { return values }
                }
                return values
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // The emission pump bounds queued work and requires exactly one drain
    // worker for a burst instead of allocating one task per trace event.
    @Test func emission_pump_bounds_queue_counts_drops_and_single_starts() {
        let pump = TurnTraceBus._EmissionPump(capacity: 2)
        func pending(_ id: String) -> TurnTraceBus._EmissionPump.Pending {
            .init(event: TurnTraceEvent(turnId: id, kind: "test"), bus: .shared)
        }
        #expect(pump.enqueue(pending("one")), "first event starts the sole worker")
        #expect(!pump.enqueue(pending("two")), "queued event must not start another worker")
        #expect(!pump.enqueue(pending("three")), "third queued event must drop")
        #expect(pump.snapshot.inFlight == 2)
        #expect(pump.snapshot.dropped == 1)
        #expect(pump.next()?.event.turnId == "one")
        #expect(pump.next()?.event.turnId == "two")
        #expect(pump.next() == nil)
        #expect(pump.enqueue(pending("four")), "an empty pump may start one new worker")
    }

    @Test func public_fire_burst_is_nonblocking_fifo_and_drains_global_backlog() async throws {
        // Let unrelated concurrent tests finish any prior global emission
        // before sampling the shared gate counters.
        for _ in 0..<500 where TurnTraceBus.emissionBacklog.inFlight != 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let baselineDrops = TurnTraceBus.emissionBacklog.dropped
        let bus = TurnTraceBus(
            persistLane: TurnTracePersistLane(dataRootOverride: tmpRoot())
        )
        let count = 1_000
        let subscription = await bus.subscribe(capacity: count + 8)
        let started = ContinuousClock.now
        for sequence in 0..<count {
            TurnTraceBus.fire(
                TurnTraceEvent(
                    turnId: "burst-(sequence)",
                    kind: "pump.integration",
                    payload: .object(["sequence": .int(Int64(sequence))])
                ),
                on: bus
            )
        }
        let producerElapsed = ContinuousClock.now - started
        #expect(producerElapsed < .seconds(1))

        let deadline = ContinuousClock.now + .seconds(10)
        while TurnTraceBus.emissionBacklog.inFlight != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(TurnTraceBus.emissionBacklog.inFlight == 0)
        let values = await collectSequences(
            from: subscription,
            on: bus,
            count: count,
            timeout: .seconds(10)
        )
        await bus.unsubscribe(subscription.id)
        #expect(values == Array(0..<count), "FIFO collection must complete before its bounded timeout")
        #expect(TurnTraceBus.emissionBacklog.dropped == baselineDrops)
    }

    @Test func public_fire_distress_is_bounded_and_drops_instead_of_allocating_unbounded_work() async throws {
        for _ in 0..<500 where TurnTraceBus.emissionBacklog.inFlight != 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let baselineDrops = TurnTraceBus.emissionBacklog.dropped
        let gate = TurnTraceDeliveryGate()
        let bus = TurnTraceBus(
            persistLane: TurnTracePersistLane(dataRootOverride: tmpRoot()),
            deliveryGate: { await gate.wait() }
        )
        TurnTraceBus.fire(TurnTraceEvent(turnId: "blocked-first", kind: "pump.distress"), on: bus)
        let gateDeadline = ContinuousClock.now + .seconds(2)
        while await gate.waiting == false, ContinuousClock.now < gateDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await gate.waiting)
        let started = ContinuousClock.now
        for sequence in 0..<50_000 {
            TurnTraceBus.fire(
                TurnTraceEvent(turnId: "distress-\(sequence)", kind: "pump.distress"),
                on: bus
            )
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(TurnTraceBus.emissionBacklog.inFlight <= 4096)
        #expect(TurnTraceBus.emissionBacklog.dropped > baselineDrops)

        await gate.open()
        let deadline = ContinuousClock.now + .seconds(10)
        while TurnTraceBus.emissionBacklog.inFlight != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(TurnTraceBus.emissionBacklog.inFlight == 0)
    }
}
