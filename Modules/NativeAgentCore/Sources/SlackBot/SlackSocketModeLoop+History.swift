import Foundation
import PersistenceCore
import NativeAgentShared
import BackgroundLoops
// Blueprint: | `SlackSocketModeLoop+History.swift` | `SlackSocketModeLoop`: conversation discovery, bounded history paging and socket-health polling deadlines; reconnect gap fill and the missed-event backstop retain their intervals |

extension SlackSocketModeLoop {
    /// A healthy socket still needs a backstop for silently missed events.
    var historySafetyPollInterval: TimeInterval {
        max(config.historyPollInterval * 10, 900)
    }

    func historyPollUntilCancelled() async {
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
        // Each socket session starts with gap fill; socket health gates later polls.
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
                try Task.checkCancellation()
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

    /// Reconnects fill gaps; unhealthy sockets poll regularly; healthy ones keep a backstop.
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

    /// Next poll deadline; socket-session cancellation wakes the wait on failure.
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

    func pollSlackHistoryOnce() async throws {
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
            await recordError(context: "conversation_discovery", error: error)
            await writeState(["conversationDiscoveryUsingLastGood": .bool(false)])
            throw error
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
            guard response["ok"]?.boolValue == true else {
                throw SlackSocketModeError.api(response["error"]?.stringValue ?? "conversations.list failed")
            }
            guard case .array(let channels)? = response["channels"] else {
                throw SlackSocketModeError.api("conversations.list returned malformed channels; discovery incomplete")
            }
            let page: [SlackConversationRef] = try channels.compactMap { raw in
                guard case .object(let obj) = raw,
                      let id = obj["id"]?.stringValue,
                      !id.isEmpty else {
                    throw SlackSocketModeError.api("conversations.list returned malformed channel entry; discovery incomplete")
                }
                let isIM = obj["is_im"]?.boolValue == true
                let isMPIM = obj["is_mpim"]?.boolValue == true
                let isMember = obj["is_member"]?.boolValue == true
                guard isIM || isMPIM || isMember else { return nil }
                let channelType: String
                if isIM {
                    channelType = "im"
                } else if isMPIM {
                    channelType = "mpim"
                } else if obj["is_private"]?.boolValue == true {
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
            guard response["ok"]?.boolValue == true else {
                throw SlackSocketModeError.api(response["error"]?.stringValue ?? "conversations.history failed")
            }
            guard case .array(let rawMessages)? = response["messages"] else {
                throw SlackSocketModeError.api("conversations.history returned malformed messages; history incomplete")
            }
            let page: [[String: JSONValue]] = try rawMessages.map { raw in
                guard case .object(let message) = raw,
                      let ts = message["ts"]?.stringValue,
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
                let ts = (message["ts"]?.stringValue)!
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
                guard let boundary = page.compactMap({ $0["ts"]?.stringValue })
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
            .compactMap({ $0["ts"]?.stringValue })
            .max(by: { Self.slackTimestampLessThan($0, $1) }) else {
            return
        }
        let seeded = await historyPollState.seedIfNeeded(channelId: conversation.id, newestTs: newest)
        if seeded { return }

        let ordered = messages.sorted {
            Self.slackTimestampLessThan(
                $0["ts"]?.stringValue ?? "0",
                $1["ts"]?.stringValue ?? "0"
            )
        }
        // Collection advances after durable admission. The journal's retained
        // handlers own model/delivery settlement independently of this cursor.
        var watermark: String?
        for message in ordered {
            if Task.isCancelled { throw CancellationError() }
            guard let inbound = inboundMessage(
                message, channel: conversation.id, channelType: conversation.channelType,
                eventType: "message", teamId: config.teamId ?? "slack", ts: message["ts"]?.stringValue ?? "",
                isDirectMessage: conversation.channelType == "im" || conversation.id.hasPrefix("D")
            ).message else {
                // Nothing to deliver (bot / subtype / empty) — safe to skip past.
                if let ts = message["ts"]?.stringValue { watermark = Self.laterTs(watermark, ts) }
                continue
            }
            await writeState([
                "lastHistoryPollMessageAt": .string(Self.nowString()),
                "lastHistoryPollChannelId": .string(conversation.id),
                "lastHistoryPollMessageTs": .string(inbound.ts),
            ])
            try Task.checkCancellation()
            let claim = try await deliveryJournal.claim(inbound)
            if claim != .alreadyDelivered {
                await spawnInboundHandling(inbound)
            }
            watermark = Self.laterTs(watermark, inbound.ts)
        }
        watermark = Self.laterTs(watermark, newest)
        if let watermark {
            await historyPollState.markSeen(channelId: conversation.id, ts: watermark)
        }
    }

    private static func laterTs(_ lhs: String?, _ rhs: String) -> String {
        guard let lhs else { return rhs }
        return slackTimestampLessThan(lhs, rhs) ? rhs : lhs
    }

    func slackAPI(
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
        let parsed = try await SlackWebAPI.response(for: req, session: session)
        guard parsed["error"] as? String != "non_json_response",
              case .object(let obj) = JSONValue(fromFoundation: parsed) else {
            throw SlackSocketModeError.api("\(method) returned non-object JSON")
        }
        if let status = parsed["httpStatus"] as? Int {
            throw SlackSocketModeError.api("\(method) HTTP \(status)")
        }
        return obj
    }

    private static func slackTimestampLessThan(_ lhs: String, _ rhs: String) -> Bool {
        (Decimal(string: lhs, locale: Locale(identifier: "en_US_POSIX")) ?? 0)
            < (Decimal(string: rhs, locale: Locale(identifier: "en_US_POSIX")) ?? 0)
    }
}
