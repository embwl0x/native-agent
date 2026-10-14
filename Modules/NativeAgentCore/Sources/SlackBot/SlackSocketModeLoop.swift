import Foundation
import NativeAgentCore
import BackgroundLoops
import ChatOrchestration
import PersistenceCore
import ProviderRouting
import SlackConnector

/// One-way latch marking that a planned session recycle (not a failure)
/// closed the socket. Same lock pattern as SlackPingContinuationGate below.
private final class SlackSessionRecycleFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

private final class SlackPingContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var continuation: CheckedContinuation<Void, Error>?
    /// An outcome that arrived BEFORE the continuation existed. 2026-09-06:
    /// cancellation and the ping deadline can both fire between constructing
    /// this gate and `withCheckedThrowingContinuation` handing over its
    /// continuation, and an outcome dropped in that window would park the
    /// caller forever — the exact hang this gate now exists to prevent.
    private var settled: Result<Void, Error>?

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let settled {
            didResume = true
            lock.unlock()
            continuation.resume(with: settled)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() { settle(.success(())) }

    func resume(throwing error: Error) { settle(.failure(error)) }

    private func settle(_ result: Result<Void, Error>) {
        lock.lock()
        guard !didResume else { lock.unlock(); return }
        guard let continuation else {
            if settled == nil { settled = result }
            lock.unlock()
            return
        }
        didResume = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

enum SlackSocketSessionClosure: Error, Sendable, Equatable {
    case disconnect(reason: String)
}

/// One notice per kind per turn. A reconnect ladder emits up to ten
/// `provider_retry` notices; posting each would bury the channel.
private actor SlackTurnNoticeMemory {
    private var announced: Set<String> = []
    func claim(_ kind: String) -> Bool { announced.insert(kind).inserted }
    /// 2026-09-06: a claim that never reached Slack announced nothing. Giving
    /// it back is what keeps ONE failed post from silencing that kind for the
    /// rest of the turn — the sender would otherwise watch a reconnecting turn
    /// in total silence because the first notice hit a blip.
    func release(_ kind: String) { announced.remove(kind) }
}

public struct SlackSocketModeLoop: LoopRunner {
    @TaskLocal private static var deferAfterHandling: (@Sendable (@escaping @Sendable () async -> Void) async -> Void)?

    /// A settings change must not stop the handler delivering its own receipt.
    @discardableResult
    public static func afterCurrentHandling(_ operation: @escaping @Sendable () async -> Void) async -> Bool {
        if let deferAfterHandling {
            await deferAfterHandling(operation)
            return true
        }
        await operation()
        return false
    }

    public let loopId = "slack_socket_mode"
    public let interval: TimeInterval
    public var tickTimeoutOverride: TimeInterval? { 3_900 }

    // A4.8(a): a tick IS one long-lived socket session, so a healthy session
    // that outlives the watchdog used to be booked as "timeout after 3900s"
    // (hourly failure receipts + pushes since Jul 12). The loop now recycles
    // its own session below the watchdog and reports that as success; the
    // 3900s watchdog remains a genuine hang backstop. Must stay < the
    // tickTimeoutOverride above.
    let sessionRecycleInterval: TimeInterval = 3_600

    private let config: SlackSocketModeConfig
    private let dataRoot: URL
    private let progressChatHandler: SlackSocketModeProgressChatHandler?
    private let botEventIntake: SlackBotEventIntake
    private let session: URLSession
    private let deliveryJournal: SlackInboundDeliveryJournal
    private let historyPollState = SlackHistoryPollState()
    private let conversationCache = SlackConversationCache()
    // LOOPS-2: every spawned handling task is registered here so loop stop can
    // cancel + await it instead of leaking detached work past the tick.
    private let inFlight = SlackInFlightHandlers()
    // LOOPS-5: shared socket-liveness signal that gates history polling.
    private let socketHealth = SlackSocketHealth()
    private let feedRetention: SlackReceiptErrorFeed.Retention = .production

    /// A socket that has said `hello` and has produced a frame or a successful
    /// ping inside this window counts as healthy. Pings run every 25s, so 90s
    /// is three missed heartbeats.
    static let socketHealthGrace: TimeInterval = 90
    /// LOOPS-5: conservative backstop poll that still runs while the socket
    /// looks healthy. Pings can keep succeeding while Slack silently stops
    /// delivering events, and that failure mode is invisible to the socket, so
    /// polling is throttled rather than removed. Default 15 min (vs the old
    /// every-60s poll) — a ~15x reduction in redundant API traffic.
    var historySafetyPollInterval: TimeInterval {
        max(config.historyPollInterval * 10, 900)
    }
    static let shortLivedSessionFloor: TimeInterval = 30
    /// Bounded window in which already-accepted work may finish before the
    /// tick cancels it. Used after a socket-open failure and after a PLANNED
    /// session teardown; see `teardownGrace`.
    static let inFlightCompletionGrace: TimeInterval = 30
    /// How long a socket-mode ping may wait for its pong before the wait is
    /// abandoned. Well inside the 25 s ping interval, so a dead socket is
    /// declared dead on the tick that found it rather than at the next one.
    static let pingResponseDeadline: TimeInterval = 10

    /// Base reconnect spacing between socket sessions. A tick IS one session,
    /// so `interval` is the reconnect delay after a session that ended without
    /// tripping failure backoff. It used to be 2s, which meant a socket that
    /// kept dying just above the failure floor reconnected 30x/minute (live
    /// churn confirmed 2026-08). Slack's own guidance is one connection per
    /// app; 15s is still far faster than any human notices a gap.
    static let defaultReconnectInterval: TimeInterval = 15

    init(
        config: SlackSocketModeConfig,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        interval: TimeInterval = SlackSocketModeLoop.defaultReconnectInterval,
        session: URLSession = .shared,
        botEventIntake: @escaping SlackBotEventIntake,
        progressChatHandler: SlackSocketModeProgressChatHandler? = nil
    ) {
        self.config = config
        self.dataRoot = dataRoot
        self.interval = interval
        self.session = session
        self.progressChatHandler = progressChatHandler
        self.botEventIntake = botEventIntake
        self.deliveryJournal = SlackInboundDeliveryJournal(dataRoot: dataRoot)
    }

    public func tick() async {
        _ = await tickOutcome()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        guard config.enabled else { return .off("Socket Mode off") }
        // Recovery and socket admission share the canonical tick owner, but
        // neither waits for the other's chat generation. Register recovery in
        // the existing child set before opening the socket; every return path
        // below drains that set, including failure before receiveLoop starts.
        let recoveryId = UUID()
        let recovery = Task(priority: .userInitiated) {
            do {
                try await reconcileSavedReplies()
            } catch is CancellationError {
                // The canonical tick is stopping.
            } catch {
                await recordError(context: "inbound_recovery", error: error)
            }
            await inFlight.finish(recoveryId)
        }
        await inFlight.register(recovery, id: recoveryId)
        let outcome = await socketTickOutcome()
        // Socket-open failure must still give bot-token/prepared recovery a
        // bounded opportunity to finish. A held chat turn cannot postpone the
        // next connection attempt forever, and cancellation skips this grace.
        _ = await inFlight.waitForCompletion(timeout: Self.inFlightCompletionGrace)
        await inFlight.cancelAndWaitAll()
        return outcome
    }

    private func socketTickOutcome() async -> LoopTickOutcome {
        let sessionStartedAt = Date()
        do {
            await writeState([
                "connected": .bool(false),
                "connectingAt": .string(Self.nowString()),
                "lastError": .null,
            ])
            let socketURL = try await openSocketURL()
            await writeState([
                "socketUrlOpenedAt": .string(Self.nowString()),
            ])
            let socket = session.webSocketTask(with: socketURL)
            socket.resume()
            // A4.8(a): planned session recycle. When the deadline fires it
            // closes the socket, which surfaces in receiveLoop as a receive
            // error — the flag distinguishes that planned close from a real
            // failure so the tick reports success instead of tripping the
            // watchdog at 3900s.
            let recycleFlag = SlackSessionRecycleFlag()
            let recycleTask = Task { [sessionRecycleInterval] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, sessionRecycleInterval) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                recycleFlag.fire()
                socket.cancel(with: .goingAway, reason: nil)
            }
            defer { recycleTask.cancel() }
            do {
                try await receiveLoop(socket: socket, recycleFlag: recycleFlag)
                socket.cancel(with: .goingAway, reason: nil)
                if Task.isCancelled {
                    await writeState([
                        "connected": .bool(false),
                        "cancelledAt": .string(Self.nowString()),
                    ])
                    return .skipped(reason: "Slack socket mode canceled")
                }
                // A receive loop that returns without a `disconnect` frame is
                // still a session that ended; if it ended fast it is churn, not
                // success, and must reach failure backoff like every other
                // short-lived session.
                let outcome = Self.classifyReceiveLoopReturn(
                    sessionDuration: max(0, Date().timeIntervalSince(sessionStartedAt)),
                    recyclePlanned: recycleFlag.didFire,
                    recycleInterval: sessionRecycleInterval
                )
                switch outcome {
                case .completed(let result):
                    await writeState([
                        "connected": .bool(false),
                        "receiveLoopEndedAt": .string(Self.nowString()),
                        "lastCloseReason": .string("receive_loop_returned"),
                    ])
                    return .completed(result: result)
                case .failed(let error):
                    throw SlackSocketModeError.api(error)
                case .skipped:
                    return outcome
                }
            } catch let closure as SlackSocketSessionClosure {
                socket.cancel(with: .goingAway, reason: nil)
                let outcome = Self.classifySessionClosure(
                    closure,
                    sessionDuration: max(0, Date().timeIntervalSince(sessionStartedAt)),
                    recyclePlanned: recycleFlag.didFire,
                    recycleInterval: sessionRecycleInterval
                )
                switch outcome {
                case .completed(let result):
                    await writeState([
                        "connected": .bool(false),
                        "receiveLoopEndedAt": .string(Self.nowString()),
                        "lastCloseReason": .string(Self.closeReason(for: closure)),
                    ])
                    return .completed(result: result)
                case .failed(let error):
                    throw SlackSocketModeError.api(error)
                case .skipped:
                    return outcome
                }
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                if recycleFlag.didFire {
                    await writeState([
                        "connected": .bool(false),
                        "receiveLoopEndedAt": .string(Self.nowString()),
                        "lastCloseReason": .string("session_recycled"),
                    ])
                    return .completed(
                        result: "Slack socket session recycled after \(Int(sessionRecycleInterval))s")
                }
                throw error
            }
        } catch is CancellationError {
            await writeState([
                "connected": .bool(false),
                "cancelledAt": .string(Self.nowString()),
            ])
            return .skipped(reason: "Slack socket mode canceled")
        } catch {
            await writeState([
                "connected": .bool(false),
                "receiveLoopErroredAt": .string(Self.nowString()),
            ])
            await recordError(context: "socket_mode", error: error)
            // History polling lives inside receiveLoop, so a session that
            // dies BEFORE the loop starts (openSocketURL throw: Slack API
            // down, bad token) used to leave the fallback transport stone
            // dead — no gap-fill until a socket finally opened. One
            // best-effort poll here keeps messages flowing during exactly
            // the outages the fallback exists for. Failure is already the
            // tick's outcome; the poll's own error is recorded, not thrown.
            if config.historyPollEnabled, config.ingressPolicy.isConfigured {
                do {
                    try await pollSlackHistoryOnce()
                    await writeState([
                        "lastHistoryPollAt": .string(Self.nowString()),
                        "lastHistoryPollTrigger": .string("socket_open_failed"),
                        "lastHistoryPollError": .null,
                    ])
                } catch is CancellationError {
                    // Loop is being stopped mid-fallback: report the
                    // cancellation, not a false loop failure (gpt-5.5 MED).
                    await writeState([
                        "connected": .bool(false),
                        "cancelledAt": .string(Self.nowString()),
                    ])
                    return .skipped(reason: "Slack socket mode canceled")
                } catch {
                    await recordError(context: "history_poll", error: error)
                }
            }
            return .failed(error: Self.redact(String(describing: error)))
        }
    }

    private func openSocketURL() async throws -> URL {
        var req = URLRequest(url: Self.apiURL("apps.connections.open"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(config.appToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw SlackSocketModeError.api("apps.connections.open HTTP \(http.statusCode)")
        }
        let parsed = try JSONValue.parse(data)
        guard case .object(let obj) = parsed else {
            throw SlackSocketModeError.api("apps.connections.open returned non-object JSON")
        }
        guard Self.bool(obj["ok"]) == true else {
            throw SlackSocketModeError.api(Self.string(obj["error"]) ?? "apps.connections.open failed")
        }
        guard let urlString = Self.string(obj["url"]),
              let url = URL(string: urlString) else {
            throw SlackSocketModeError.api("apps.connections.open did not return a WebSocket URL")
        }
        return url
    }

    private func receiveLoop(
        socket: URLSessionWebSocketTask,
        recycleFlag: SlackSessionRecycleFlag
    ) async throws {
        let pingTask = Task {
            await pingUntilCancelled(socket: socket)
        }
        let historyPollTask = Task {
            await historyPollUntilCancelled()
        }
        // LOOPS-2: handling used to be spawned into detached `Task {}` blocks
        // that outlived the tick — nothing cancelled them, nothing awaited
        // them, and their outcome never reached the loop's health accounting.
        // Every exit path (return, throw, cancellation) now drains the child
        // tasks AND the tracked handling set before the tick reports.
        do {
            try await receiveLoopBody(socket: socket)
        } catch {
            await drainSessionWork(
                pingTask: pingTask,
                historyPollTask: historyPollTask,
                grace: Self.teardownGrace(closing: error, recyclePlanned: recycleFlag.didFire)
            )
            throw error
        }
        await drainSessionWork(
            pingTask: pingTask,
            historyPollTask: historyPollTask,
            grace: Self.teardownGrace(closing: nil, recyclePlanned: recycleFlag.didFire)
        )
    }

    /// A session that ends ON PURPOSE — the hourly recycle, or Slack's routine
    /// `refresh_requested`/`warning` rotation — used to cancel in-flight chat
    /// generation the instant the socket closed. That leaves the journal row in
    /// `.generating`, which recovery parks as `outcome_unknown` and never
    /// auto-retries (guarding against duplicated tool effects), so the user's
    /// message silently never gets a reply. Give planned teardown a bounded
    /// grace to finish the turn first. Unplanned failure keeps the prompt
    /// cancel: reconnection must not wait on a session that is already broken,
    /// and the crash/fatal-disconnect semantics stay exactly as they were.
    static func teardownGrace(closing error: Error?, recyclePlanned: Bool) -> TimeInterval {
        // Same precedence as `classifySessionClosure`: a fatal disconnect racing
        // the recycle timer is a broken socket, not a planned teardown.
        if let error, let closure = error as? SlackSocketSessionClosure,
           case .disconnect(let reason) = closure {
            return disconnectDisposition(forReason: reason) == .routine ? inFlightCompletionGrace : 0
        }
        return recyclePlanned ? inFlightCompletionGrace : 0
    }

    private func drainSessionWork(
        pingTask: Task<Void, Never>,
        historyPollTask: Task<Void, Never>,
        grace: TimeInterval = 0
    ) async {
        pingTask.cancel()
        historyPollTask.cancel()
        await socketHealth.markDisconnected()
        await historyPollTask.value
        await pingTask.value
        // Canonical loop cancellation short-circuits this wait, so stopping the
        // loop stays prompt.
        if grace > 0 { _ = await inFlight.waitForCompletion(timeout: grace) }
        await inFlight.cancelAndWaitAll()
    }

    private func receiveLoopBody(socket: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            let json: JSONValue
            switch message {
            case .string(let string):
                guard let data = string.data(using: .utf8) else { continue }
                json = try JSONValue.parse(data)
            case .data(let data):
                json = try JSONValue.parse(data)
            @unknown default:
                continue
            }
            guard case .object(let obj) = json else { continue }
            let type = Self.string(obj["type"]) ?? ""
            // LOOPS-5: any received frame proves the socket is alive.
            await socketHealth.markAlive()
            await writeState([
                "lastWebSocketMessageAt": .string(Self.nowString()),
                "lastWebSocketMessageType": .string(type.isEmpty ? "unknown" : type),
            ])
            switch type {
            case "hello":
                await socketHealth.markConnected()
                await writeState([
                    "connected": .bool(true),
                    "connectedAt": .string(Self.nowString()),
                    "lastError": .null,
                ])
            case "disconnect":
                await socketHealth.markDisconnected()
                let reason = Self.string(obj["reason"]) ?? "disconnect"
                await writeState([
                    "connected": .bool(false),
                    "disconnectedAt": .string(Self.nowString()),
                    "disconnectReason": .string(reason),
                ])
                throw SlackSocketSessionClosure.disconnect(reason: reason)
            default:
                let envelopeId = Self.string(obj["envelope_id"])
                await recordEnvelope(envelope: obj, envelopeId: envelopeId)
                guard let inbound = inboundMessage(fromEnvelope: obj) else {
                    if let envelopeId {
                        try await acknowledge(envelopeId: envelopeId, socket: socket)
                    }
                    await recordIgnoredEnvelope(obj)
                    continue
                }
                // Slack treats ACK as ownership transfer. Persist the complete
                // admitted message first so a crash after ACK can recover it.
                // If the journal is unavailable or saturated, leave the
                // envelope unacknowledged and let Slack retain/redeliver it.
                let claim = try await claimInboundBeforeAcknowledging(inbound) {
                    if let envelopeId {
                        try await acknowledge(envelopeId: envelopeId, socket: socket)
                    }
                }
                if claim == .alreadyDelivered { continue }
                // Socket handling stays concurrent (the receive loop must keep
                // acking envelopes), but it is tracked — see spawnInboundHandling.
                await spawnInboundHandling(inbound)
            }
        }
    }

    private static func closeReason(for closure: SlackSocketSessionClosure) -> String {
        switch closure {
        case .disconnect(let reason):
            return "disconnect:\(reason)"
        }
    }

    /// Handling stays tracked while the journal owns admission and settlement.
    func spawnInboundHandling(_ inbound: SlackInboundMessage) async {
        let id = UUID()
        // Socket receipt is background transport work; handling an accepted
        // human message is not. Keep the tracked cancellation/delivery owner,
        // but do not let the chat turn inherit the utility-priority socket
        // loop and starve behind unrelated local builds.
        let task = Task(priority: .userInitiated) {
            _ = await handleDurableInbound(inbound)
            await inFlight.finish(id)
        }
        await inFlight.register(task, id: id)
    }

    func claimInboundBeforeAcknowledging(
        _ inbound: SlackInboundMessage,
        acknowledge: @Sendable () async throws -> Void
    ) async throws -> SlackInboundClaimOutcome {
        let claim = try await deliveryJournal.claim(inbound)
        try await acknowledge()
        return claim
    }

    private func historyPollUntilCancelled() async {
        guard config.historyPollEnabled, config.ingressPolicy.isConfigured else {
            let reason = config.historyPollEnabled
                ? "allowlist_empty_fail_closed"
                : "disabled_by_configuration"
            await writeState([
                "historyPollEnabled": .bool(false),
                "historyPollDisabledAt": .string(Self.nowString()),
                "historyPollDisabledReason": .string(reason),
            ])
            return
        }
        await writeState([
            "historyPollEnabled": .bool(true),
            "historyPollInterval": .double(config.historyPollInterval),
            "historyPollMode": .string("event_driven"),
            "historySafetyPollInterval": .double(historySafetyPollInterval),
        ])
        // LOOPS-5: this task is created fresh per socket session, so
        // `lastPollAt == nil` means "just (re)connected" and produces the
        // gap-fill poll. After that the socket's own health decides.
        var lastPollAt: Date?
        while !Task.isCancelled {
            let now = Date()
            guard let trigger = Self.historyPollTrigger(
                now: now,
                socketHealthy: await socketHealth.isHealthy(now: now),
                lastPollAt: lastPollAt,
                pollInterval: config.historyPollInterval,
                safetyInterval: historySafetyPollInterval
            ) else {
                do {
                    let deadline = Self.historyPollDeadline(
                        socketHealthy: await socketHealth.isHealthy(now: now),
                        lastPollAt: lastPollAt,
                        pollInterval: config.historyPollInterval,
                        safetyInterval: historySafetyPollInterval
                    ) ?? now
                    let delay = max(0.001, deadline.timeIntervalSinceNow)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
                continue
            }
            do {
                try await pollSlackHistoryOnce()
                lastPollAt = Date()
                await writeState([
                    "lastHistoryPollAt": .string(Self.nowString()),
                    "lastHistoryPollTrigger": .string(trigger.rawValue),
                    "lastHistoryPollError": .null,
                ])
            } catch is CancellationError {
                return
            } catch {
                lastPollAt = Date()
                await writeState([
                    "lastHistoryPollAt": .string(Self.nowString()),
                    "lastHistoryPollError": .string(Self.redact(String(describing: error))),
                ])
                await recordError(context: "history_poll", error: error)
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    /// LOOPS-5: pure decision for "should history poll run right now?".
    ///
    /// Old behavior polled every `pollInterval` unconditionally, even while the
    /// socket was connected and delivering the same messages. Now:
    ///   - no poll yet this socket session -> gap-fill (covers reconnects and
    ///     anything missed while the socket was down),
    ///   - socket unhealthy -> keep polling at `pollInterval` (this is the
    ///     fallback transport),
    ///   - socket healthy -> only the infrequent `safetyInterval` backstop,
    ///     because a socket can keep answering pings while Slack silently
    ///     stops delivering events.
    static func historyPollTrigger(
        now: Date,
        socketHealthy: Bool,
        lastPollAt: Date?,
        pollInterval: TimeInterval,
        safetyInterval: TimeInterval
    ) -> SlackHistoryPollTrigger? {
        guard let lastPollAt else { return .gapFill }
        let elapsed = now.timeIntervalSince(lastPollAt)
        if !socketHealthy {
            return elapsed >= pollInterval ? .socketUnhealthy : nil
        }
        return elapsed >= safetyInterval ? .safetyInterval : nil
    }

    /// The next instant at which the current health state can change the poll
    /// decision. Sleeping to this deadline replaces the old ten-second scan;
    /// socket-session cancellation still wakes the task immediately on ping or
    /// transport failure.
    static func historyPollDeadline(
        socketHealthy: Bool,
        lastPollAt: Date?,
        pollInterval: TimeInterval,
        safetyInterval: TimeInterval
    ) -> Date? {
        guard let lastPollAt else { return nil }
        return lastPollAt.addingTimeInterval(
            socketHealthy ? safetyInterval : pollInterval
        )
    }

    private func pollSlackHistoryOnce() async throws {
        let conversations = try await cachedPollableConversations()
        await writeState([
            "lastHistoryPollConversationCount": .int(Int64(conversations.count)),
        ])
        for conversation in conversations {
            if Task.isCancelled { throw CancellationError() }
            try await pollHistory(conversation: conversation)
        }
    }

    func cachedPollableConversations(now: Date = Date()) async throws -> [SlackConversationRef] {
        try Task.checkCancellation()
        if let cached = await conversationCache.value(maxAge: config.historyConversationRefreshInterval, now: now) {
            return cached
        }
        do {
            let conversations = try await pollableConversations()
            try Task.checkCancellation()
            await conversationCache.store(conversations, now: now)
            await writeState(["conversationDiscoveryUsingLastGood": .bool(false)])
            return conversations
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            let lastGood = await conversationCache.lastGoodValue()
            await recordError(context: "conversation_discovery", error: error)
            await writeState(["conversationDiscoveryUsingLastGood": .bool(lastGood != nil)])
            try Task.checkCancellation()
            guard let lastGood else { throw error }
            return lastGood
        }
    }

    private func pollableConversations() async throws -> [SlackConversationRef] {
        var conversations: [SlackConversationRef] = []
        var seenIDs = Set<String>()
        var seenCursors = Set<String>()
        var cursor: String?
        // Bound pathological/changing workspace pagination without publishing a
        // partial list. This allows 20,000 virtual channel entries per refresh.
        for _ in 0..<100 {
            try Task.checkCancellation()
            var params = [
                "exclude_archived": "true",
                "limit": "200",
                "types": "public_channel,private_channel,mpim,im",
            ]
            if let cursor { params["cursor"] = cursor }
            let response = try await slackAPI(
                method: "conversations.list",
                httpMethod: "GET",
                params: params
            )
            try Task.checkCancellation()
            guard Self.bool(response["ok"]) == true else {
                throw SlackSocketModeError.api(Self.string(response["error"]) ?? "conversations.list failed")
            }
            guard case .array(let channels)? = response["channels"] else {
                throw SlackSocketModeError.api("conversations.list returned malformed channels; discovery incomplete")
            }
            let page: [SlackConversationRef] = try channels.compactMap { raw in
                guard case .object(let obj) = raw,
                      let id = Self.string(obj["id"]),
                      !id.isEmpty else {
                    throw SlackSocketModeError.api("conversations.list returned malformed channel entry; discovery incomplete")
                }
                let isIM = Self.bool(obj["is_im"]) == true
                let isMPIM = Self.bool(obj["is_mpim"]) == true
                let isMember = Self.bool(obj["is_member"]) == true
                guard isIM || isMPIM || isMember else { return nil }
                let channelType: String
                if isIM {
                    channelType = "im"
                } else if isMPIM {
                    channelType = "mpim"
                } else if Self.bool(obj["is_private"]) == true {
                    channelType = "group"
                } else {
                    channelType = "channel"
                }
                // When policy is channel-only, avoid fetching any conversation the
                // transport could never admit. A user allowlist still needs all
                // joined conversations so message authors can be evaluated.
                if config.allowedUserIds.isEmpty,
                   !config.allowedChannelIds.contains(id) {
                    return nil
                }
                return SlackConversationRef(id: id, channelType: channelType)
            }
            for conversation in page where seenIDs.insert(conversation.id).inserted {
                conversations.append(conversation)
            }
            guard let metadata = response["response_metadata"] else { return conversations }
            guard case .object(let fields) = metadata else {
                throw SlackSocketModeError.api("conversations.list returned malformed pagination metadata; discovery incomplete")
            }
            guard let nextValue = fields["next_cursor"] else { return conversations }
            guard case .string(let nextCursor) = nextValue else {
                throw SlackSocketModeError.api("conversations.list returned malformed pagination cursor; discovery incomplete")
            }
            guard !nextCursor.isEmpty else { return conversations }
            guard seenCursors.insert(nextCursor).inserted else {
                throw SlackSocketModeError.api("conversations.list repeated pagination cursor; discovery incomplete")
            }
            cursor = nextCursor
        }
        throw SlackSocketModeError.api("conversations.list exceeded 100 pages; discovery incomplete")
    }

    private func historyMessages(
        conversation: SlackConversationRef,
        oldest: String?,
        latest: String
    ) async throws -> [[String: JSONValue]] {
        var params: [String: String] = [
            "channel": conversation.id,
            "inclusive": "false",
            "limit": "8",
            // Keep the collection's upper boundary fixed while cursor paging,
            // so new arrivals belong to the next poll, not this traversal.
            "latest": latest,
        ]
        if let oldest { params["oldest"] = oldest }
        var collected: [[String: JSONValue]] = []
        var seenTimestamps = Set<String>()
        var seenCursors = Set<String>()
        for _ in 0..<100 {
            try Task.checkCancellation()
            let response = try await slackAPI(method: "conversations.history", httpMethod: "GET", params: params)
            try Task.checkCancellation()
            guard Self.bool(response["ok"]) == true else {
                throw SlackSocketModeError.api(Self.string(response["error"]) ?? "conversations.history failed")
            }
            guard case .array(let rawMessages)? = response["messages"] else {
                throw SlackSocketModeError.api("conversations.history returned malformed messages; history incomplete")
            }
            let page: [[String: JSONValue]] = try rawMessages.map { raw in
                guard case .object(let message) = raw,
                      let ts = Self.string(message["ts"]),
                      let value = Decimal(string: ts, locale: Locale(identifier: "en_US_POSIX")),
                      !value.isNaN, value > 0,
                      ts.split(separator: ".", omittingEmptySubsequences: false).count <= 2,
                      ts.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                          !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
                      }) else {
                    throw SlackSocketModeError.api("conversations.history returned malformed message timestamp; history incomplete")
                }
                return message
            }
            for message in page {
                let ts = Self.string(message["ts"])!
                if let oldest, !Self.slackTimestampLessThan(oldest, ts) { continue }
                if seenTimestamps.insert(ts).inserted { collected.append(message) }
            }
            // First enable/restart only seeds the newest observed message.
            // Do not traverse older history or turn bootstrap into replay.
            guard oldest != nil else { return collected }

            let hasMore: Bool
            if let value = response["has_more"] {
                guard case .bool(let flag) = value else {
                    throw SlackSocketModeError.api("conversations.history returned malformed has_more; history incomplete")
                }
                hasMore = flag
            } else { hasMore = false }
            var nextCursor = ""
            if let metadata = response["response_metadata"] {
                guard case .object(let fields) = metadata else {
                    throw SlackSocketModeError.api("conversations.history returned malformed pagination metadata; history incomplete")
                }
                if let value = fields["next_cursor"] {
                    guard case .string(let cursor) = value else {
                        throw SlackSocketModeError.api("conversations.history returned malformed pagination cursor; history incomplete")
                    }
                    nextCursor = cursor
                }
            }
            if !nextCursor.isEmpty {
                guard seenCursors.insert(nextCursor).inserted else {
                    throw SlackSocketModeError.api("conversations.history repeated pagination cursor; history incomplete")
                }
                params["cursor"] = nextCursor
            } else if hasMore {
                // Slack also supports time pagination without a cursor. Keep
                // oldest fixed and require strict movement toward that bound.
                guard let boundary = page.compactMap({ Self.string($0["ts"]) })
                    .min(by: Self.slackTimestampLessThan),
                      let latestBound = params["latest"],
                      let oldestBound = oldest,
                      Self.slackTimestampLessThan(boundary, latestBound),
                      Self.slackTimestampLessThan(oldestBound, boundary) else {
                    throw SlackSocketModeError.api("conversations.history pagination made no progress; history incomplete")
                }
                params["latest"] = boundary
                params.removeValue(forKey: "cursor")
            } else { return collected }
        }
        throw SlackSocketModeError.api("conversations.history exceeded 100 pages; history incomplete")
    }

    func pollHistory(conversation: SlackConversationRef, now: Date = Date()) async throws {
        let oldest = await historyPollState.lastSeen(channelId: conversation.id)
        let latest = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), now.timeIntervalSince1970)
        let messages = try await historyMessages(conversation: conversation, oldest: oldest, latest: latest)
        try Task.checkCancellation()
        guard let newest = messages
            .compactMap({ Self.string($0["ts"]) })
            .max(by: { Self.slackTimestampLessThan($0, $1) }) else {
            return
        }
        let seeded = await historyPollState.seedIfNeeded(channelId: conversation.id, newestTs: newest)
        if seeded { return }

        let ordered = messages.sorted {
            Self.slackTimestampLessThan(
                Self.string($0["ts"]) ?? "0",
                Self.string($1["ts"]) ?? "0"
            )
        }
        // History delivery joins the session's tracked work so planned teardown
        // gives accepted turns the same grace as socket delivery. Awaiting the
        // result also lets the channel cursor advance only past messages the
        // journal has settled. Active or failed delivery stops the watermark.
        var watermark: String?
        var stalledOnFailure = false
        for message in ordered {
            if Task.isCancelled { throw CancellationError() }
            guard let inbound = inboundMessage(fromHistoryMessage: message, conversation: conversation) else {
                // Nothing to deliver (bot / subtype / empty) — safe to skip past.
                if let ts = Self.string(message["ts"]) { watermark = Self.laterTs(watermark, ts) }
                continue
            }
            await writeState([
                "lastHistoryPollMessageAt": .string(Self.nowString()),
                "lastHistoryPollChannelId": .string(conversation.id),
                "lastHistoryPollMessageTs": .string(inbound.ts),
            ])
            let id = UUID()
            let (results, completion) = AsyncStream<Bool>.makeStream()
            let handling = Task(priority: .userInitiated) {
                let delivered = await handleDurableInbound(inbound)
                completion.yield(delivered)
                completion.finish()
                await inFlight.finish(id)
            }
            await inFlight.register(handling, id: id)
            var delivered = false
            // Cancelling history collection stops this wait, while the accepted
            // handler remains owned by the session's bounded completion drain.
            for await result in results { delivered = result }
            try Task.checkCancellation()
            if delivered {
                watermark = Self.laterTs(watermark, inbound.ts)
            } else {
                stalledOnFailure = true
                break
            }
        }
        if !stalledOnFailure {
            watermark = Self.laterTs(watermark, newest)
        }
        if let watermark {
            await historyPollState.markSeen(channelId: conversation.id, ts: watermark)
        }
    }

    private static func laterTs(_ lhs: String?, _ rhs: String) -> String {
        guard let lhs else { return rhs }
        return slackTimestampLessThan(lhs, rhs) ? rhs : lhs
    }

    private func inboundMessage(
        fromHistoryMessage message: [String: JSONValue],
        conversation: SlackConversationRef
    ) -> SlackInboundMessage? {
        if Self.string(message["bot_id"]) != nil { return nil }
        if let subtype = Self.string(message["subtype"]),
           !subtype.isEmpty, subtype != "file_share" { return nil }
        let user = Self.string(message["user"]) ?? ""
        guard !user.isEmpty else { return nil }
        if let botUserId = config.botUserId, user == botUserId { return nil }
        let rawText = Self.string(message["text"]) ?? ""
        guard config.ingressPolicy.denial(
            channelId: conversation.id,
            userId: user,
            eventType: "message",
            channelType: conversation.channelType,
            rawText: rawText
        ) == nil else {
            return nil
        }
        let text = Self.stripBotMention(rawText, botUserId: config.botUserId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let files = Self.inboundFiles(message["files"])
        guard !text.isEmpty || !files.isEmpty else { return nil }
        let ts = Self.string(message["ts"]) ?? ""
        guard !ts.isEmpty else { return nil }
        let teamId = config.teamId ?? "slack"
        return SlackInboundMessage(
            eventId: "\(teamId):\(conversation.id):\(ts)",
            teamId: teamId,
            channelId: conversation.id,
            userId: user,
            eventType: "message",
            text: text,
            ts: ts,
            threadTs: Self.string(message["thread_ts"]),
            channelType: conversation.channelType,
            isDirectMessage: conversation.channelType == "im" || conversation.id.hasPrefix("D"),
            files: files
        )
    }

    private func pingUntilCancelled(socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 25_000_000_000)
                try await sendPing(socket: socket)
                await socketHealth.markAlive()
                await writeState([
                    "connected": .bool(true),
                    "lastPingAt": .string(Self.nowString()),
                ])
            } catch is CancellationError {
                return
            } catch {
                await socketHealth.markDisconnected()
                await writeState([
                    "connected": .bool(false),
                    "lastPingErrorAt": .string(Self.nowString()),
                    "lastPingError": .string(Self.redact(String(describing: error))),
                ])
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    /// 2026-09-06: this parked on a checked continuation that ONLY Slack's pong
    /// handler could resume — no cancellation handling and no deadline. A pong
    /// that never comes is the precise failure a ping exists to detect, and
    /// `drainSessionWork` cancels this task and then AWAITS it, so that silence
    /// held teardown, and therefore reconnection, open forever. Three things
    /// can now finish the wait — the handler, task cancellation, and a bounded
    /// deadline — and the gate keeps the first, discarding the rest.
    private func sendPing(socket: URLSessionWebSocketTask) async throws {
        let gate = SlackPingContinuationGate()
        let deadline = Task {
            try? await Task.sleep(for: .seconds(Self.pingResponseDeadline))
            guard !Task.isCancelled else { return }
            gate.resume(throwing: SlackSocketModeError.api(
                "Slack did not answer a socket-mode ping within \(Int(Self.pingResponseDeadline))s"
            ))
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.attach(continuation)
                socket.sendPing { error in
                    if let error {
                        gate.resume(throwing: error)
                    } else {
                        gate.resume()
                    }
                }
            }
        } onCancel: {
            gate.resume(throwing: CancellationError())
        }
    }

    private func slackAPI(
        method: String,
        httpMethod: String,
        params: [String: String]
    ) async throws -> [String: JSONValue] {
        var components = URLComponents(
            url: Self.apiURL(method),
            resolvingAgainstBaseURL: false
        )!
        if httpMethod == "GET" {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name }
        }
        guard let url = components.url else {
            throw SlackSocketModeError.api("Could not build Slack API URL for \(method)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = httpMethod
        req.timeoutInterval = 30
        req.setValue("Bearer \(config.botToken)", forHTTPHeaderField: "Authorization")
        if httpMethod != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: params)
        }
        let (data, resp) = try await session.data(for: req)
        let parsed = try JSONValue.parse(data)
        guard case .object(let obj) = parsed else {
            throw SlackSocketModeError.api("\(method) returned non-object JSON")
        }
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw SlackSocketModeError.api("\(method) HTTP \(http.statusCode)")
        }
        return obj
    }

    static func apiURL(_ method: String) -> URL {
        SlackConnectorActions.apiURL(method)
    }

    public func recoverReply(_ response: ChatResponse, originRunId: String,
                             route: AgentBridgeCompletionRoute? = nil, priorVerdict: String? = nil) async throws -> String {
        var indexed = try await deliveryJournal.answerRecord(runId: response.runId, originRunId: originRunId)
        if indexed == nil, let route, let session = response.sessionId, let channel = route.destinationId, !channel.isEmpty {
            let inbound = SlackInboundMessage(eventId: "answer:" + response.runId, teamId: config.teamId ?? "",
                channelId: channel, userId: route.requesterUserId ?? "", eventType: "answer", text: "",
                ts: "", threadTs: route.threadId, channelType: nil,
                isDirectMessage: channel.hasPrefix("D"), files: [], opensReplyThread: false)
            indexed = try await deliveryJournal.reserveReply(inbound, reply: Self.preparedReply(response),
                runId: response.runId, sessionId: session, priorVerdict: priorVerdict)
        }
        guard let indexed else {
            throw SlackInboundJournalError.missingClaim(response.runId)
        }
        guard route == nil || indexed.inbound.channelId == route?.destinationId
            && indexed.inbound.inbound.replyThreadTs == route?.threadId else { throw SlackInboundJournalError.malformed }
        let eventId = indexed.inbound.eventId
        guard await deliveryJournal.acquireHandler(eventId: eventId) else { return "owed" }
        do {
            let verdict = try await recoverClaimedReply(response, eventId: eventId, priorVerdict: priorVerdict)
            await deliveryJournal.releaseHandler(eventId: eventId)
            return verdict
        } catch {
            await deliveryJournal.releaseHandler(eventId: eventId)
            throw error
        }
    }

    private func recoverClaimedReply(_ response: ChatResponse, eventId: String, priorVerdict: String?) async throws -> String {
        guard let record = try await deliveryJournal.record(eventId: eventId),
              let session = response.sessionId, record.assistantSessionId == session else {
            throw SlackInboundJournalError.missingClaim(response.runId)
        }
        let inbound = record.inbound.inbound
        guard config.teamId == nil || config.teamId == inbound.teamId,
              inbound.eventType == "answer" || config.allowedChannelIds.contains(inbound.channelId) || config.allowedUserIds.contains(inbound.userId) else {
            throw SlackSocketModeError.api("Recovery paused: current Slack workspace or admission policy no longer matches the accepted message")
        }
        if let phase = record.settledAssistantRuns?[response.runId] {
            guard ["delivered", "sent_unconfirmed", "failed_before_answer"].contains(phase) else { throw SlackInboundJournalError.malformed }
            try SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: response.runId)
            return phase == "delivered" ? "completed" : phase
        }
        if record.assistantRunId == response.runId, record.phase.isTerminal {
            try settleCheckpoint(record)
            return record.phase == .failedBeforeAnswer ? "failed_before_answer"
                : record.phase == .sentUnconfirmed ? "sent_unconfirmed" : "completed"
        }
        if record.assistantRunId != response.runId {
            guard record.phase.isTerminal else { return "owed" }
            try await deliveryJournal.prepareSuccessor(eventId: record.inbound.eventId,
                response: Self.preparedReply(response), runId: response.runId, sessionId: session)
        }
        if record.assistantRunId == response.runId, record.phase == .generating || record.phase == .claimed {
            _ = try await deliveryJournal.prepare(eventId: record.inbound.eventId, reply: Self.preparedReply(response))
        }
        if let priorVerdict {
            let migrated = priorVerdict == "completed"
                ? try await deliveryJournal.markDelivered(eventId: eventId)
                : try await deliveryJournal.settleUnconfirmed(eventId: eventId)
            try settleCheckpoint(migrated)
            return priorVerdict
        }
        guard await processDurableInbound(inbound) else { return "owed" }
        let settled = try await deliveryJournal.record(eventId: record.inbound.eventId)
        return settled?.phase == .failedBeforeAnswer ? "failed_before_answer"
            : settled?.phase == .sentUnconfirmed ? "sent_unconfirmed" : "completed"
    }

    private static func preparedReply(_ response: ChatResponse) -> SlackPreparedReply {
        let uploads = uploadableImageAttachments(response.attachments ?? []).map {
            SlackPreparedUpload(path: $0.path ?? "", name: $0.name ?? URL(fileURLWithPath: $0.path ?? "").lastPathComponent, mime: $0.mime)
        }
        return .make(text: response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !uploads.isEmpty
            ? "Generated image" : response.output, uploads: uploads)
    }

    private func settleCheckpoint(_ record: SlackInboundDeliveryRecord) throws {
        if let session = record.assistantSessionId, let run = record.assistantRunId {
            try SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: run)
        }
    }

    private func acknowledge(envelopeId: String, socket: URLSessionWebSocketTask) async throws {
        let payload = try JSONValue.object([
            "envelope_id": .string(envelopeId),
        ]).serialize(pretty: false)
        try await socket.send(.string(payload))
    }

    private func inboundMessage(fromEnvelope envelope: [String: JSONValue]) -> SlackInboundMessage? {
        guard Self.string(envelope["type"]) == "events_api",
              let payload = Self.object(envelope["payload"]),
              Self.string(payload["type"]) == "event_callback",
              let event = Self.object(payload["event"]) else {
            return nil
        }
        let eventType = Self.string(event["type"]) ?? ""
        guard eventType == "app_mention" || eventType == "message" else { return nil }
        if Self.string(event["bot_id"]) != nil { return nil }
        if let subtype = Self.string(event["subtype"]),
           !subtype.isEmpty, subtype != "file_share" { return nil }

        let channelType = Self.string(event["channel_type"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let channel = Self.string(event["channel"]) ?? ""
        let isSupportedMessageChannel = eventType == "message"
            && Self.isSupportedConversationChannel(channelId: channel, channelType: channelType)
        guard eventType == "app_mention" || isSupportedMessageChannel else { return nil }
        let isDirectMessage = channelType == "im" || channelType == "app_home" || channel.hasPrefix("D")

        let user = Self.string(event["user"]) ?? ""
        guard !user.isEmpty else { return nil }
        if let botUserId = config.botUserId, user == botUserId { return nil }

        let rawText = Self.string(event["text"]) ?? ""
        guard config.ingressPolicy.denial(
            channelId: channel,
            userId: user,
            eventType: eventType,
            channelType: channelType,
            rawText: rawText
        ) == nil else {
            return nil
        }
        let text = Self.stripBotMention(rawText, botUserId: config.botUserId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let files = Self.inboundFiles(event["files"])
        guard !text.isEmpty || !files.isEmpty else { return nil }

        let teamId = Self.string(payload["team_id"]) ?? config.teamId ?? "slack"
        let ts = Self.string(event["ts"]) ?? Self.string(event["event_ts"]) ?? ""
        guard !channel.isEmpty, !ts.isEmpty else { return nil }

        let eventId = "\(teamId):\(channel):\(ts)"
        return SlackInboundMessage(
            eventId: eventId,
            teamId: teamId,
            channelId: channel,
            userId: user,
            eventType: eventType,
            text: text,
            ts: ts,
            threadTs: Self.string(event["thread_ts"]),
            channelType: channelType,
            isDirectMessage: isDirectMessage,
            files: files
        )
    }

    private static func isSupportedConversationChannel(channelId: String, channelType: String?) -> Bool {
        if let channelType {
            switch channelType {
            case "im", "app_home", "mpim", "channel", "group":
                return true
            default:
                break
            }
        }
        return channelId.hasPrefix("D") || channelId.hasPrefix("C") || channelId.hasPrefix("G")
    }

    public func reconcileSavedReplies() async throws {
        for record in try await deliveryJournal.unresolved() {
            guard !Task.isCancelled else { throw CancellationError() }
            let inbound = record.inbound.inbound
            // A credential/workspace change must not replay old workspace
            // work into the newly selected Slack installation.
            guard config.teamId == nil || config.teamId == inbound.teamId,
                  inbound.eventType == "answer" || config.allowedChannelIds.contains(inbound.channelId)
                    || config.allowedUserIds.contains(inbound.userId) else {
                await recordError(
                    context: "inbound_recovery_policy_mismatch",
                    error: SlackSocketModeError.api("Recovery paused: current Slack workspace or admission policy no longer matches the accepted message"),
                    inbound: inbound
                )
                continue
            }
            _ = await handleDurableInbound(inbound)
        }
        if Task.isCancelled { throw CancellationError() }
    }

    /// The production receive/history paths use this durable lifecycle. A
    /// prepared reply may be safely retried without invoking the model again.
    /// A dispatch whose outcome is ambiguous is reconciled, never blindly
    /// replayed. History absence is NOT proof of non-delivery (retention,
    /// deletion, visibility, and eventual consistency can all hide a post).
    @discardableResult
    func handleDurableInbound(_ inbound: SlackInboundMessage) async -> Bool {
        let completion = SlackHandlingCompletion()
        let delivered = await Self.$deferAfterHandling.withValue({ operation in
            await completion.append(operation)
        }) {
            await performDurableInbound(inbound)
        }
        await completion.finish()
        return delivered
    }

    private func performDurableInbound(_ inbound: SlackInboundMessage) async -> Bool {
        guard await deliveryJournal.acquireHandler(eventId: inbound.eventId) else { return false }
        let delivered = await processDurableInbound(inbound)
        await deliveryJournal.releaseHandler(eventId: inbound.eventId)
        return delivered
    }

    private func processDurableInbound(_ received: SlackInboundMessage) async -> Bool {
        do {
            let claim = try await deliveryJournal.claim(received)
            guard case .claimed(var record) = claim else { return true }
            let inbound = record.inbound.inbound
            // Only unresolved messages can wake bots; the durable claim keeps
            // socket, history and recovery from repeating the same fan-out.
            if (try? await deliveryJournal.claimBotEvent(eventId: inbound.eventId)) == true {
                await botEventIntake(inbound.channelId, inbound.text, inbound.userId)
            }
            if record.phase == .claimed, inbound.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/retry resend" {
                if let rejected = try await deliveryJournal.retryRejectedReply(for: inbound) {
                    return await handleDurableInbound(rejected.inbound.inbound)
                }
                let saved = try await deliveryJournal.savedUnconfirmedReply(for: inbound)
                if let saved, let reply = saved.prepared, let session = saved.assistantSessionId {
                    try await deliveryJournal.prepareSuccessor(eventId: saved.inbound.eventId,
                        response: reply, runId: "resend:" + inbound.eventId, sessionId: session)
                    _ = try await deliveryJournal.markDelivered(eventId: inbound.eventId)
                    return await handleDurableInbound(saved.inbound.inbound)
                }
                record = try await deliveryJournal.prepare(eventId: inbound.eventId,
                    reply: .make(text: "There's no saved answer waiting to be delivered.", uploads: []))
            }
            if record.phase == .generating {
                if let session = record.assistantSessionId, let run = record.assistantRunId {
                    if let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: session, runId: run) {
                        record = try await deliveryJournal.prepare(eventId: inbound.eventId, reply: Self.preparedReply(response))
                    } else {
                        // The checkpoint owns an unfinished turn; do not run the inbound again.
                        if try SwiftNativeChatOrchestrationClient.hasReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: run) { return false }
                        record = try await deliveryJournal.prepare(eventId: inbound.eventId,
                            reply: .make(text: "Couldn't finish the reply.", uploads: []), failedBeforeAnswer: true)
                    }
                } else {
                    record = try await deliveryJournal.prepare(eventId: inbound.eventId,
                        reply: .make(text: "Couldn't finish the reply.", uploads: []), failedBeforeAnswer: true)
                }
            }
            if record.phase == .outcomeUnknown && record.prepared == nil {
                if let session = record.assistantSessionId, let run = record.assistantRunId {
                    if let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: session, runId: run) {
                        record = try await deliveryJournal.prepare(eventId: inbound.eventId, reply: Self.preparedReply(response))
                    } else if try SwiftNativeChatOrchestrationClient.hasReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: run) { return false }
                }
            }
            if record.phase == .outcomeUnknown && record.prepared == nil {
                // Older interrupted turns already attempted their once-only
                // notice. Keep the no-replay evidence without a pending slot.
                _ = try await deliveryJournal.settleUnconfirmed(eventId: inbound.eventId, failedBeforeAnswer: true)
                return true
            }
            if record.phase == .dispatching || record.phase == .outcomeUnknown {
                return await reconcileDurableReply(record)
            }
            if record.phase == .claimed {
                let hydration = await hydratingAttachments(inbound)
                guard !hydration.hasTransientFailure else { return false }
                let hydrated = hydration.inbound
                guard hydration.notice != nil || !hydrated.text.isEmpty || !hydrated.attachments.isEmpty else {
                    await recordError(context: "download_inbound_file", error: SlackSocketModeError.api("no supported Slack attachment could be read"), inbound: inbound)
                    return false
                }
                guard !Task.isCancelled else { return false }
                let sessionId = try await SlackSessionStore(dataRoot: dataRoot).activeSessionId(for: inbound)
                let runId = UUID().uuidString
                record = try await deliveryJournal.beginGeneration(eventId: inbound.eventId, runId: runId, sessionId: sessionId)
                let reply: SlackSocketModeReply
                var failedBeforeAnswer = false
                do {
                    reply = try await ChatPersistenceContext.$pinnedTurnRunID.withValue(runId) {
                        try await attachmentAwareReply(hydration, original: inbound)
                    }
                } catch {
                    guard !Task.isCancelled else { return false }
                    failedBeforeAnswer = true
                    await recordError(context: "chat_handler", error: error, inbound: inbound)
                    // Prepare the error notice too. Its delivery is a real
                    // external effect and must not multiply on retry.
                    let detail = error is SlackSessionStorageError
                        ? "Slack conversation storage needs repair before this message can be answered. Existing conversation bindings were preserved."
                        : ProviderRecoveryPolicy.personMessage(error) ?? "Couldn't finish the reply."
                    reply = SlackSocketModeReply(text: (hydration.notice.map { $0 + "\n\n" } ?? "") + detail)
                }
                let uploads = Self.uploadableImageAttachments(reply.attachments).map {
                    SlackPreparedUpload(
                        path: $0.path ?? "",
                        name: $0.name ?? URL(fileURLWithPath: $0.path ?? "").lastPathComponent,
                        mime: $0.mime
                    )
                }
                let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty || !uploads.isEmpty else {
                    await recordError(context: "empty_reply", error: SlackSocketModeError.api("chat returned empty reply"), inbound: inbound)
                    return false
                }
                record = try await deliveryJournal.prepare(
                    eventId: inbound.eventId,
                    reply: .make(text: text.isEmpty ? "Generated image" : text, uploads: uploads),
                    failedBeforeAnswer: failedBeforeAnswer
                )
            }
            guard let prepared = record.prepared else { throw SlackInboundJournalError.malformed }
            guard !TurnQuietHoursWindow.holdsResidentWake(session: record.assistantSessionId, dataRoot: dataRoot) else { return false }
            guard record.lastRejection?.preparedFingerprint != prepared.fingerprint else { return false }
            guard !Task.isCancelled else { return false }
            // Missing local artifacts are a pre-dispatch failure. Preserve the
            // prepared reply and do not rerun the chat/tool turn to recreate it.
            guard prepared.uploads.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                _ = try await deliveryJournal.retryPrepared(eventId: inbound.eventId, detail: "prepared Slack image is no longer available")
                await recordError(context: "prepared_reply_artifact_missing", error: SlackSocketModeError.api("prepared Slack image is no longer available"), inbound: inbound)
                return false
            }
            guard !config.botToken.isEmpty else { throw SlackSocketModeError.api("Slack reply token is unavailable") }
            for upload in prepared.uploads {
                guard !(try Data(contentsOf: URL(fileURLWithPath: upload.path))).isEmpty else {
                    throw SlackSocketModeError.api("Prepared Slack image is empty")
                }
            }
            if record.confirmedText != true {
                _ = try await deliveryJournal.beginDispatch(eventId: inbound.eventId)
                var input: [String: JSONValue] = [
                    "channel": .string(inbound.channelId),
                    "text": .string(prepared.text),
                    "metadata": Self.deliveryMetadata(eventId: inbound.eventId, fingerprint: prepared.fingerprint),
                ]
                if let run = record.assistantRunId, let id = UUID(uuidString: run) { input["client_msg_id"] = .string(id.uuidString) }
                if let threadTs = inbound.replyThreadTs { input["thread_ts"] = .string(threadTs) }
                guard try CodexCompletionLifecycleProjection.permitsDelivery(sessionId: record.assistantSessionId,
                    runId: record.assistantRunId, configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot),
                    dataRoot: dataRoot) else { return false }
                let posted: JSONValue
                do {
                    posted = try await SlackConnectorActions.postMessage(input: input, dataRoot: dataRoot, tokenOverride: config.botToken)
                } catch {
                    return await recordUnknownDelivery(inbound, detail: "Reply dispatch outcome is unknown: \(Self.redact(String(describing: error)))")
                }
                guard Self.envelopeOK(posted) else {
                    if Self.isProvenSlackRejection(posted) {
                        let fields = Self.object(posted)
                        let reason = Self.string(fields?["error"]) ?? Self.string(Self.object(fields?["response"])?["error"]) ?? ""
                        _ = try await deliveryJournal.retryPrepared(eventId: inbound.eventId,
                            detail: "Reply rejected before acceptance: \(reason). Use /retry resend to deliver the saved answer.",
                            rejectionReason: reason)
                        await recordError(context: "post_reply", error: SlackSocketModeError.api(String(describing: posted)), inbound: inbound)
                        return false
                    }
                    return await recordUnknownDelivery(inbound, detail: "Slack returned an ambiguous reply failure")
                }
                record = try await deliveryJournal.confirmReplyPart(eventId: inbound.eventId, isText: true)
            }
            // File completion has no message-metadata hook. Once any upload
            // begins, a failed/crashed attempt is explicitly ambiguous; it is
            // never replayed merely because the text marker is visible.
            for upload in prepared.uploads.dropFirst(record.confirmedUploadCount ?? 0) {
                var uploadInput: [String: JSONValue] = [
                    "channel": .string(inbound.channelId),
                    "file_path": .string(upload.path),
                    "filename": .string(upload.name),
                    "title": .string(upload.name),
                ]
                if let threadTs = inbound.replyThreadTs { uploadInput["thread_ts"] = .string(threadTs) }
                _ = try await deliveryJournal.beginDispatch(eventId: inbound.eventId)
                guard try CodexCompletionLifecycleProjection.permitsDelivery(sessionId: record.assistantSessionId,
                    runId: record.assistantRunId, configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot),
                    dataRoot: dataRoot) else { return false }
                do {
                    guard Self.envelopeOK(try await SlackConnectorActions.uploadFile(input: uploadInput, dataRoot: dataRoot, tokenOverride: config.botToken)) else {
                        return await recordUnknownDelivery(inbound, detail: "Text reply accepted; image completion is unconfirmed")
                    }
                } catch {
                    return await recordUnknownDelivery(inbound, detail: "Text reply accepted; image dispatch outcome is unknown")
                }
                record = try await deliveryJournal.confirmReplyPart(eventId: inbound.eventId, isText: false)
            }
            _ = try await deliveryJournal.markDelivered(eventId: inbound.eventId)
            try settleCheckpoint(record)
            await recordReceipt(kind: "reply", inbound: inbound, reply: prepared.text)
            await writeState([
                "lastDeliveryOutcome": .string("delivered"),
                "lastDeliveryOutcomeEventId": .string(inbound.eventId),
                "lastDeliveryOutcomeDetail": .null,
            ])
            return true
        } catch {
            await recordError(context: "inbound_delivery_journal", error: error, inbound: received)
            return false
        }
    }

    /// Post in-turn notices into the same thread the message came from, once
    /// per kind. A failure to post is not worth failing the turn over — the
    /// reply itself still has the durable delivery lane.
    /// Whichever handler this loop was built with. The progress-carrying one
    /// wins when both are present; the plain one simply never sees the sink.
    private func generateReply(
        _ inbound: SlackInboundMessage,
        sink: @escaping SlackChatProgressSink
    ) async throws -> SlackSocketModeReply {
        if let progressChatHandler {
            return try await progressChatHandler(inbound, sink)
        }
        throw SlackSocketModeError.api("no Slack chat handler configured")
    }

    private func noticeSink(for inbound: SlackInboundMessage) -> SlackChatProgressSink {
        let memory = SlackTurnNoticeMemory()
        // Notices use the same captured credential snapshot as reply delivery.
        let botToken = config.botToken
        let dataRoot = self.dataRoot
        let channelId = inbound.channelId
        let threadTs = inbound.replyThreadTs
        return { kind, text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, await memory.claim(kind) else { return }
            var input: [String: JSONValue] = [
                "channel": .string(channelId),
                "text": .string(trimmed),
            ]
            if let threadTs { input["thread_ts"] = .string(threadTs) }
            let posted = (try? await SlackConnectorActions.postMessage(input: input, dataRoot: dataRoot, tokenOverride: botToken)).map(Self.envelopeOK) ?? false
            if !posted { await memory.release(kind) }
        }
    }

    private func recordUnknownDelivery(_ inbound: SlackInboundMessage, detail: String) async -> Bool {
        do {
            _ = try await deliveryJournal.markOutcomeUnknown(eventId: inbound.eventId, detail: detail)
        } catch {
            await recordError(context: "inbound_delivery_journal", error: error, inbound: inbound)
        }
        await writeState([
            "lastDeliveryOutcome": .string("outcome_unknown"),
            "lastDeliveryOutcomeEventId": .string(inbound.eventId),
            "lastDeliveryOutcomeDetail": .string(detail),
        ])
        await recordError(context: "reply_outcome_unknown", error: SlackSocketModeError.api(detail), inbound: inbound)
        do {
            guard let record = try await deliveryJournal.record(eventId: inbound.eventId) else { return false }
            return await reconcileDurableReply(record)
        } catch { return false }
    }

    private func reconcileDurableReply(_ record: SlackInboundDeliveryRecord) async -> Bool {
        let inbound = record.inbound.inbound
        guard let prepared = record.prepared, let botUserId = config.botUserId, !botUserId.isEmpty else {
            return await settleUnconfirmedReply(record, detail: "Cannot reconcile reply without its prepared artifact and bot identity")
        }
        var params: [String: String] = [
            "channel": inbound.channelId,
            "oldest": inbound.ts,
            "inclusive": "false",
            "include_all_metadata": "true",
            "limit": "100",
        ]
        let method: String
        if let threadTs = inbound.replyThreadTs {
            method = "conversations.replies"
            params["ts"] = threadTs
        } else {
            method = "conversations.history"
        }
        do {
            let response = try await slackAPI(method: method, httpMethod: "GET", params: params)
            guard Self.hasUniqueAcceptedReply(
                response: response,
                inbound: inbound,
                fingerprint: prepared.fingerprint,
                botUserId: botUserId
            ) else {
                return await settleUnconfirmedReply(record, detail: "Slack history does not uniquely prove acceptance")
            }
            guard prepared.uploads.isEmpty else {
                return await settleUnconfirmedReply(record, detail: "Text reply accepted; image completion is unconfirmed")
            }
            _ = try await deliveryJournal.markDelivered(eventId: inbound.eventId)
            try settleCheckpoint(record)
            await recordReceipt(kind: "reply_reconciled", inbound: inbound, reply: prepared.text)
            await writeState([
                "lastDeliveryOutcome": .string("delivered"),
                "lastDeliveryOutcomeEventId": .string(inbound.eventId),
                "lastDeliveryOutcomeDetail": .string("Accepted reply reconciled from Slack history"),
            ])
            return true
        } catch {
            return await settleUnconfirmedReply(record, detail: "Slack reply reconciliation unavailable: \(Self.redact(String(describing: error)))")
        }
    }

    private func settleUnconfirmedReply(_ record: SlackInboundDeliveryRecord, detail: String) async -> Bool {
        do {
            _ = try await deliveryJournal.markOutcomeUnknown(eventId: record.inbound.eventId, detail: detail)
            _ = try await deliveryJournal.settleUnconfirmed(eventId: record.inbound.eventId)
            try settleCheckpoint(record)
            await recordError(context: "reply_sent_unconfirmed", error: SlackSocketModeError.api(detail), inbound: record.inbound.inbound)
            return true
        } catch {
            await recordError(context: "inbound_delivery_journal", error: error, inbound: record.inbound.inbound)
            return false
        }
    }

    static func deliveryMetadata(eventId: String, fingerprint: String) -> JSONValue {
        .object([
            "event_type": .string("nativeagent_reply"),
            "event_payload": .object([
                "event_id": .string(eventId),
                "fingerprint": .string(fingerprint),
            ]),
        ])
    }

    /// Positive proof only. Incomplete/filtered history cannot establish
    /// uniqueness, and a missing message never establishes non-delivery.
    static func hasUniqueAcceptedReply(
        response: [String: JSONValue],
        inbound: SlackInboundMessage,
        fingerprint: String,
        botUserId: String
    ) -> Bool {
        guard bool(response["ok"]) == true,
              bool(response["has_more"]) == false,
              bool(response["is_limited"]) != true,
              string(object(response["response_metadata"])?["next_cursor"])?.isEmpty != false,
              case .array(let messages)? = response["messages"] else { return false }
        var matches = 0
        for raw in messages {
            guard let message = object(raw) else { return false }
            guard let metadata = object(message["metadata"]),
                  string(metadata["event_type"]) == "nativeagent_reply",
                  let payload = object(metadata["event_payload"]),
                  string(payload["event_id"]) == inbound.eventId else { continue }
            guard string(payload["fingerprint"]) == fingerprint,
                  string(message["user"]) == botUserId,
                  let ts = string(message["ts"]), !ts.isEmpty else { return false }
            let thread = string(message["thread_ts"])
            if let expected = inbound.replyThreadTs {
                guard thread == expected else { return false }
            } else if let thread, thread != ts {
                return false
            }
            matches += 1
        }
        return matches == 1
    }

    static func isProvenSlackRejection(_ envelope: JSONValue) -> Bool {
        guard let value = object(envelope), bool(value["ok"]) == false,
              let error = string(value["error"]) ?? string(object(value["response"])?["error"]) else { return false }
        // Slack documents internal_error/fatal_error as potentially partially
        // successful. Only these explicit classes prove non-acceptance.
        return Set([
            "invalid_auth", "not_authed", "token_expired", "token_revoked",
            "missing_scope", "no_permission", "not_in_channel", "channel_not_found",
            "is_archived", "no_text", "msg_too_long", "invalid_arguments",
            "invalid_metadata", "metadata_too_large", "ratelimited", "rate_limited",
        ]).contains(error)
    }

    private enum AttachmentFailure: Error {
        case unsupported, oversized, empty, limit, permanent, transient
    }

    private struct AttachmentHydration {
        static let noticeText = "Some attachments could not be read. Send JPEG, PNG, GIF, or WebP images up to 10 MB each, at most four images and 20 MB total, or paste the text."
        let inbound: SlackInboundMessage
        let failures: [AttachmentFailure]
        var hasTransientFailure: Bool { failures.contains { if case .transient = $0 { return true }; return false } }
        var notice: String? {
            failures.isEmpty ? nil : Self.noticeText
        }
    }

    private func attachmentAwareReply(_ hydration: AttachmentHydration, original: SlackInboundMessage) async throws -> SlackSocketModeReply {
        let inbound = hydration.inbound
        if inbound.text.isEmpty && inbound.attachments.isEmpty {
            return SlackSocketModeReply(text: hydration.notice ?? "No readable message was received.")
        }
        var reply = try await generateReply(inbound, sink: noticeSink(for: original))
        if let notice = hydration.notice { reply.text = notice + "\n\n" + reply.text }
        return reply
    }

    private func hydratingAttachments(_ inbound: SlackInboundMessage) async -> AttachmentHydration {
        var attachments = inbound.attachments
        var failures: [AttachmentFailure] = []
        var remainingBytes = 20 * 1_024 * 1_024
        for (index, file) in inbound.files.enumerated() {
            guard index < 4, remainingBytes > 0 else { failures.append(.limit); continue }
            do {
                let attachment = try await downloadInboundFile(
                    file,
                    maximumBytes: min(10 * 1_024 * 1_024, remainingBytes)
                )
                remainingBytes -= attachment.byteSize
                attachments.append(attachment)
            } catch {
                failures.append((error as? AttachmentFailure) ?? .transient)
                await writeState([
                    "lastInboundAttachmentErrorAt": .string(Self.nowString()),
                    "lastInboundAttachmentError": .string(String(describing: error)),
                ])
            }
        }
        let text = !failures.isEmpty && (!inbound.text.isEmpty || !attachments.isEmpty)
            ? inbound.text + "\n\n[Slack attachment notice: " + AttachmentHydration.noticeText + "]"
            : inbound.text
        let hydrated = SlackInboundMessage(
            eventId: inbound.eventId,
            teamId: inbound.teamId,
            channelId: inbound.channelId,
            userId: inbound.userId,
            eventType: inbound.eventType,
            text: text,
            ts: inbound.ts,
            threadTs: inbound.threadTs,
            channelType: inbound.channelType,
            isDirectMessage: inbound.isDirectMessage,
            files: inbound.files,
            attachments: attachments,
            opensReplyThread: inbound.opensReplyThread
        )
        return AttachmentHydration(inbound: hydrated, failures: failures)
    }

    private func downloadInboundFile(
        _ file: SlackInboundFile,
        maximumBytes: Int
    ) async throws -> ChatOrchestration.MultimodalAttachment {
        let mime = file.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let supportedMIMEs: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]
        guard supportedMIMEs.contains(mime),
              let url = URL(string: file.downloadURL), url.scheme?.lowercased() == "https" else {
            throw AttachmentFailure.unsupported
        }
        if let declared = file.byteSize, declared < 0 || declared > maximumBytes {
            throw AttachmentFailure.oversized
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(config.botToken)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AttachmentFailure.transient
        }
        if !(200..<300).contains(http.statusCode) {
            if (400..<500).contains(http.statusCode), ![408, 425, 429].contains(http.statusCode) {
                throw AttachmentFailure.permanent
            }
            throw AttachmentFailure.transient
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw AttachmentFailure.oversized
        }
        var data = Data()
        data.reserveCapacity(min(file.byteSize ?? 0, maximumBytes))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw AttachmentFailure.oversized
            }
            data.append(byte)
        }
        guard !data.isEmpty else { throw AttachmentFailure.empty }
        return ChatOrchestration.MultimodalAttachment(
            type: "image",
            base64: data.base64EncodedString(),
            mime: mime,
            name: file.name,
            byteSize: data.count
        )
    }

    private static func inboundFiles(_ value: JSONValue?) -> [SlackInboundFile] {
        guard case .array(let rows)? = value else { return [] }
        return rows.compactMap { value in
            guard case .object(let file) = value,
                  let url = string(file["url_private_download"]) ?? string(file["url_private"]),
                  let mime = string(file["mimetype"]) else { return nil }
            let bytes: Int? = {
                switch file["size"] {
                case .int(let value)?: return Int(value)
                case .double(let value)?: return Int(exactly: value.rounded(.towardZero))
                default: return nil
                }
            }()
            return SlackInboundFile(
                downloadURL: url,
                mimeType: mime,
                name: string(file["name"]),
                byteSize: bytes
            )
        }
    }

    private static func uploadableImageAttachments(
        _ attachments: [ChatOrchestration.MultimodalAttachment]
    ) -> [ChatOrchestration.MultimodalAttachment] {
        attachments.filter { attachment in
            attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
        }
    }

    private func recordReceipt(kind: String, inbound: SlackInboundMessage, reply: String) async {
        var row: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "at": .string(Self.nowString()),
            "kind": .string(kind),
            "eventId": .string(inbound.eventId),
            "teamId": .string(inbound.teamId),
            "channelId": .string(inbound.channelId),
            "userId": .string(inbound.userId),
            "ts": .string(inbound.ts),
            "textPreview": .string(Self.preview(inbound.text)),
            "replyPreview": .string(Self.preview(reply)),
        ]
        if let threadTs = inbound.threadTs { row["threadTs"] = .string(threadTs) }
        var statePatch: [String: JSONValue] = [
            "lastReplyAt": .string(Self.nowString()),
            "lastReplyEventId": .string(inbound.eventId),
            "lastReplyChannelId": .string(inbound.channelId),
            "lastError": .null,
            "lastErrorAt": .null,
        ]
        do {
            try await SlackReceiptErrorFeed.append(
                .object(row),
                to: slackDir.appendingPathComponent("receipts.jsonl"),
                using: SlackSocketModeLoop.persistence,
                retention: feedRetention,
                label: "SlackSocketModeLoop.receipts"
            )
            statePatch["lastReceiptFeedWriteError"] = .null
        } catch {
            statePatch["lastReceiptFeedWriteError"] = .string(Self.preview(String(describing: error), limit: 512))
        }
        await writeState(statePatch)
    }

    private func recordEnvelope(envelope: [String: JSONValue], envelopeId: String?) async {
        var patch: [String: JSONValue] = [
            "lastEnvelopeAt": .string(Self.nowString()),
            "lastEnvelopeType": .string(Self.string(envelope["type"]) ?? "unknown"),
        ]
        if let envelopeId, !envelopeId.isEmpty {
            patch["lastEnvelopeId"] = .string(envelopeId)
        }
        if let payload = Self.object(envelope["payload"]) {
            if let payloadType = Self.string(payload["type"]) {
                patch["lastPayloadType"] = .string(payloadType)
            }
            if let event = Self.object(payload["event"]) {
                if let eventType = Self.string(event["type"]) {
                    patch["lastSlackEventType"] = .string(eventType)
                }
                if let channel = Self.string(event["channel"]) {
                    patch["lastEnvelopeChannelId"] = .string(channel)
                }
                if let channelType = Self.string(event["channel_type"]) {
                    patch["lastEnvelopeChannelType"] = .string(channelType)
                }
            }
        }
        await writeState(patch)
    }

    private func recordIgnoredEnvelope(_ envelope: [String: JSONValue]) async {
        let detail = ignoredEnvelopeDetail(envelope)
        var statePatch: [String: JSONValue] = [
            "lastIgnoredAt": .string(Self.nowString()),
            "lastIgnoredReason": .string(detail.reason),
            "lastIgnoredEnvelopeType": .string(detail.envelopeType),
        ]
        if let value = detail.eventType { statePatch["lastIgnoredEventType"] = .string(value) }
        if let value = detail.channelType { statePatch["lastIgnoredChannelType"] = .string(value) }
        if let value = detail.channel { statePatch["lastIgnoredChannelId"] = .string(value) }
        await writeState(statePatch)
    }

    private func ignoredEnvelopeDetail(_ envelope: [String: JSONValue]) -> (
        reason: String,
        envelopeType: String,
        eventType: String?,
        channelType: String?,
        channel: String?
    ) {
        let envelopeType = Self.string(envelope["type"]) ?? "unknown"
        guard envelopeType == "events_api" else {
            return ("unsupported_envelope_type", envelopeType, nil, nil, nil)
        }
        guard let payload = Self.object(envelope["payload"]) else {
            return ("missing_payload", envelopeType, nil, nil, nil)
        }
        let payloadType = Self.string(payload["type"])
        guard payloadType == "event_callback" else {
            return ("unsupported_payload_type", envelopeType, nil, nil, nil)
        }
        guard let event = Self.object(payload["event"]) else {
            return ("missing_event", envelopeType, nil, nil, nil)
        }
        let eventType = Self.string(event["type"])
        let subtype = Self.string(event["subtype"])
        let channelType = Self.string(event["channel_type"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let channel = Self.string(event["channel"])
        let user = Self.string(event["user"])

        if eventType != "app_mention" && eventType != "message" {
            return ("unsupported_event_type", envelopeType, eventType, channelType, channel)
        }
        if Self.string(event["bot_id"]) != nil {
            return ("bot_message", envelopeType, eventType, channelType, channel)
        }
        if let subtype, !subtype.isEmpty {
            return ("message_subtype_\(subtype)", envelopeType, eventType, channelType, channel)
        }
        if let botUserId = config.botUserId, user == botUserId {
            return ("self_message", envelopeType, eventType, channelType, channel)
        }
        if eventType == "message" && !Self.isSupportedConversationChannel(channelId: channel ?? "", channelType: channelType) {
            return ("unsupported_message_channel", envelopeType, eventType, channelType, channel)
        }
        if user?.isEmpty ?? true {
            return ("missing_user", envelopeType, eventType, channelType, channel)
        }
        if let channel, let user,
           let denial = config.ingressPolicy.denial(
               channelId: channel,
               userId: user,
               eventType: eventType ?? "",
               channelType: channelType,
               rawText: Self.string(event["text"]) ?? ""
           ) {
            return (denial.rawValue, envelopeType, eventType, channelType, channel)
        }
        let text = Self.stripBotMention(Self.string(event["text"]) ?? "", botUserId: config.botUserId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return ("empty_text", envelopeType, eventType, channelType, channel)
        }
        let ts = Self.string(event["ts"]) ?? Self.string(event["event_ts"]) ?? ""
        if channel?.isEmpty ?? true || ts.isEmpty {
            return ("missing_channel_or_ts", envelopeType, eventType, channelType, channel)
        }
        return ("unknown_filtered", envelopeType, eventType, channelType, channel)
    }

    private func recordError(context: String, error: Error, inbound: SlackInboundMessage? = nil) async {
        let safeError = Self.preview(String(describing: error), limit: 1_024)
        var row: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "at": .string(Self.nowString()),
            "context": .string(context),
            "errorClass": .string(Self.errorClass(for: error)),
            "error": .string(safeError),
        ]
        if let inbound {
            row["eventId"] = .string(inbound.eventId)
            row["channelId"] = .string(inbound.channelId)
            row["userId"] = .string(inbound.userId)
            if config.ingressPolicy.denial(
                channelId: inbound.channelId, userId: inbound.userId,
                eventType: inbound.eventType, channelType: inbound.channelType,
                rawText: inbound.text
            ) == nil {
                row["textPreview"] = .string(Self.preview(inbound.text))
            }
        }
        var statePatch: [String: JSONValue] = [
            "lastError": .string("\(context): \(safeError)"),
            "lastErrorAt": .string(Self.nowString()),
        ]
        do {
            try await SlackReceiptErrorFeed.append(
                .object(row),
                to: slackDir.appendingPathComponent("errors.jsonl"),
                using: SlackSocketModeLoop.persistence,
                retention: feedRetention,
                label: "SlackSocketModeLoop.errors"
            )
            statePatch["lastErrorFeedWriteError"] = .null
        } catch {
            statePatch["lastErrorFeedWriteError"] = .string(Self.preview(String(describing: error), limit: 512))
        }
        await writeState(statePatch)
    }

    @discardableResult
    private func writeState(_ patch: [String: JSONValue]) async -> SlackRuntimeStateWriteOutcome {
        await SlackRuntimeStateStore.apply(
            patch,
            dataRoot: dataRoot,
            persistence: SlackSocketModeLoop.persistence
        )
    }

    private var slackDir: URL {
        dataRoot.appendingPathComponent("slack", isDirectory: true)
    }

    private static let persistence = SwiftNativePersistenceCore()

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let obj)? = value else { return nil }
        return obj
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let bool)? = value else { return nil }
        return bool
    }

    private static func envelopeOK(_ value: JSONValue) -> Bool {
        guard case .object(let obj) = value,
              case .bool(let ok)? = obj["ok"] else {
            return false
        }
        return ok
    }

    private static func stripBotMention(_ text: String, botUserId: String?) -> String {
        var output = text
        if let botUserId, !botUserId.isEmpty {
            output = output.replacingOccurrences(of: "<@\(botUserId)>", with: "")
        }
        return output
    }

    private static func preview(_ text: String, limit: Int = 240) -> String {
        let trimmed = redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "..."
    }

    private static func slackTimestampLessThan(_ lhs: String, _ rhs: String) -> Bool {
        (Decimal(string: lhs, locale: Locale(identifier: "en_US_POSIX")) ?? 0)
            < (Decimal(string: rhs, locale: Locale(identifier: "en_US_POSIX")) ?? 0)
    }

    static func nowString(_ date: Date = Date()) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }

    private static let redactingExpressions = [
        #"(?i)\b(?:wss?|https?)://[^\s\"<>?#]+[?#][^\s\"<>]*"#,
        #"\bxox[baprs]-[A-Za-z0-9-]{20,}|\bxapp-[A-Za-z0-9-]{20,}\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func redact(_ raw: String) -> String {
        // Socket errors embed authenticated URLs (sometimes more than once).
        // Retain the endpoint for diagnosis, never its query or fragment.
        var safe = TurnSecretRedactor.redactText(raw)
        for regex in redactingExpressions {
            let matches = regex.matches(in: safe, range: NSRange(safe.startIndex..., in: safe))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: safe) else { continue }
                let value = String(safe[range])
                let replacement = value.contains("://")
                    ? String(value.prefix { $0 != "?" && $0 != "#" }) + "?[REDACTED]"
                    : "[REDACTED_SLACK_TOKEN]"
                safe.replaceSubrange(range, with: replacement)
            }
        }
        return safe
    }

    /// Stable diagnostic classes make the bounded feed rankable without
    /// retaining transport payloads or redacted error prose as an identifier.
    private static func errorClass(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is SlackSocketModeError { return "slack_api" }
        if let urlError = error as? URLError {
            return "url_error_\(urlError.errorCode)"
        }
        return "runtime_error"
    }
}
