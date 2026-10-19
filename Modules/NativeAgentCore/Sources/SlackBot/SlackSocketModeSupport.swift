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
