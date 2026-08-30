import Foundation
@testable import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, row `diagnostics.turnTraceObserver`
// (NativeDiagnosticObserver.swift:23 subscribe / :45 unsubscribe; consumer
// NativeExperienceContextPage.swift:88).
//
// Silent failure named in the ledger: state-lifecycle leak + silent drop.
// Every `subscribe()` opens a TurnTraceBus sink whose release depends on the
// projection stream terminating; a consumer that goes away without an
// unsubscribe leaks a bus sink for the process lifetime, and the Experience >
// Context page shows a thinned feed with no drop counter.
//
// Pinned here: (1) events actually project with monotonic ordinals and carry
// turn identity; (2) `unsubscribe` is a real release — it finishes the
// projection stream AND drops the underlying bus sink, so the add path has a
// matching remove path.
@Suite("Native diagnostic observer", .serialized)
struct NativeDiagnosticObserverTests {
    /// Lets the observer relay project the priming event, then arrests the
    /// first burst event after it has left the bus stream. That leaves the
    /// capacity-one bus sink full for a deterministic overflow proof.
    private actor ProjectionGate {
        private var callCount = 0
        private var blocked = false
        private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitBeforeProjection() async {
            callCount += 1
            guard callCount == 2 else { return }
            blocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilBlocked() async {
            guard !blocked else { return }
            await withCheckedContinuation { blockedWaiters.append($0) }
        }

        func release() {
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    /// The persist lane acknowledges only after the JSONL append has completed,
    /// replacing a timing poll with an exact durable-write boundary.
    private actor PersistReceipt {
        private var count = 0
        private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func record() {
            count += 1
            let ready = waiters.filter { count >= $0.target }
            waiters.removeAll { count >= $0.target }
            ready.forEach { $0.continuation.resume() }
        }

        func waitForCount(_ target: Int) async {
            guard count < target else { return }
            await withCheckedContinuation { waiters.append((target, $0)) }
        }
    }

    /// Holds a live projection consumer after it has definitely received one
    /// row.  That gives the burst a known empty capacity-one buffer to fill;
    /// every later row must then be accounted for by either the bus sink or
    /// the observer projection's drop counter.
    private actor HeldProjectionConsumer {
        private var isReady = false
        private var isReleased = false
        private var readyWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markReady() {
            guard !isReady else { return }
            isReady = true
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func waitUntilReady() async {
            guard !isReady else { return }
            await withCheckedContinuation { readyWaiters.append($0) }
        }

        func waitForRelease() async {
            guard !isReleased else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func fire(turnId: String, kind: String, name: String) {
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnId,
            kind: kind,
            sessionId: "diag-session",
            surface: "chat",
            payload: .object([
                "name": .string(name),
                "phase": .string("end"),
                "status": .string("ok"),
            ])
        ))
    }

    // EVAL FENCE: feeds
    // Ledger row: feeds.turn_traces.busSubscriberDrops
    //
    // A small live observer buffer must name its own loss.  This is deliberately
    // separate from persistence: a dropped subscriber is allowed to disagree
    // with the durable trace, but it must never present that partial projection
    // as complete.
    @Test("observer surfaces its bounded-subscriber drops while durable trace survives")
    func tinyObserverBufferCountsDropsWithoutErasingDurableTrace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-observer-drops-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let persistReceipt = PersistReceipt()
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(
            dataRootOverride: root,
            onPersist: { _ in await persistReceipt.record() }
        ))
        let projectionGate = ProjectionGate()
        let observer = NativeDiagnosticObserver(
            bus: bus,
            beforeProjection: { await projectionGate.waitBeforeProjection() }
        )
        let subscription = await observer.subscribe(capacity: 1)
        let dropNotice = Task { () -> Int? in
            for await count in subscription.dropCounts where count >= 7 {
                return count
            }
            return nil
        }
        let turnID = TurnTraceContext.mintTurnId()

        // Receive exactly one priming row, then keep the consumer alive without
        // draining it.  This is an event-driven readiness handshake rather than
        // racing the observer's relay task against the burst below.
        let heldConsumer = HeldProjectionConsumer()
        let consumer = Task { () -> ExperienceDiagnosticEvent? in
            var iterator = subscription.stream.makeAsyncIterator()
            let primingRow = await iterator.next()
            await heldConsumer.markReady()
            await heldConsumer.waitForRelease()
            return primingRow
        }
        await bus.deliver(TurnTraceEvent(
            turnId: "diagnostic-observer-prime-\(UUID().uuidString)",
            kind: "stream.prime",
            sessionId: "diag-drop-session",
            surface: "chat"
        ))
        await heldConsumer.waitUntilReady()

        // Let the first burst row leave the bus stream and hold it immediately
        // before the projection yield. The bus sink now has exactly one empty
        // slot; after this is observed, eight more rows leave one buffered and
        // seven measured drops. No task scheduling or polling chooses that
        // boundary.
        await bus.deliver(TurnTraceEvent(
            turnId: turnID,
            kind: "stream.tick",
            sessionId: "diag-drop-session",
            surface: "chat",
            payload: .object(["index": .int(0)])
        ))
        await projectionGate.waitUntilBlocked()
        for index in 1..<9 {
            await bus.deliver(TurnTraceEvent(
                turnId: turnID,
                kind: "stream.tick",
                sessionId: "diag-drop-session",
                surface: "chat",
                payload: .object(["index": .int(Int64(index))])
            ))
        }
        #expect(await subscription.dropCount() == 7)
        #expect(await dropNotice.value == 7,
                "terminal burst loss must wake diagnostics without a polling timer")

        await persistReceipt.waitForCount(10) // prime + nine burst rows
        let reader = TurnTraceRecentReader(dataRootOverride: root)
        let durableRows = try await reader.read().events.filter { $0.turnId == turnID }
        #expect(durableRows.count == 9, "subscriber loss must not erase canonical persisted rows")
        let drops = await subscription.dropCount()
        #expect(drops > 0)
        #expect(liveDiagnosticDropWarning(drops) == "Live observer omitted \(drops) event(s) under backpressure; use the canonical Turn Inspector for the durable trace.")
        #expect(liveDiagnosticDropWarning(0) == nil)
        await projectionGate.release()
        await heldConsumer.release()
        _ = await consumer.value
        await observer.unsubscribe(subscription.id)
    }

    @Test("subscribed events project with turn identity and monotonic ordinals")
    func projectionCarriesIdentityAndOrdinals() async throws {
        let observer = NativeDiagnosticObserver()
        let subscription = await observer.subscribe()
        #expect(await subscription.dropCount() == 0)
        let turnId = "diag-turn-\(UUID().uuidString)"

        let collected = Task { () -> [ExperienceDiagnosticEvent] in
            var seen: [ExperienceDiagnosticEvent] = []
            for await event in subscription.stream {
                guard event.turnId == turnId else { continue }
                seen.append(event)
                if seen.count == 2 { break }
            }
            return seen
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            collected.cancel()
        }

        fire(turnId: turnId, kind: "tool.dispatch", name: "read_file")
        fire(turnId: turnId, kind: "llm.call", name: "claude")

        let events = await collected.value
        watchdog.cancel()
        await observer.unsubscribe(subscription.id)

        #expect(events.count == 2, "a subscribed diagnostic consumer must see the turn's events")
        #expect(events.allSatisfy { $0.turnId == turnId })
        #expect(events.first?.kind == .tool)
        #expect(events.last?.kind == .provider)
        // Ordinals are the only thing separating two events with the same
        // timestamp — a collision would silently collapse rows in the page.
        #expect(Set(events.map(\.id)).count == 2)
    }

    @Test("unsubscribe releases the bus sink and finishes the projection stream")
    func unsubscribeReleasesTheSink() async throws {
        let observer = NativeDiagnosticObserver()
        // The bus is process-global and shared with parallel suites, so the
        // honest assertion is the one TurnInspectorModelTests already uses:
        // the count RETURNS to its baseline — this observer leaves no sink
        // behind.
        let baseline = await TurnTraceBus.shared.subscriberCount
        let subscription = await observer.subscribe()

        let finished = Task { () -> Bool in
            for await _ in subscription.stream {}
            return true
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            finished.cancel()
        }

        await observer.unsubscribe(subscription.id)

        // The add path has a matching remove path: the projection stream ends
        // (so a `for await` consumer unwinds instead of parking forever)...
        #expect(await finished.value)
        watchdog.cancel()

        // ...and the bus sink is gone. A leak here is invisible in normal use:
        // chat keeps working while the process accumulates dead sinks.
        // Assert on a WITNESSED observation from the poll loop itself — a
        // fresh re-read after the loop races the process-global bus (a
        // parallel suite's subscribe can land between loop-exit and re-read
        // and be misread as this observer's leak). A real leak still fails:
        // the count never returns to baseline within the deadline.
        let deadline = Date().addingTimeInterval(10)
        var settled = await TurnTraceBus.shared.subscriberCount
        while settled > baseline, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            settled = await TurnTraceBus.shared.subscriberCount
        }
        #expect(
            settled <= baseline,
            "unsubscribe must drop the TurnTraceBus sink it opened (baseline \(baseline), settled \(settled))"
        )
    }
}
