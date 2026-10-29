import Foundation
import NativeAgentShared
import BackgroundLoops
import PersistenceCore
import os
// Blueprint: | `SlackSocketModeLoop.swift` | `SlackSocketModeLoop` state, `tick`, `tickOutcome`, socket lifetime and ingress; session cancellation closes pending receives and drains passive work while journal-owned accepted handlers continue |

enum SlackSocketSessionClosure: Error, Sendable, Equatable {
    case disconnect(reason: String)
}

public struct SlackSocketModeLoop: LoopRunner {
    @TaskLocal static var deferAfterHandling: (@Sendable (@escaping @Sendable () async -> Void) async -> Void)?

    public let loopId = "slack_socket_mode"
    public let interval: TimeInterval
    public var tickTimeoutOverride: TimeInterval? { 3_900 }

    // Recycle healthy socket sessions before the tick watchdog's hang deadline.
    let sessionRecycleInterval: TimeInterval = 3_600

    let config: SlackSocketModeConfig
    let dataRoot: URL
    let progressChatHandler: SlackProgressChat?
    let botEventIntake: SlackBotEventIntake
    let session: URLSession
    let deliveryJournal: SlackInboundDeliveryJournal
    let historyPollState = SlackHistoryPollState()
    let conversationCache = SlackConversationCache()
    // Socket liveness gates history polling.
    let socketHealth = SlackSocketHealth()
    let feedRetention = JSONLPathOwnedCapPolicy(
        maxLines: JSONLLineCaps.slackReceipts, maxBytes: 1_048_576, trimToBytes: 786_432
    )

    /// A socket that has said `hello` and has produced a frame or a successful
    /// ping inside this window counts as healthy. Pings run every 25s, so 90s
    /// is three missed heartbeats.
    static let socketHealthGrace: TimeInterval = 90
    static let shortLivedSessionFloor: TimeInterval = 30
    /// How long a socket-mode ping may wait for its pong before the wait is
    /// abandoned. Well inside the 25 s ping interval, so a dead socket is
    /// declared dead on the tick that found it rather than at the next one.
    static let pingResponseDeadline: TimeInterval = 10

    /// Reconnect spacing for sessions that end without failure backoff.
    static let defaultReconnectInterval: TimeInterval = 15

    init(
        config: SlackSocketModeConfig,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        interval: TimeInterval = SlackSocketModeLoop.defaultReconnectInterval,
        session: URLSession = .shared,
        botEventIntake: @escaping SlackBotEventIntake,
        progressChatHandler: SlackProgressChat? = nil
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
        // Recovery only hands each saved accepted message its own lifetime,
        // as a new one gets; the socket session never waits on or cancels it.
        do { try await reconcileSavedReplies() }
        catch { await recordError(context: "inbound_recovery", error: error) }
        guard !Task.isCancelled else { return .skipped(reason: "Slack socket mode canceled") }
        return await socketTickOutcome()
    }

    private func socketTickOutcome() async -> LoopTickOutcome {
        let sessionStartedAt = Date()
        do {
            await writeState([
                "connected": .bool(false),
                "connectingAt": .string(Self.nowString()),
                "lastError": .null,
            ])
            try Task.checkCancellation()
            let socketURL = try await openSocketURL()
            try Task.checkCancellation()
            await writeState([
                "socketUrlOpenedAt": .string(Self.nowString()),
            ])
            try Task.checkCancellation()
            let socket = session.webSocketTask(with: socketURL)
            socket.resume()
            // Mark planned closes so receive errors remain successful recycling.
            let recycleFlag = OSAllocatedUnfairLock(initialState: false)
            let recycleTask = Task { [sessionRecycleInterval] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, sessionRecycleInterval) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                recycleFlag.withLock { $0 = true }
                socket.cancel(with: .goingAway, reason: nil)
            }
            defer { recycleTask.cancel() }
            var endingError: Error?
            do {
                try await receiveLoop(socket: socket)
            } catch { endingError = error }
            socket.cancel(with: .goingAway, reason: nil)
            if endingError is CancellationError { throw CancellationError() }
            try Task.checkCancellation()
            let outcome = Self.classifySessionClosure(
                endingError,
                sessionDuration: max(0, Date().timeIntervalSince(sessionStartedAt)),
                recyclePlanned: recycleFlag.withLock { $0 },
                recycleInterval: sessionRecycleInterval
            )
            switch outcome {
            case .completed:
                let reason = (endingError as? SlackSocketSessionClosure).map(Self.closeReason)
                    ?? (endingError == nil ? "receive_loop_returned" : "session_recycled")
                await writeState([
                    "connected": .bool(false),
                    "receiveLoopEndedAt": .string(Self.nowString()),
                    "lastCloseReason": .string(reason),
                ])
                return outcome
            case .failed(let error):
                if let endingError, !(endingError is SlackSocketSessionClosure) { throw endingError }
                throw SlackSocketModeError.api(error)
            case .skipped:
                return outcome
            }
        } catch let error where error is CancellationError || Task.isCancelled {
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
            // Poll history when opening fails; retain the socket failure outcome.
            if config.historyPollEnabled, config.ingressPolicy.isConfigured {
                do {
                    try await pollSlackHistoryOnce()
                    await writeState([
                        "lastHistoryPollAt": .string(Self.nowString()),
                        "lastHistoryPollTrigger": .string("socket_open_failed"),
                        "lastHistoryPollError": .null,
                    ])
                } catch let error where error is CancellationError || Task.isCancelled {
                    // Stopping a history poll records cancellation without a loop failure.
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
        let parsed = try await SlackWebAPI.response(for: req, session: session)
        if let status = parsed["httpStatus"] as? Int { throw SlackSocketModeError.api("apps.connections.open HTTP \(status)") }
        guard parsed["error"] as? String != "non_json_response",
              case .object(let obj) = JSONValue(fromFoundation: parsed) else {
            throw SlackSocketModeError.api("apps.connections.open returned non-object JSON")
        }
        guard obj["ok"]?.boolValue == true else {
            throw SlackSocketModeError.api(obj["error"]?.stringValue ?? "apps.connections.open failed")
        }
        guard let urlString = obj["url"]?.stringValue,
              let url = URL(string: urlString) else {
            throw SlackSocketModeError.api("apps.connections.open did not return a WebSocket URL")
        }
        return url
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async throws {
        try Task.checkCancellation()
        let pingTask = Task {
            await pingUntilCancelled(socket: socket)
        }
        let historyPollTask = Task {
            await historyPollUntilCancelled()
        }
        // Every exit path drains the session's own children (ping, history);
        // accepted turns are not the session's and keep running.
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await receiveLoopBody(socket: socket)
            } onCancel: {
                // Cancelling the Swift task must also wake a parked receive.
                pingTask.cancel()
                historyPollTask.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            await drainSessionWork(pingTask: pingTask, historyPollTask: historyPollTask)
            throw error
        }
        await drainSessionWork(pingTask: pingTask, historyPollTask: historyPollTask)
    }

    private func drainSessionWork(pingTask: Task<Void, Never>, historyPollTask: Task<Void, Never>) async {
        pingTask.cancel()
        historyPollTask.cancel()
        await historyPollTask.value
        await pingTask.value
        await socketHealth.markDisconnected()
    }

    private func receiveLoopBody(socket: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            try Task.checkCancellation()
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
            let type = obj["type"]?.stringValue ?? ""
            // Any received frame proves the socket is alive.
            await socketHealth.markAlive()
            await writeState([
                "lastWebSocketMessageAt": .string(Self.nowString()),
                "lastWebSocketMessageType": .string(type.isEmpty ? "unknown" : type),
            ])
            try Task.checkCancellation()
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
                let reason = obj["reason"]?.stringValue ?? "disconnect"
                await writeState([
                    "connected": .bool(false),
                    "disconnectedAt": .string(Self.nowString()),
                    "disconnectReason": .string(reason),
                ])
                throw SlackSocketSessionClosure.disconnect(reason: reason)
            default:
                let envelopeId = obj["envelope_id"]?.stringValue
                await recordEnvelope(envelope: obj, envelopeId: envelopeId)
                try Task.checkCancellation()
                let parsed = inboundMessage(fromEnvelope: obj)
                guard let inbound = parsed.message else {
                    if let envelopeId {
                        try await acknowledge(envelopeId: envelopeId, socket: socket)
                    }
                    await recordIgnoredEnvelope(parsed.detail)
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

    func claimInboundBeforeAcknowledging(
        _ inbound: SlackInboundMessage,
        acknowledge: @Sendable () async throws -> Void
    ) async throws -> SlackInboundClaimOutcome {
        try Task.checkCancellation()
        let claim = try await deliveryJournal.claim(inbound)
        try await acknowledge()
        return claim
    }

    private func pingUntilCancelled(socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 25_000_000_000)
                try await sendPing(socket: socket)
                try Task.checkCancellation()
                await socketHealth.markAlive()
                try Task.checkCancellation()
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

    /// Pong, cancellation and deadline race to settle the first outcome.
    private func sendPing(socket: URLSessionWebSocketTask) async throws {
        let gate = ContinuationOnce<Result<Void, Error>>()
        let deadline = Task {
            try? await Task.sleep(for: .seconds(Self.pingResponseDeadline))
            guard !Task.isCancelled else { return }
            gate.resume(.failure(SlackSocketModeError.api(
                "Slack did not answer a socket-mode ping within \(Int(Self.pingResponseDeadline))s"
            )))
        }
        defer { deadline.cancel() }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
                gate.install(continuation)
                socket.sendPing { error in
                    if let error {
                        gate.resume(.failure(error))
                    } else {
                        gate.resume(.success(()))
                    }
                }
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
        }
        try result.get()
    }

    static func apiURL(_ method: String) -> URL {
        SlackWebAPI.apiURL(method)
    }

    private func acknowledge(envelopeId: String, socket: URLSessionWebSocketTask) async throws {
        let payload = try JSONValue.object([
            "envelope_id": .string(envelopeId),
        ]).serialize(pretty: false)
        try await socket.send(.string(payload))
    }

    private func inboundMessage(fromEnvelope envelope: [String: JSONValue]) -> (
        message: SlackInboundMessage?,
        detail: (reason: String, envelopeType: String, eventType: String?, channelType: String?, channel: String?)
    ) {
        let envelopeType = envelope["type"]?.stringValue ?? "unknown"
        guard envelopeType == "events_api" else {
            return (nil, ("unsupported_envelope_type", envelopeType, nil, nil, nil))
        }
        guard let payload = envelope["payload"]?.objectValue else {
            return (nil, ("missing_payload", envelopeType, nil, nil, nil))
        }
        guard payload["type"]?.stringValue == "event_callback" else {
            return (nil, ("unsupported_payload_type", envelopeType, nil, nil, nil))
        }
        guard let event = payload["event"]?.objectValue else {
            return (nil, ("missing_event", envelopeType, nil, nil, nil))
        }
        let channelType = event["channel_type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let channel = event["channel"]?.stringValue ?? ""
        let reject = { (reason: String) in
            (nil as SlackInboundMessage?, (reason, envelopeType, event["type"]?.stringValue, channelType, event["channel"]?.stringValue))
        }
        let eventType = event["type"]?.stringValue ?? ""
        guard eventType == "app_mention" || eventType == "message" else { return reject("unsupported_event_type") }
        let isSupportedMessageChannel = eventType == "message"
            && Self.isSupportedConversationChannel(channelId: channel, channelType: channelType)
        let teamId = payload["team_id"]?.stringValue ?? config.teamId ?? "slack"
        let ts = event["ts"]?.stringValue ?? event["event_ts"]?.stringValue ?? ""
        let parsed = inboundMessage(event, channel: channel, channelType: channelType,
            eventType: eventType, teamId: teamId, ts: ts,
            isDirectMessage: channelType == "im" || channelType == "app_home" || channel.hasPrefix("D"),
            channelRejection: eventType == "app_mention" || isSupportedMessageChannel ? nil : "unsupported_message_channel")
        return (parsed.message, (parsed.reason, envelopeType, event["type"]?.stringValue, channelType, event["channel"]?.stringValue))
    }

    func inboundMessage(
        _ event: [String: JSONValue], channel: String, channelType: String?,
        eventType: String, teamId: String, ts: String, isDirectMessage: Bool, channelRejection: String? = nil
    ) -> (message: SlackInboundMessage?, reason: String) {
        let reject = { (reason: String) in (nil as SlackInboundMessage?, reason) }
        if event["bot_id"]?.stringValue != nil { return reject("bot_message") }
        if let subtype = event["subtype"]?.stringValue,
           !subtype.isEmpty, subtype != "file_share" { return reject("message_subtype_\(subtype)") }
        if let channelRejection { return reject(channelRejection) }
        let user = event["user"]?.stringValue ?? ""
        guard !user.isEmpty else { return reject("missing_user") }
        if let botUserId = config.botUserId, user == botUserId { return reject("self_message") }

        let rawText = event["text"]?.stringValue ?? ""
        if let denial = config.ingressPolicy.denial(
            channelId: channel,
            userId: user,
            eventType: eventType,
            channelType: channelType,
            rawText: rawText
        ) {
            return reject(denial.rawValue)
        }
        let text = Self.stripBotMention(rawText, botUserId: config.botUserId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let files = Self.inboundFiles(event["files"])
        guard !text.isEmpty || !files.isEmpty else { return reject("empty_text") }

        guard !channel.isEmpty, !ts.isEmpty else { return reject("missing_channel_or_ts") }

        let eventId = "\(teamId):\(channel):\(ts)"
        return (SlackInboundMessage(
            eventId: eventId,
            teamId: teamId,
            channelId: channel,
            userId: user,
            eventType: eventType,
            text: text,
            ts: ts,
            threadTs: event["thread_ts"]?.stringValue,
            channelType: channelType,
            isDirectMessage: isDirectMessage,
            files: files
        ), "")
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

    private static func stripBotMention(_ text: String, botUserId: String?) -> String {
        var output = text
        if let botUserId, !botUserId.isEmpty {
            output = output.replacingOccurrences(of: "<@\(botUserId)>", with: "")
        }
        return output
    }

}
