import Foundation
import PersistenceCore
import SlackConnector

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

actor SlackEventDeduper {
    private var seen: [String] = []
    private var seenSet: Set<String> = []
    private var deliveredSet: Set<String> = []
    private let cap: Int

    init(cap: Int = 500) {
        self.cap = max(1, cap)
    }

    func markIfNew(_ id: String) -> Bool {
        guard !id.isEmpty else { return true }
        guard !seenSet.contains(id) else { return false }
        seen.append(id)
        seenSet.insert(id)
        while seen.count > cap {
            let removed = seen.removeFirst()
            seenSet.remove(removed)
            deliveredSet.remove(removed)
        }
        return true
    }

    /// A mark alone means "delivery in flight — or failed and about to be
    /// unmarked." Only a confirmed delivery may let the history poller advance
    /// its watermark past the message: a dedupe hit on an IN-FLIGHT mark can
    /// still fail and unmark afterwards, and a watermark that already moved
    /// past it would skip the message forever (gpt-5.5 review BLOCKING).
    func confirmDelivered(_ id: String) {
        guard !id.isEmpty, seenSet.contains(id) else { return }
        deliveredSet.insert(id)
    }

    /// LOOPS-2: release a mark whose delivery failed. Without this the mark is
    /// a permanent tombstone — the message counts as "seen" forever while
    /// never having been delivered, so no retry path can ever reach it.
    func unmark(_ id: String) {
        guard !id.isEmpty, seenSet.contains(id) else { return }
        seenSet.remove(id)
        deliveredSet.remove(id)
        if let index = seen.lastIndex(of: id) {
            seen.remove(at: index)
        }
    }

    func hasSeen(_ id: String) -> Bool {
        seenSet.contains(id)
    }

    func isDelivered(_ id: String) -> Bool {
        deliveredSet.contains(id)
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

    var count: Int { tasks.count }
    var completionWaiterCount: Int { completionWaiters.count }

    func register(_ task: Task<Void, Never>, id: UUID) {
        // The task may already have completed before we got here; don't
        // resurrect a finished entry (that would leak a handle forever).
        if finished.remove(id) != nil { return }
        tasks[id] = task
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
    /// Deliberately POLLS the registry instead of `await task.value`: awaiting
    /// the value of a non-throwing task does not respond to cancellation, so
    /// any structure that awaits it (including a task group, which must drain
    /// its children before returning) inherits the wedge — the first cut of
    /// this fix deadlocked exactly that way. `finish(id)` empties the registry
    /// as each handler completes; a handler that never finishes is what the
    /// deadline is for.
    @discardableResult
    func cancelAndWaitAll(timeout: TimeInterval = 10) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while !tasks.isEmpty, Date() < deadline {
            // Re-cancel each round: a handler registered after entry (receive
            // loop racing shutdown) must still get the cancellation signal.
            for (_, task) in tasks { task.cancel() }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let abandoned = tasks.count
        tasks.removeAll()
        finished.removeAll()
        notifyCompletionIfEmpty()
        return abandoned
    }
}

/// Thin transport seam: ownership, receive dispatch, ACKs, and cancellation
/// remain in the loop. Tests can hold real receive-loop work without a socket.
struct SlackSocketConnection: Sendable {
    var resume: @Sendable () -> Void
    var cancel: @Sendable () -> Void
    var receive: @Sendable () async throws -> URLSessionWebSocketTask.Message
    var send: @Sendable (URLSessionWebSocketTask.Message) async throws -> Void
    var sendPing: @Sendable (@escaping @Sendable (Error?) -> Void) -> Void

    static func live(_ socket: URLSessionWebSocketTask) -> Self {
        Self(
            resume: { socket.resume() },
            cancel: { socket.cancel(with: .goingAway, reason: nil) },
            receive: { try await socket.receive() },
            send: { try await socket.send($0) },
            sendPing: { socket.sendPing(pongReceiveHandler: $0) }
        )
    }
}

/// Injection seam for the two Slack write calls the loop makes. Production uses
/// `.live`; tests substitute a recorder so no test can post to a real workspace.
struct SlackSocketModeOutbound: Sendable {
    var postMessage: @Sendable (_ input: [String: JSONValue]) async throws -> JSONValue
    var uploadFile: @Sendable (_ input: [String: JSONValue]) async throws -> JSONValue

    static func live(dataRoot: URL, botToken: String) -> SlackSocketModeOutbound {
        // Inbound, reply, and reconciliation must use one credential snapshot;
        // the two persisted token stores can legitimately differ during repair.
        SlackSocketModeOutbound(
            postMessage: { try await SlackConnectorActions.postMessage(input: $0, dataRoot: dataRoot, tokenOverride: botToken) },
            uploadFile: { try await SlackConnectorActions.uploadFile(input: $0, dataRoot: dataRoot, tokenOverride: botToken) }
        )
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
