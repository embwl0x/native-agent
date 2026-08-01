import Foundation
import BackgroundLoops
import ChatOrchestration
import PersistenceCore
import SlackConnector

struct SlackSocketModeConfig: Sendable, Equatable {
    let botToken: String
    let appToken: String
    let botUserId: String?
    let teamId: String?
    let enabled: Bool
    let historyPollEnabled: Bool
    let historyPollInterval: TimeInterval
    let historyConversationRefreshInterval: TimeInterval
    // 2026-07-21 audit fix: transport allowlist (mirrors TelegramConfig).
    // Empty sets = open (prior behavior); when either is configured, only
    // those channels/users may drive chat turns.
    let allowedChannelIds: Set<String>
    let allowedUserIds: Set<String>

    static func load(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> SlackSocketModeConfig? {
        let objects = tokenObjects(dataRoot: dataRoot)
        let botToken = firstString(keys: ["access_token", "bot_token"], in: objects)
        let appToken = firstString(keys: ["socket_mode_app_token", "app_token", "slack_app_token"], in: objects)
        guard let botToken, !botToken.isEmpty,
              let appToken, !appToken.isEmpty else {
            return nil
        }
        let enabled = firstBool(keys: ["socket_mode_enabled", "inbound_enabled"], in: objects) ?? true
        let historyPollEnabled = firstBool(
            keys: ["history_poll_enabled", "socket_mode_history_poll_enabled"],
            in: objects
        ) ?? true
        let historyPollInterval = max(
            30,
            firstDouble(keys: ["history_poll_interval", "socket_mode_history_poll_interval"], in: objects) ?? 60
        )
        let historyConversationRefreshInterval = max(
            historyPollInterval,
            firstDouble(
                keys: ["history_conversation_refresh_interval", "socket_mode_history_conversation_refresh_interval"],
                in: objects
            ) ?? 600
        )
        return SlackSocketModeConfig(
            botToken: botToken,
            appToken: appToken,
            botUserId: firstString(keys: ["user_id", "bot_user_id", "bot_id"], in: objects),
            teamId: firstString(keys: ["team_id"], in: objects),
            enabled: enabled,
            historyPollEnabled: historyPollEnabled,
            historyPollInterval: historyPollInterval,
            historyConversationRefreshInterval: historyConversationRefreshInterval,
            allowedChannelIds: firstStringSet(
                keys: ["allowed_channel_ids", "allowedChannelIds", "allowed_chat_ids", "allowedChatIds"],
                in: objects
            ),
            allowedUserIds: firstStringSet(
                keys: ["allowed_user_ids", "allowedUserIds"],
                in: objects
            )
        )
    }

    private static func tokenObjects(dataRoot: URL) -> [[String: Any]] {
        let paths = [
            dataRoot
                .appendingPathComponent("connectors", isDirectory: true)
                .appendingPathComponent("slack", isDirectory: true)
                .appendingPathComponent("auth.json"),
            dataRoot
                .appendingPathComponent("oauth_tokens", isDirectory: true)
                .appendingPathComponent("slack.json"),
        ]
        return paths.compactMap { path in
            guard let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return obj
        }
    }

    private static func firstStringSet(keys: [String], in objects: [[String: Any]]) -> Set<String> {
        // UNION across all files and aliases (2026-07-21 gpt-5.5 review):
        // SecurityCenter's slack allowlist unions the same sources — the
        // transport gate must not be stricter than the trust root (first-
        // non-empty previously let one file shadow another's channels).
        var result: Set<String> = []
        for object in objects {
            for key in keys {
                if let array = object[key] as? [String] {
                    result.formUnion(array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                } else if let array = object[key] as? [Any] {
                    result.formUnion(array.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                }
            }
        }
        return result
    }

    private static func firstString(keys: [String], in objects: [[String: Any]]) -> String? {
        for object in objects {
            for key in keys {
                guard let value = object[key] as? String else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func firstBool(keys: [String], in objects: [[String: Any]]) -> Bool? {
        for object in objects {
            for key in keys {
                if let value = object[key] as? Bool { return value }
                if let value = object[key] as? String {
                    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                    case "1", "true", "yes", "on": return true
                    case "0", "false", "no", "off": return false
                    default: continue
                    }
                }
            }
        }
        return nil
    }

    private static func firstDouble(keys: [String], in objects: [[String: Any]]) -> Double? {
        for object in objects {
            for key in keys {
                if let value = object[key] as? Double { return value }
                if let value = object[key] as? Int { return Double(value) }
                if let value = object[key] as? String,
                   let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return parsed
                }
            }
        }
        return nil
    }
}

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
    private let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        guard claim() else { return }
        continuation.resume()
    }

    func resume(throwing error: Error) {
        guard claim() else { return }
        continuation.resume(throwing: error)
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

struct SlackInboundMessage: Sendable, Equatable {
    let eventId: String
    let teamId: String
    let channelId: String
    let userId: String
    let eventType: String
    let text: String
    let ts: String
    let threadTs: String?
    let channelType: String?
    let isDirectMessage: Bool

    var sessionKey: String {
        if let threadTs = normalizedThreadTs {
            return "thread:\(teamId):\(channelId):\(threadTs)"
        }
        return "conversation:\(teamId):\(channelId)"
    }

    var replyThreadTs: String? {
        normalizedThreadTs
    }

    var normalizedThreadTs: String? {
        guard let threadTs else { return nil }
        let trimmed = threadTs.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SlackSocketModeReply: Sendable, Equatable {
    var text: String
    var attachments: [ChatOrchestration.MultimodalAttachment]

    init(
        text: String,
        attachments: [ChatOrchestration.MultimodalAttachment] = []
    ) {
        self.text = text
        self.attachments = attachments
    }
}

typealias SlackSocketModeChatHandler = @Sendable (_ message: SlackInboundMessage) async throws -> SlackSocketModeReply

struct SlackSocketModeLoop: LoopRunner {
    let loopId = "slack_socket_mode"
    let interval: TimeInterval
    var tickTimeoutOverride: TimeInterval? { 3_900 }

    // A4.8(a): a tick IS one long-lived socket session, so a healthy session
    // that outlives the watchdog used to be booked as "timeout after 3900s"
    // (hourly failure receipts + pushes since Jul 12). The loop now recycles
    // its own session below the watchdog and reports that as success; the
    // 3900s watchdog remains a genuine hang backstop. Must stay < the
    // tickTimeoutOverride above (pinned in SlackSocketModeLoopTests).
    let sessionRecycleInterval: TimeInterval

    private let config: SlackSocketModeConfig
    private let dataRoot: URL
    private let chatHandler: SlackSocketModeChatHandler
    private let session: URLSession
    private let deduper = SlackEventDeduper()
    private let historyPollState = SlackHistoryPollState()
    private let conversationCache = SlackConversationCache()
    // LOOPS-2: every spawned handling task is registered here so loop stop can
    // cancel + await it instead of leaking detached work past the tick.
    private let inFlight = SlackInFlightHandlers()
    // LOOPS-5: shared socket-liveness signal that gates history polling.
    private let socketHealth = SlackSocketHealth()
    private let outbound: SlackSocketModeOutbound

    /// A socket that has said `hello` and has produced a frame or a successful
    /// ping inside this window counts as healthy. Pings run every 25s, so 90s
    /// is three missed heartbeats.
    static let socketHealthGrace: TimeInterval = 90
    /// How often the history-poll task re-evaluates its trigger while idle.
    static let historyPollCheckInterval: TimeInterval = 10

    /// LOOPS-5: conservative backstop poll that still runs while the socket
    /// looks healthy. Pings can keep succeeding while Slack silently stops
    /// delivering events, and that failure mode is invisible to the socket, so
    /// polling is throttled rather than removed. Default 15 min (vs the old
    /// every-60s poll) — a ~15x reduction in redundant API traffic.
    var historySafetyPollInterval: TimeInterval {
        max(config.historyPollInterval * 10, 900)
    }

    init(
        config: SlackSocketModeConfig,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        interval: TimeInterval = 2,
        sessionRecycleInterval: TimeInterval = 3_600,
        session: URLSession = .shared,
        outbound: SlackSocketModeOutbound = .live,
        chatHandler: @escaping SlackSocketModeChatHandler
    ) {
        self.config = config
        self.dataRoot = dataRoot
        self.interval = interval
        self.sessionRecycleInterval = sessionRecycleInterval
        self.session = session
        self.outbound = outbound
        self.chatHandler = chatHandler
    }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        guard config.enabled else { return .skipped(reason: "Slack socket mode disabled") }
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
                try await receiveLoop(socket: socket)
                socket.cancel(with: .goingAway, reason: nil)
                await writeState([
                    "connected": .bool(false),
                    "receiveLoopEndedAt": .string(Self.nowString()),
                    "lastCloseReason": .string("receive_loop_returned"),
                ])
                return .completed(result: "Slack socket receive loop ended")
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
            if config.historyPollEnabled {
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
        var req = URLRequest(url: URL(string: "https://slack.com/api/apps.connections.open")!)
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

    private func receiveLoop(socket: URLSessionWebSocketTask) async throws {
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
            await drainSessionWork(pingTask: pingTask, historyPollTask: historyPollTask)
            throw error
        }
        await drainSessionWork(pingTask: pingTask, historyPollTask: historyPollTask)
    }

    private func drainSessionWork(
        pingTask: Task<Void, Never>,
        historyPollTask: Task<Void, Never>
    ) async {
        pingTask.cancel()
        historyPollTask.cancel()
        await socketHealth.markDisconnected()
        await historyPollTask.value
        await pingTask.value
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
                await writeState([
                    "connected": .bool(false),
                    "disconnectedAt": .string(Self.nowString()),
                    "disconnectReason": .string(Self.string(obj["reason"]) ?? "disconnect"),
                ])
                return
            default:
                let envelopeId = Self.string(obj["envelope_id"])
                if let envelopeId {
                    try await acknowledge(envelopeId: envelopeId, socket: socket)
                }
                await recordEnvelope(envelope: obj, envelopeId: envelopeId)
                guard let inbound = inboundMessage(fromEnvelope: obj) else {
                    await recordIgnoredEnvelope(obj)
                    continue
                }
                let shouldProcess = await deduper.markIfNew(inbound.eventId)
                guard shouldProcess else { continue }
                // Socket handling stays concurrent (the receive loop must keep
                // acking envelopes), but it is tracked — see spawnInboundHandling.
                await spawnInboundHandling(inbound)
            }
        }
    }

    /// LOOPS-2: spawn handling into the tracked set, and unmark the deduper if
    /// delivery failed so the message is retryable instead of permanently
    /// swallowed by a "seen" entry that never produced a reply.
    func spawnInboundHandling(_ inbound: SlackInboundMessage) async {
        let id = UUID()
        let task = Task {
            let delivered = await handleInbound(inbound)
            if delivered {
                await deduper.confirmDelivered(inbound.eventId)
            } else {
                await deduper.unmark(inbound.eventId)
            }
            await inFlight.finish(id)
        }
        await inFlight.register(task, id: id)
    }

    /// Test/lifecycle seam: cancel and await everything the loop spawned.
    func cancelAndWaitInFlightHandling() async {
        await inFlight.cancelAndWaitAll()
    }

    var inFlightHandlingCount: Int {
        get async { await inFlight.count }
    }

    private func historyPollUntilCancelled() async {
        guard config.historyPollEnabled else {
            await writeState([
                "historyPollEnabled": .bool(false),
                "historyPollDisabledAt": .string(Self.nowString()),
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
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.historyPollCheckInterval * 1_000_000_000))
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

    private func cachedPollableConversations() async throws -> [SlackConversationRef] {
        if let cached = await conversationCache.value(maxAge: config.historyConversationRefreshInterval) {
            return cached
        }
        let conversations = try await pollableConversations()
        await conversationCache.store(conversations)
        return conversations
    }

    private func pollableConversations() async throws -> [SlackConversationRef] {
        let response = try await slackAPI(
            method: "conversations.list",
            httpMethod: "GET",
            params: [
                "exclude_archived": "true",
                "limit": "200",
                "types": "public_channel,private_channel,mpim,im",
            ]
        )
        guard Self.bool(response["ok"]) == true else {
            throw SlackSocketModeError.api(Self.string(response["error"]) ?? "conversations.list failed")
        }
        guard case .array(let channels)? = response["channels"] else { return [] }
        return channels.compactMap { raw in
            guard case .object(let obj) = raw,
                  let id = Self.string(obj["id"]),
                  !id.isEmpty else {
                return nil
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
            return SlackConversationRef(id: id, channelType: channelType)
        }
    }

    private func pollHistory(conversation: SlackConversationRef) async throws {
        var params: [String: String] = [
            "channel": conversation.id,
            "inclusive": "false",
            "limit": "8",
        ]
        if let oldest = await historyPollState.lastSeen(channelId: conversation.id) {
            params["oldest"] = oldest
        }
        let response = try await slackAPI(
            method: "conversations.history",
            httpMethod: "GET",
            params: params
        )
        guard Self.bool(response["ok"]) == true else {
            await writeState([
                "lastHistoryPollChannelId": .string(conversation.id),
                "lastHistoryPollError": .string(Self.string(response["error"]) ?? "conversations.history failed"),
            ])
            return
        }
        guard case .array(let rawMessages)? = response["messages"] else { return }
        let messages: [[String: JSONValue]] = rawMessages.compactMap { raw in
            guard case .object(let obj) = raw else { return nil }
            return obj
        }
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
        // LOOPS-2: history delivery is awaited inline (structured) instead of
        // fired into a detached Task, so the poll task owns its lifecycle and
        // cancellation reaches it. It also lets the channel cursor advance only
        // past messages that actually got delivered: a failed delivery unmarks
        // the deduper AND stops the watermark, so the next poll re-fetches and
        // retries it rather than losing it forever.
        var watermark: String?
        var stalledOnFailure = false
        for message in ordered {
            if Task.isCancelled { throw CancellationError() }
            guard let inbound = inboundMessage(fromHistoryMessage: message, conversation: conversation) else {
                // Nothing to deliver (bot / subtype / empty) — safe to skip past.
                if let ts = Self.string(message["ts"]) { watermark = Self.laterTs(watermark, ts) }
                continue
            }
            let shouldProcess = await deduper.markIfNew(inbound.eventId)
            guard shouldProcess else {
                // Dedupe hit. Only a CONFIRMED delivery justifies moving the
                // watermark past this message — an in-flight socket delivery
                // can still fail and unmark, and a watermark already past it
                // would skip the message forever (gpt-5.5 review BLOCKING).
                // In-flight: stop here and let the next poll re-check; by then
                // the mark has either been confirmed or released.
                if await deduper.isDelivered(inbound.eventId) {
                    watermark = Self.laterTs(watermark, inbound.ts)
                    continue
                }
                stalledOnFailure = true
                break
            }
            await writeState([
                "lastHistoryPollMessageAt": .string(Self.nowString()),
                "lastHistoryPollChannelId": .string(conversation.id),
                "lastHistoryPollMessageTs": .string(inbound.ts),
            ])
            let delivered = await handleInbound(inbound)
            if delivered {
                await deduper.confirmDelivered(inbound.eventId)
                watermark = Self.laterTs(watermark, inbound.ts)
            } else {
                await deduper.unmark(inbound.eventId)
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
        if let subtype = Self.string(message["subtype"]), !subtype.isEmpty { return nil }
        let user = Self.string(message["user"]) ?? ""
        guard !user.isEmpty else { return nil }
        if let botUserId = config.botUserId, user == botUserId { return nil }
        let rawText = Self.string(message["text"]) ?? ""
        let text = Self.stripBotMention(rawText, botUserId: config.botUserId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
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
            isDirectMessage: conversation.channelType == "im" || conversation.id.hasPrefix("D")
        )
    }

    private func pingUntilCancelled(socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 25_000_000_000)
                try await sendPing(socket: socket)
                await socketHealth.markAlive()
                await writeState([
                    "lastPingAt": .string(Self.nowString()),
                    "lastPingError": .null,
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

    private func sendPing(socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = SlackPingContinuationGate(continuation)
            socket.sendPing { error in
                if let error {
                    gate.resume(throwing: error)
                } else {
                    gate.resume()
                }
            }
        }
    }

    private func slackAPI(
        method: String,
        httpMethod: String,
        params: [String: String]
    ) async throws -> [String: JSONValue] {
        var components = URLComponents(
            url: URL(string: "https://slack.com/api/\(method)")!,
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
        if let subtype = Self.string(event["subtype"]), !subtype.isEmpty { return nil }

        let channelType = Self.string(event["channel_type"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let channel = Self.string(event["channel"]) ?? ""
        let isSupportedMessageChannel = eventType == "message"
            && Self.isSupportedConversationChannel(channelId: channel, channelType: channelType)
        guard eventType == "app_mention" || isSupportedMessageChannel else { return nil }
        let isDirectMessage = channelType == "im" || channelType == "app_home" || channel.hasPrefix("D")

        let user = Self.string(event["user"]) ?? ""
        guard !user.isEmpty else { return nil }
        if let botUserId = config.botUserId, user == botUserId { return nil }

        // 2026-07-21 audit fix: transport allowlist gate. Previously ANY
        // workspace member in ANY channel the bot sat in got a chat turn.
        // When the allowlist is configured, only allowlisted channels/users
        // may drive turns (mirrors the Telegram transport gate).
        if !config.allowedChannelIds.isEmpty || !config.allowedUserIds.isEmpty {
            guard config.allowedChannelIds.contains(channel) || config.allowedUserIds.contains(user) else {
                return nil
            }
        }

        let rawText = Self.string(event["text"]) ?? ""
        let text = Self.stripBotMention(rawText, botUserId: config.botUserId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

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
            isDirectMessage: isDirectMessage
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

    /// Returns `true` only when the reply actually reached Slack. Callers use
    /// that to decide whether the deduper mark and the history watermark may
    /// stand (LOOPS-2: a `false` here must leave the message retryable).
    @discardableResult
    func handleInbound(_ inbound: SlackInboundMessage) async -> Bool {
        await writeState([
            "lastEventAt": .string(Self.nowString()),
            "lastEventId": .string(inbound.eventId),
            "lastChannelId": .string(inbound.channelId),
        ])
        do {
            let chatReply = try await chatHandler(inbound)
            let reply = chatReply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let imageAttachments = Self.uploadableImageAttachments(chatReply.attachments)
            guard !reply.isEmpty || !imageAttachments.isEmpty else {
                await recordError(context: "empty_reply", error: SlackSocketModeError.api("chat returned empty reply"), inbound: inbound)
                return false
            }
            var postedAny = false
            if !reply.isEmpty {
                var input: [String: JSONValue] = [
                    "channel": .string(inbound.channelId),
                    "text": .string(reply),
                ]
                if let threadTs = inbound.replyThreadTs, !threadTs.isEmpty {
                    input["thread_ts"] = .string(threadTs)
                }
                do {
                    let posted = try await outbound.postMessage(input)
                    if Self.envelopeOK(posted) {
                        postedAny = true
                    } else {
                        await recordError(context: "post_reply", error: SlackSocketModeError.api(String(describing: posted)), inbound: inbound)
                    }
                } catch {
                    await recordError(context: "post_reply", error: error, inbound: inbound)
                }
            }
            for attachment in imageAttachments {
                do {
                    var input = Self.uploadInput(for: attachment, inbound: inbound)
                    if reply.isEmpty {
                        input["initial_comment"] = .string(attachment.name ?? "Generated image")
                    }
                    let uploaded = try await outbound.uploadFile(input)
                    if Self.envelopeOK(uploaded) {
                        postedAny = true
                    } else {
                        await recordError(context: "upload_reply_image", error: SlackSocketModeError.api(String(describing: uploaded)), inbound: inbound)
                    }
                } catch {
                    await recordError(context: "upload_reply_image", error: error, inbound: inbound)
                }
            }
            if postedAny {
                await recordReceipt(kind: "reply", inbound: inbound, reply: reply.isEmpty ? "[image]" : reply)
                return true
            }
            await recordError(context: "post_reply", error: SlackSocketModeError.api("no Slack reply artifact posted"), inbound: inbound)
            return false
        } catch {
            await recordError(context: "chat_handler", error: error, inbound: inbound)
            let notice = "(internal error while drafting a Slack reply)"
            var input: [String: JSONValue] = [
                "channel": .string(inbound.channelId),
                "text": .string(notice),
            ]
            if let threadTs = inbound.replyThreadTs, !threadTs.isEmpty {
                input["thread_ts"] = .string(threadTs)
            }
            _ = try? await outbound.postMessage(input)
            return false
        }
    }

    private static func uploadableImageAttachments(
        _ attachments: [ChatOrchestration.MultimodalAttachment]
    ) -> [ChatOrchestration.MultimodalAttachment] {
        attachments.filter { attachment in
            attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
                && attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && FileManager.default.fileExists(atPath: attachment.path ?? "")
        }
    }

    private static func uploadInput(
        for attachment: ChatOrchestration.MultimodalAttachment,
        inbound: SlackInboundMessage
    ) -> [String: JSONValue] {
        let path = attachment.path ?? ""
        let fallbackName = URL(fileURLWithPath: path).lastPathComponent
        var input: [String: JSONValue] = [
            "channel": .string(inbound.channelId),
            "file_path": .string(path),
            "filename": .string(attachment.name ?? fallbackName),
            "title": .string(attachment.name ?? fallbackName),
        ]
        if let threadTs = inbound.replyThreadTs, !threadTs.isEmpty {
            input["thread_ts"] = .string(threadTs)
        }
        return input
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
        try? await appendJSONLCapped(
            .object(row),
            to: slackDir.appendingPathComponent("receipts.jsonl"),
            using: SlackSocketModeLoop.persistence,
            maxLines: JSONLLineCaps.slackReceipts,
            logLabel: "SlackSocketModeLoop.receipts"
        )
        await writeState([
            "lastReplyAt": .string(Self.nowString()),
            "lastReplyEventId": .string(inbound.eventId),
            "lastReplyChannelId": .string(inbound.channelId),
            "lastError": .null,
            "lastErrorAt": .null,
        ])
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
        var row: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "at": .string(Self.nowString()),
            "reason": .string(detail.reason),
            "envelopeType": .string(detail.envelopeType),
        ]
        if let value = detail.payloadType { row["payloadType"] = .string(value) }
        if let value = detail.eventType { row["eventType"] = .string(value) }
        if let value = detail.subtype { row["subtype"] = .string(value) }
        if let value = detail.channelType { row["channelType"] = .string(value) }
        if let value = detail.channel { row["channelId"] = .string(value) }
        if let value = detail.user { row["userId"] = .string(value) }
        if let value = detail.textPreview { row["textPreview"] = .string(value) }
        try? await appendJSONLCapped(
            .object(row),
            to: slackDir.appendingPathComponent("ignored.jsonl"),
            using: SlackSocketModeLoop.persistence,
            maxLines: JSONLLineCaps.slackReceipts,
            logLabel: "SlackSocketModeLoop.ignored"
        )
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
        payloadType: String?,
        eventType: String?,
        subtype: String?,
        channelType: String?,
        channel: String?,
        user: String?,
        textPreview: String?
    ) {
        let envelopeType = Self.string(envelope["type"]) ?? "unknown"
        guard envelopeType == "events_api" else {
            return ("unsupported_envelope_type", envelopeType, nil, nil, nil, nil, nil, nil, nil)
        }
        guard let payload = Self.object(envelope["payload"]) else {
            return ("missing_payload", envelopeType, nil, nil, nil, nil, nil, nil, nil)
        }
        let payloadType = Self.string(payload["type"])
        guard payloadType == "event_callback" else {
            return ("unsupported_payload_type", envelopeType, payloadType, nil, nil, nil, nil, nil, nil)
        }
        guard let event = Self.object(payload["event"]) else {
            return ("missing_event", envelopeType, payloadType, nil, nil, nil, nil, nil, nil)
        }
        let eventType = Self.string(event["type"])
        let subtype = Self.string(event["subtype"])
        let channelType = Self.string(event["channel_type"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let channel = Self.string(event["channel"])
        let user = Self.string(event["user"])
        let textPreview = Self.string(event["text"]).map { Self.preview($0) }

        if eventType != "app_mention" && eventType != "message" {
            return ("unsupported_event_type", envelopeType, payloadType, eventType, subtype, channelType, channel, user, textPreview)
        }
        if Self.string(event["bot_id"]) != nil {
            return ("bot_message", envelopeType, payloadType, eventType, subtype, channelType, channel, user, textPreview)
        }
        if let subtype, !subtype.isEmpty {
            return ("message_subtype_\(subtype)", envelopeType, payloadType, eventType, subtype, channelType, channel, user, textPreview)
        }
        if let botUserId = config.botUserId, user == botUserId {
            return ("self_message", envelopeType, payloadType, eventType, subtype, channelType, channel, user, textPreview)
        }
        if eventType == "message" && !Self.isSupportedConversationChannel(channelId: channel ?? "", channelType: channelType) {
            return ("unsupported_message_channel", envelopeType, payloadType, eventType, subtype, channelType, channel, user, textPreview)
        }
        if user?.isEmpty ?? true {
            return ("missing_user", envelopeType, payloadType, eventType, subtype, channelType, channel, user, textPreview)
        }
        let text = Self.stripBotMention(Self.string(event["text"]) ?? "", botUserId: config.botUserId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return ("empty_text", envelopeType, payloadType, eventType, subtype, channelType, channel, user, textPreview)
        }
        let ts = Self.string(event["ts"]) ?? Self.string(event["event_ts"]) ?? ""
        if channel?.isEmpty ?? true || ts.isEmpty {
            return ("missing_channel_or_ts", envelopeType, payloadType, eventType, subtype, channelType, channel, user, textPreview)
        }
        return ("unknown_filtered", envelopeType, payloadType, eventType, subtype, channelType, channel, user, textPreview)
    }

    private func recordError(context: String, error: Error, inbound: SlackInboundMessage? = nil) async {
        let safeError = Self.redact(String(describing: error))
        var row: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "at": .string(Self.nowString()),
            "context": .string(context),
            "error": .string(safeError),
        ]
        if let inbound {
            row["eventId"] = .string(inbound.eventId)
            row["channelId"] = .string(inbound.channelId)
            row["userId"] = .string(inbound.userId)
            row["textPreview"] = .string(Self.preview(inbound.text))
        }
        try? await appendJSONLCapped(
            .object(row),
            to: slackDir.appendingPathComponent("errors.jsonl"),
            using: SlackSocketModeLoop.persistence,
            maxLines: JSONLLineCaps.slackReceipts,
            logLabel: "SlackSocketModeLoop.errors"
        )
        await writeState([
            "lastError": .string("\(context): \(safeError)"),
            "lastErrorAt": .string(Self.nowString()),
        ])
    }

    private func writeState(_ patch: [String: JSONValue]) async {
        let path = slackDir.appendingPathComponent("state.json")
        // 2026-07-21 audit: this ran as an UNLOCKED read-modify-write from
        // per-frame handlers and unstructured handleInbound tasks, so
        // concurrent writers lost each other's keys. Same flock RMW pattern
        // as patchSessionMap below.
        do {
            try await SlackSocketModeLoop.persistence.withFileLock(path) {
                let current = await SlackSocketModeLoop.persistence.readJSON(path, defaultValue: .object([:]))
                var obj: [String: JSONValue]
                if case .object(let currentObj) = current {
                    obj = currentObj
                } else {
                    obj = [:]
                }
                for (key, value) in patch {
                    obj[key] = value
                }
                try await SlackSocketModeLoop.persistence.writeJSON(.object(obj), to: path)
            }
        } catch {
            // Best-effort status mirror — same fail-open posture as before.
        }
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
        guard let regex = try? NSRegularExpression(pattern: #"<@[A-Z0-9]+>"#) else {
            return output
        }
        let range = NSRange(output.startIndex..., in: output)
        return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
    }

    private static func preview(_ text: String, limit: Int = 240) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "..."
    }

    private static func slackTimestampLessThan(_ lhs: String, _ rhs: String) -> Bool {
        (Double(lhs) ?? 0) < (Double(rhs) ?? 0)
    }

    static func nowString(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func redact(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\bxox[baprs]-[A-Za-z0-9-]{20,}|\bxapp-[A-Za-z0-9-]{20,}\b"#) else {
            return raw
        }
        return regex.stringByReplacingMatches(
            in: raw,
            range: NSRange(raw.startIndex..., in: raw),
            withTemplate: "[REDACTED_SLACK_TOKEN]"
        )
    }
}

struct SlackSessionStore: Sendable {
    let dataRoot: URL

    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    func activeSessionId(for inbound: SlackInboundMessage) async throws -> String {
        if let mapped = await mappedSessionId(key: inbound.sessionKey), !mapped.isEmpty {
            try await ensureSessionRow(id: mapped, inbound: inbound)
            return mapped
        }
        // 2026-07-21 audit fix: mint-or-adopt must be ONE locked RMW. The
        // unlocked read above loses to a concurrent first message for the same
        // conversation — both sides saw nil, both minted, and the second patch
        // clobbered the first (orphaning that turn's session context). Re-check
        // inside the flock and adopt any id a concurrent patch already wrote.
        let resolved = try await patchSessionMap(key: inbound.sessionKey) { entry -> String in
            if case .string(let existing)? = entry["activeSessionId"] {
                let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            let minted = UUID().uuidString
            let now = SlackSocketModeLoop.nowString()
            if entry["createdAt"] == nil { entry["createdAt"] = .string(now) }
            entry["activeSessionId"] = .string(minted)
            entry["teamId"] = .string(inbound.teamId)
            entry["channelId"] = .string(inbound.channelId)
            entry["userId"] = .string(inbound.userId)
            entry["updatedAt"] = .string(now)
            return minted
        }
        try await ensureSessionRow(id: resolved, inbound: inbound)
        return resolved
    }

    private func mappedSessionId(key: String) async -> String? {
        guard let entry = await sessionMapEntry(key: key),
              case .string(let id)? = entry["activeSessionId"] else {
            return nil
        }
        return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sessionMapEntry(key: String) async -> [String: JSONValue]? {
        let current = await Self.persistence.readJSON(sessionMapPath, defaultValue: .object([:]))
        guard case .object(let root) = current,
              case .object(let sessions)? = root["sessions"],
              case .object(let entry)? = sessions[key] else {
            return nil
        }
        return entry
    }

    @discardableResult
    private func patchSessionMap<T: Sendable>(
        key: String,
        mutate: @escaping @Sendable (inout [String: JSONValue]) -> T
    ) async throws -> T {
        try await Self.persistence.withFileLock(sessionMapPath) {
            let current = await Self.persistence.readJSON(sessionMapPath, defaultValue: .object([:]))
            var root: [String: JSONValue]
            if case .object(let obj) = current { root = obj } else { root = [:] }
            var sessions: [String: JSONValue]
            if case .object(let obj)? = root["sessions"] { sessions = obj } else { sessions = [:] }
            var entry: [String: JSONValue]
            if case .object(let obj)? = sessions[key] { entry = obj } else { entry = [:] }
            let result = mutate(&entry)
            sessions[key] = .object(entry)
            root["sessions"] = .object(sessions)
            try await Self.persistence.writeJSON(.object(root), to: sessionMapPath)
            return result
        }
    }

    private func ensureSessionRow(id: String, inbound: SlackInboundMessage) async throws {
        let title: String
        if inbound.isDirectMessage {
            title = "Slack DM \(inbound.userId)"
        } else if inbound.normalizedThreadTs != nil {
            title = "Slack Thread \(inbound.channelId)"
        } else if inbound.channelType == "mpim" {
            title = "Slack MPIM \(inbound.channelId)"
        } else {
            title = "Slack \(inbound.channelId)"
        }
        try await Self.ensureSessionRow(
            id: id,
            title: title,
            sourceKey: inbound.sessionKey,
            dataRoot: dataRoot
        )
    }

    static func ensureSessionRow(
        id: String,
        title: String,
        sourceKey: String,
        dataRoot: URL
    ) async throws {
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        try await persistence.withFileLock(sessionsPath) {
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            if rows.contains(where: { row in
                guard case .string(let rowId)? = row["id"] else { return false }
                return rowId == id
            }) {
                return
            }
            let now = SlackSocketModeLoop.nowString()
            let row: [String: JSONValue] = [
                "id": .string(id),
                "title": .string(title),
                "source": .string("slack"),
                "sourceKey": .string(sourceKey),
                "createdAt": .string(now),
                "updatedAt": .string(now),
                "archived": .bool(false),
                "messageCount": .int(0),
            ]
            rows.insert(row, at: 0)
            let out = try ChatSessionIndexFile.serializedData(for: rows)
            try out.write(to: sessionsPath, options: .atomic)
            _ = try? ChatSessionRetention.enforce(dataRoot: dataRoot, now: Date())
        }
    }

    private var sessionMapPath: URL {
        dataRoot
            .appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("session_map.json")
    }

    private var sessionsPath: URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    private static let persistence = SwiftNativePersistenceCore()
}

struct SlackConversationRef: Sendable, Equatable {
    let id: String
    let channelType: String
}

actor SlackConversationCache {
    private var conversations: [SlackConversationRef] = []
    private var loadedAt: Date?

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
        if (Double(ts) ?? 0) >= (Double(current) ?? 0) {
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

    var count: Int { tasks.count }

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
        return abandoned
    }
}

/// Injection seam for the two Slack write calls the loop makes. Production uses
/// `.live`; tests substitute a recorder so no test can post to a real workspace.
struct SlackSocketModeOutbound: Sendable {
    var postMessage: @Sendable (_ input: [String: JSONValue]) async throws -> JSONValue
    var uploadFile: @Sendable (_ input: [String: JSONValue]) async throws -> JSONValue

    static let live = SlackSocketModeOutbound(
        postMessage: { try await SlackConnectorActions.postMessage(input: $0) },
        uploadFile: { try await SlackConnectorActions.uploadFile(input: $0) }
    )
}

enum SlackSocketModeError: Error, CustomStringConvertible {
    case api(String)

    var description: String {
        switch self {
        case .api(let message): return message
        }
    }
}
