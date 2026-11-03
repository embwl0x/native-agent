import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import os
// Blueprint: | `TurnTraceBus.swift` | In-process multicast and bounded ingress/disk queues with sole retained workers; durable terminal delivery before checkpoint retirement; turn-scoped flush markers retain prior accepted-write failure and capture outstanding tickets with cancellation and a five-second deadline, independent of later traffic |

/// Nonblocking live multicast with bounded subscriber buffers;
/// overflow drops the oldest buffered event.
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

    private var sinks: [UUID: AsyncStream<TurnTraceEvent>.Continuation] = [:]

    /// Per-bus persistence isolates disk waits from process-wide live delivery.
    private nonisolated let persistLane: TurnTracePersistLane
    private nonisolated let persistQueue = _FIFO<TrackedEvent>(capacity: 4096)
    private nonisolated let flushes = TurnFlushes()

    public init(persistLane: TurnTracePersistLane = TurnTracePersistLane()) {
        self.persistLane = persistLane
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
        sinks[id] = continuation
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
        sinks.removeValue(forKey: id)?.finish()
    }

    // MARK: Emit

    /// Bounded ingress retains one drain task; overload drops events without
    /// allocating a task per event.
    private nonisolated static let emissionPump = _FIFO<PendingEmission>(capacity: 4096)

    private struct PendingEmission: Sendable {
        let tracked: TrackedEvent
        let bus: TurnTraceBus
    }

    private struct TrackedEvent: Sendable {
        let event: TurnTraceEvent
        let ticket: UUID
    }

    /// A marker covers this turn's prior failures and outstanding accepted events.
    /// Later traffic cannot extend it; neither cancellation nor a deadline waits
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
        // One retained cause per damaged turn is enough to forbid a clean flush.
        // Never evict or clear it on capture: a later successful append cannot
        // restore an earlier lost row. Successful turns retain no result state.
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
        /// Queue admission and publication of the sole retained worker share
        /// the lock. Its handle retires only after the final delivery settles.
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
        /// Suspend until the pump is idle (queue empty AND the drain worker,
        /// which pops each item BEFORE awaiting its delivery, has finished its
        /// final delivery and observed the empty queue). Resumes immediately
        /// when already idle. Process-exit drain for short-lived CLI hosts;
        /// the hot emit path never touches this.
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

    /// Drain accepted ingress, then this bus's persistence queue, before process exit.
    /// Dropped events stay lost; never await this on a turn's hot path.
    public nonisolated func drainForProcessExit() async {
        await Self.emissionPump.waitUntilIdle()
        await persistQueue.waitUntilIdle()
    }

    /// Flush this turn's already-accepted queue entries, with a five-second
    /// deadline. Any prior accepted-write failure on this bus still throws.
    /// This is ordering evidence only: the caller must still verify the
    /// checkpoint and persisted terminal. Queue loss is never completion.
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

    /// Nonblocking emission through bounded ingress and per-bus persistence queues.
    /// Events over either queue's capacity are dropped.
    public nonisolated static func fire(_ event: TurnTraceEvent, on bus: TurnTraceBus = .shared) {
        let event = sequencingDispatch(event)
        let tracked = TrackedEvent(event: event, ticket: bus.flushes.begin(event.turnId))
        if !emissionPump.enqueue(.init(tracked: tracked, bus: bus), deliver: { pending in
            await pending.bus.deliver(pending.tracked)
        }) {
            bus.flushes.end(tracked, error: ToolFailureError("Trace ingress was full; the turn's evidence is incomplete.", effects: .unknown))
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

    /// Publish to subscribers without awaiting them, then enqueue persistence.
    public func deliver(_ event: TurnTraceEvent) {
        deliver(TrackedEvent(event: event, ticket: flushes.begin(event.turnId)))
    }

    private func deliver(_ tracked: TrackedEvent) {
        let event = tracked.event
        if event.turnId != "unknown" || event.diagnostic.isEmpty { deliverToSubscribers(event) }
        if !persistQueue.enqueue(tracked, deliver: { [persistLane, flushes] next in
            do {
                try await persistLane.appendChecked(next.event)
                flushes.end(next)
            } catch {
                ModuleLog(category: "TurnTracePersistLane")("append failed (\(next.event.kind), turn \(next.event.turnId)): \(error)", level: .error)
                flushes.end(next, error: error)
            }
        }) {
            flushes.end(tracked, error: ToolFailureError("Trace persistence queue was full; the turn's evidence is incomplete.", effects: .unknown))
        }
    }

    /// A terminal must reach disk before its restart checkpoint can be removed.
    public func deliverDurably(_ event: TurnTraceEvent) async throws {
        let wrote = try await persistLane.appendGuarded(event, shouldAppend: { current in
            guard event.kind == "turn.terminal", case .object(let payload) = event.payload,
                  case .string(let status)? = payload["status"] else { return true }
            // This terminal is known by its live owner. Damage elsewhere in
            // the feed cannot prevent its append or invalidate an exact duplicate.
            return !TurnTraceReplayReader.containsTerminal(forTurn: event.turnId, in: current.events, status: status)
        })
        if wrote { deliverToSubscribers(event) }
    }

    private struct DispatchCoverage: Sendable {
        let life = UUID().uuidString
        var next: Int64 = 0
    }
    private static let dispatchCoverage = OSAllocatedUnfairLock<[String: DispatchCoverage]>(initialState: [:])

    /// Stamp before either lossy queue. Turn closure carries the final count,
    /// so even losing both ends of a dispatch leaves a detectable gap.
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
            threadId: event.threadId, payload: .object(payload))
        sequenced.diagnostic = event.diagnostic
        return sequenced
    }

    /// Live delivery without persistence. Reconciliation uses this after its
    /// guarded append so the event is not written twice.
    func deliverToSubscribers(_ event: TurnTraceEvent) {
        for continuation in sinks.values {
            // `.bufferingNewest(cap)` means yield NEVER blocks; on overflow it
            // drops the OLDEST buffered value and reports `.dropped`.
            if case .terminated = continuation.yield(event) { continuation.finish() }
        }
    }
}
