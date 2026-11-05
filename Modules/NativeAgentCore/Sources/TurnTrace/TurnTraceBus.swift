import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import os
// Blueprint: | `TurnTraceBus.swift` | Bounded live/disk queues; durable terminals and scoped flush |

/// Nonblocking live multicast with bounded subscriber buffers; overflow drops the oldest buffered event.
public actor TurnTraceBus {
    public static let shared = TurnTraceBus()

    /// Default per-subscriber ring capacity. Bounded so a stalled consumer can't grow memory without limit.
    public static let defaultBufferCapacity = 512

    public struct Subscription: Sendable {
        public let id: UUID
        public let stream: AsyncStream<TurnTraceEvent>
        init(id: UUID, stream: AsyncStream<TurnTraceEvent>) {
            self.id = id
            self.stream = stream
        }
    }

    private var sinks: [UUID: AsyncStream<TurnTraceEvent>.Continuation] = [:]

    /// Per-bus persistence isolates disk waits from process-wide live delivery.
    private nonisolated let persistLane: TurnTracePersistLane
    private nonisolated let persistQueue = _FIFO<TrackedEvent>(capacity: 4096)
    private nonisolated let flushes = TurnFlushes()

    public init(persistLane: TurnTracePersistLane = TurnTracePersistLane()) {
        self.persistLane = persistLane
    }

    // MARK: Subscribe / unsubscribe

    /// Termination unregisters bounded subscriptions so abandoned consumers cannot retain buffers.
    public func subscribe(
        capacity: Int = TurnTraceBus.defaultBufferCapacity
    ) -> Subscription {
        let id = UUID()
        let cap = max(1, capacity)
        let (stream, continuation) = AsyncStream<TurnTraceEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(cap)
        )
        sinks[id] = continuation
        continuation.onTermination = { [weak self] _ in
            // Detach cleanup because stream termination callbacks cannot await.
            Task { [weak self] in await self?.removeSink(id) }
        }
        return Subscription(id: id, stream: stream)
    }

    public func unsubscribe(_ id: UUID) {
        removeSink(id)
    }

    private func removeSink(_ id: UUID) {
        sinks.removeValue(forKey: id)?.finish()
    }

    // MARK: Emit

    /// Bounded ingress retains one drain task; overload drops events without allocating a task per event.
    private nonisolated static let emissionPump = _FIFO<PendingEmission>(capacity: 4096)

    private struct PendingEmission: Sendable {
        let tracked: TrackedEvent
        let bus: TurnTraceBus
    }

    private struct TrackedEvent: Sendable {
        let event: TurnTraceEvent
        let ticket: UUID
    }

    /// A marker covers this turn's prior failures and outstanding accepted events. Later traffic cannot extend it; neither cancellation nor a deadline waits
    /// for a blocked persistence worker to return.
    private final class TurnFlushes: @unchecked Sendable {
        final class Marker: @unchecked Sendable {
            let id = UUID()
            private let lock = NSLock()
            private var result: Result<Void, Error>?
            private var continuation: CheckedContinuation<Void, Error>?

            func resolve(_ outcome: Result<Void, Error>) {
                let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                    guard result == nil else { return nil }
                    result = outcome
                    let waiter = continuation; continuation = nil
                    return waiter
                }
                waiter?.resume(with: outcome)
            }

            func wait() async throws {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                        let ready = lock.withLock { () -> Result<Void, Error>? in
                            if let result { return result }
                            continuation = waiter
                            return nil
                        }
                        if let ready { waiter.resume(with: ready) }
                    }
                } onCancel: { self.resolve(.failure(CancellationError())) }
            }
        }
        private struct Waiting {
            let marker: Marker
            var tickets: Set<UUID>
        }
        private let lock = NSLock()
        private var pending: [String: Set<UUID>] = [:]
        // One retained cause per damaged turn is enough to forbid a clean flush. Never evict or clear it on capture: a later successful append cannot restore
        // an earlier lost row. Successful turns retain no result state.
        private var failures: [String: Error] = [:]
        private var waiting: [UUID: Waiting] = [:]

        func begin(_ turn: String) -> UUID {
            lock.withLock {
                let ticket = UUID()
                pending[turn, default: []].insert(ticket)
                return ticket
            }
        }

        func end(_ tracked: TrackedEvent, error: Error? = nil) {
            let completed = lock.withLock { () -> [(Marker, Result<Void, Error>)] in
                let turn = tracked.event.turnId, ticket = tracked.ticket
                if let error, failures[turn] == nil { failures[turn] = error }
                pending[turn]?.remove(ticket)
                if pending[turn]?.isEmpty == true { pending[turn] = nil }
                var completed: [(Marker, Result<Void, Error>)] = []
                for id in Array(waiting.keys) {
                    guard var entry = waiting[id], entry.tickets.remove(ticket) != nil else { continue }
                    if let error {
                        waiting[id] = nil
                        completed.append((entry.marker, .failure(error)))
                    } else if entry.tickets.isEmpty {
                        waiting[id] = nil
                        completed.append((entry.marker, .success(())))
                    } else { waiting[id] = entry }
                }
                return completed
            }
            for (marker, result) in completed { marker.resolve(result) }
        }

        func capture(_ turn: String) -> Marker {
            let marker = Marker()
            let ready = lock.withLock { () -> Result<Void, Error>? in
                if let error = failures[turn] { return .failure(error) }
                let tickets = pending[turn] ?? []
                guard !tickets.isEmpty else { return .success(()) }
                waiting[marker.id] = Waiting(marker: marker, tickets: tickets)
                return nil
            }
            if let ready { marker.resolve(ready) }
            return marker
        }

        func remove(_ marker: Marker) { lock.withLock { waiting[marker.id] = nil } }
    }

    private final class _FIFO<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Element] = []
        private var head = 0
        private var worker: Task<Void, Never>?
        private var idleWaiters: [CheckedContinuation<Void, Never>] = []
        private let capacity: Int
        init(capacity: Int) { self.capacity = capacity }
        /// Share queue admission and worker publication under one lock; retire the worker only after final delivery settles.
        @discardableResult
        func enqueue(_ pending: Element, deliver: @escaping @Sendable (Element) async -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard queue.count - head < capacity else { return false }
            queue.append(pending)
            guard worker == nil else { return true }
            worker = Task.detached(priority: .utility) { [self] in
                while let next = self.next() { await deliver(next) }
            }
            return true
        }
        /// Batch delivery: the worker takes everything queued (up to `limit`) at once, so one write carries a whole flush.
        @discardableResult
        func enqueue(_ pending: Element, limit: Int, deliverBatch: @escaping @Sendable ([Element]) async -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard queue.count - head < capacity else { return false }
            queue.append(pending)
            guard worker == nil else { return true }
            worker = Task.detached(priority: .utility) { [self] in
                while let batch = self.nextBatch(limit) { await deliverBatch(batch) }
            }
            return true
        }
        func nextBatch(_ limit: Int) -> [Element]? {
            guard let first = next() else { return nil }
            var batch = [first]
            while batch.count < limit, let more = takeIfQueued() { batch.append(more) }
            return batch
        }
        /// The next queued element without retiring the worker when none is queued.
        private func takeIfQueued() -> Element? {
            lock.lock(); defer { lock.unlock() }
            guard head < queue.count else { return nil }
            let value = queue[head]
            head += 1
            return value
        }
        func next() -> Element? {
            lock.lock()
            guard head < queue.count else {
                queue.removeAll(keepingCapacity: true)
                head = 0
                worker = nil
                let waiters = idleWaiters
                idleWaiters.removeAll()
                lock.unlock()
                for waiter in waiters { waiter.resume() }
                return nil
            }
            let value = queue[head]
            head += 1
            if head >= 256, head * 2 >= queue.count {
                queue.removeFirst(head)
                head = 0
            }
            lock.unlock()
            return value
        }
        /// Idle requires both an empty queue and completed final delivery because the worker dequeues before awaiting. Use only for short-lived process exit;
        /// hot emission never waits here.
        func waitUntilIdle() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                guard worker != nil || head < queue.count else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Drain accepted ingress, then this bus's persistence queue, before process exit. Dropped events stay lost; never await this on a turn's hot path.
    public nonisolated func drainForProcessExit() async {
        await Self.emissionPump.waitUntilIdle()
        await persistQueue.waitUntilIdle()
    }

    /// Flush this turn's already-accepted queue entries, with a five-second deadline. Any prior accepted-write failure on this bus still throws. This is
    /// ordering evidence only: the caller must still verify the checkpoint and persisted terminal. Queue loss is never completion.
    public nonisolated func flush(turnId: String) async throws {
        try Task.checkCancellation()
        let marker = flushes.capture(turnId)
        defer { flushes.remove(marker) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await marker.wait() }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw ToolFailureError("Turn \(turnId)'s trace flush did not finish within five seconds; recovery remains unconfirmed.", effects: .unknown)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        try Task.checkCancellation()
    }

    /// Nonblocking emission through bounded ingress and per-bus persistence queues. Events over either queue's capacity are dropped.
    public nonisolated static func fire(_ event: TurnTraceEvent, on bus: TurnTraceBus = .shared) {
        let event = sequencingDispatch(event)
        let tracked = TrackedEvent(event: event, ticket: bus.flushes.begin(event.turnId))
        if !emissionPump.enqueue(.init(tracked: tracked, bus: bus), deliver: { pending in
            await pending.bus.deliver(pending.tracked)
        }) {
            bus.flushes.end(tracked, error: ToolFailureError("Trace ingress was full; the turn's evidence is incomplete.", effects: .unknown))
        }
    }

    /// Capture explicit request metadata before asynchronous emission; trace-only correlation may supply the act id.
    public nonisolated static func fireFromContext(
        kind: String,
        sessionId: String? = nil,
        surface: String? = nil,
        payload: JSONValue = .object([:]),
        turn: Turn?,
        on bus: TurnTraceBus? = nil
    ) {
        guard let turnId = turn?.id ?? TurnTraceContext.turnId else { return }
        let event = TurnTraceEvent(
            turnId: turnId,
            kind: kind,
            sessionId: sessionId ?? turn?.session,
            surface: surface,
            destinationId: TurnTraceContext.destinationId,
            threadId: TurnTraceContext.threadId,
            payload: payload,
            turn: turn
        )
        fire(event, on: bus ?? TurnTraceContext.bus ?? .shared)
    }

    /// Keep subscriber delivery independent of disk latency.
    public func deliver(_ event: TurnTraceEvent) {
        deliver(TrackedEvent(event: event, ticket: flushes.begin(event.turnId)))
    }

    private func deliver(_ tracked: TrackedEvent) {
        let event = tracked.event
        if event.turnId != "unknown" || event.diagnostic.isEmpty { deliverToSubscribers(event) }
        if !persistQueue.enqueue(tracked, limit: 256, deliverBatch: { [persistLane, flushes] batch in
            do {
                try await persistLane.appendBatch(batch.map(\.event))
                for next in batch { flushes.end(next) }
            } catch {
                ModuleLog(category: "TurnTracePersistLane")("append of \(batch.count) events failed: \(error)", level: .error)
                for next in batch { flushes.end(next, error: error) }
            }
        }) {
            flushes.end(tracked, error: ToolFailureError("Trace persistence queue was full; the turn's evidence is incomplete.", effects: .unknown))
        }
    }

    /// A terminal must reach disk before its restart checkpoint can be removed.
    public func deliverDurably(_ event: TurnTraceEvent) async throws {
        let wrote = try await persistLane.appendGuarded(event, unless: { current in
            guard event.kind == "turn.terminal", case .object(let payload) = event.payload,
                  case .string(let status)? = payload["status"] else { return false }
            // This terminal is known by its live owner: only an exact duplicate among its turn's own events stops it.
            return TurnTraceReplayReader.containsTerminal(forTurn: event.turnId, in: current, status: status)
        })
        if wrote { deliverToSubscribers(event) }
    }

    private struct DispatchCoverage: Sendable {
        let life = UUID().uuidString
        var next: Int64 = 0
    }
    private static let dispatchCoverage = OSAllocatedUnfairLock<[String: DispatchCoverage]>(initialState: [:])

    /// Stamp before either lossy queue. Turn closure carries the final count, so even losing both ends of a dispatch leaves a detectable gap.
    private nonisolated static func sequencingDispatch(_ event: TurnTraceEvent) -> TurnTraceEvent {
        guard event.kind == "tool.dispatch" || event.kind == "tool.dispatch.closed", case .object(var payload) = event.payload else { return event }
        let mark = dispatchCoverage.withLock { rows -> JSONValue in
            var row = rows[event.turnId] ?? DispatchCoverage()
            let mark: JSONValue = .object(["life": .string(row.life), "ordinal": .int(row.next)])
            if event.kind == "tool.dispatch" {
                let (next, overflow) = row.next.addingReportingOverflow(1)
                if overflow { row = DispatchCoverage() } else { row.next = next }
            }
            // Memory bound only; eviction changes life, never fabricates continuity.
            if rows.count >= 256, rows[event.turnId] == nil, let key = rows.keys.sorted().first { rows[key] = nil }
            rows[event.turnId] = row
            return mark
        }
        payload["dispatchCoverage"] = mark
        var sequenced = TurnTraceEvent(turnId: event.turnId, ts: event.ts, kind: event.kind,
            sessionId: event.sessionId, surface: event.surface, destinationId: event.destinationId,
            threadId: event.threadId, payload: .object(payload), turn: nil)
        sequenced.diagnostic = event.diagnostic
        return sequenced
    }

    /// Live delivery without persistence. Reconciliation uses this after its guarded append so the event is not written twice.
    func deliverToSubscribers(_ event: TurnTraceEvent) {
        for continuation in sinks.values {
            // `.bufferingNewest(cap)` means yield NEVER blocks; on overflow it drops the OLDEST buffered value and reports `.dropped`.
            if case .terminated = continuation.yield(event) { continuation.finish() }
        }
    }
}
