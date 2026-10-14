import Foundation

struct SlackConversationRef: Sendable, Equatable {
    let id: String
    let channelType: String
}

actor SlackConversationCache {
    private var conversations: [SlackConversationRef] = []
    private var loadedAt: Date?

    func lastGoodValue() -> [SlackConversationRef]? {
        loadedAt == nil ? nil : conversations
    }

    func value(maxAge: TimeInterval, now: Date = Date()) -> [SlackConversationRef]? {
        guard let loadedAt,
              now.timeIntervalSince(loadedAt) < maxAge else {
            return nil
        }
        return conversations
    }

    func store(_ conversations: [SlackConversationRef], now: Date = Date()) {
        self.conversations = conversations
        self.loadedAt = now
    }
}

actor SlackHistoryPollState {
    private var lastSeenByChannel: [String: String] = [:]

    func lastSeen(channelId: String) -> String? {
        lastSeenByChannel[channelId]
    }

    func seedIfNeeded(channelId: String, newestTs: String) -> Bool {
        if lastSeenByChannel[channelId] != nil { return false }
        lastSeenByChannel[channelId] = newestTs
        return true
    }

    func markSeen(channelId: String, ts: String) {
        let current = lastSeenByChannel[channelId] ?? "0"
        if (Decimal(string: ts, locale: Locale(identifier: "en_US_POSIX")) ?? 0)
            >= (Decimal(string: current, locale: Locale(identifier: "en_US_POSIX")) ?? 0) {
            lastSeenByChannel[channelId] = ts
        }
    }
}

/// LOOPS-5: which condition released the history poll. Persisted to state.json
/// so an operator can tell a gap-fill from the safety backstop.
enum SlackHistoryPollTrigger: String, Sendable, Equatable {
    /// First poll of a socket session — covers the reconnect gap.
    case gapFill = "gap_fill"
    /// The socket is not delivering; history is the fallback transport.
    case socketUnhealthy = "socket_unhealthy"
    /// Infrequent backstop against a socket that pings fine but delivers nothing.
    case safetyInterval = "safety_interval"
}

/// LOOPS-5: socket liveness shared between the receive loop, the ping task and
/// the history poller.
actor SlackSocketHealth {
    private var connected = false
    private var lastAliveAt: Date?

    func markConnected(now: Date = Date()) {
        connected = true
        lastAliveAt = now
    }

    /// A frame arrived or a ping round-tripped — either proves the transport
    /// works, even if `hello` has not been seen yet.
    func markAlive(now: Date = Date()) {
        connected = true
        lastAliveAt = now
    }

    func markDisconnected() {
        connected = false
        lastAliveAt = nil
    }

    func isHealthy(now: Date = Date(), grace: TimeInterval = SlackSocketModeLoop.socketHealthGrace) -> Bool {
        guard connected, let lastAliveAt else { return false }
        return now.timeIntervalSince(lastAliveAt) <= grace
    }
}

/// LOOPS-2: registry of handling tasks spawned by the loop, so loop stop can
/// cancel and await them instead of letting detached work escape the tick.
actor SlackInFlightHandlers {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var finished: Set<UUID> = []
    private var completionWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var draining = false

    func register(_ task: Task<Void, Never>, id: UUID) {
        // The task may already have completed before we got here; don't
        // resurrect a finished entry (that would leak a handle forever).
        if finished.remove(id) != nil { return }
        tasks[id] = task
        if draining { task.cancel() }
    }

    func finish(_ id: UUID) {
        if tasks.removeValue(forKey: id) == nil {
            finished.insert(id)
        }
        notifyCompletionIfEmpty()
    }

    private func notifyCompletionIfEmpty() {
        guard tasks.isEmpty else { return }
        let waiters = completionWaiters.values
        completionWaiters.removeAll()
        for waiter in waiters { waiter.finish() }
    }

    /// A short grace for already-owned work after socket-open failure. This
    /// does not create an owner or release any task; the caller must follow it
    /// with cancelAndWaitAll. Canonical cancellation ends the grace promptly.
    func waitForCompletion(timeout: TimeInterval) async -> Bool {
        guard !tasks.isEmpty, !Task.isCancelled, timeout > 0 else { return tasks.isEmpty }
        let id = UUID()
        let (events, continuation) = AsyncStream<Void>.makeStream()
        // Registration and the empty check are in one actor turn, so a
        // concurrent finish cannot be lost between observing and subscribing.
        completionWaiters[id] = continuation
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                continuation.finish()
            } catch {
                // Completion or canonical cancellation retired this deadline.
            }
        }
        // AsyncStream iteration terminates on task cancellation without an
        // unowned cancellation-relay task. The sole deadline is always joined.
        for await _ in events {}
        deadline.cancel()
        await deadline.value
        completionWaiters.removeValue(forKey: id)?.finish()
        return tasks.isEmpty
    }

    /// Bounded: a handler that ignores cooperative cancellation must not
    /// deadlock loop stop or socket recycle (gpt-5.5 review MEDIUM). After
    /// `timeout` the remaining tasks are abandoned — they are already
    /// cancelled, and shutdown cannot hang on a wedged provider call.
    /// Returns how many tasks were abandoned (0 = clean drain).
    ///
    /// Waits for registry completion in a separately owned task so a cancelled
    /// caller still gives handlers a bounded grace. Late registrations are
    /// cancelled too; no wait joins a potentially wedged handler's task value.
    @discardableResult
    func cancelAndWaitAll(timeout: TimeInterval = 10) async -> Int {
        draining = true
        for task in tasks.values { task.cancel() }
        _ = await Task.detached { await self.waitForCompletion(timeout: timeout) }.value
        draining = false
        let abandoned = tasks.count
        tasks.removeAll()
        finished.removeAll()
        notifyCompletionIfEmpty()
        return abandoned
    }
}

/// Settings restarts wait for the inbound handler's reply delivery to settle.
actor SlackHandlingCompletion {
    private var operations: [@Sendable () async -> Void] = []

    func append(_ operation: @escaping @Sendable () async -> Void) {
        operations.append(operation)
    }

    func finish() {
        let pending = operations
        operations.removeAll()
        guard !pending.isEmpty else { return }
        Task.detached {
            for operation in pending { await operation() }
        }
    }
}

enum SlackSocketModeError: Error, CustomStringConvertible {
    case api(String)

    var description: String {
        switch self {
        case .api(let message): return message
        }
    }
}
