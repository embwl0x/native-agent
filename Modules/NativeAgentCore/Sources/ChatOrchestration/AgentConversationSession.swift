import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots

/// Conversational operation over existing gated adapters. No protocol or
/// permission is implemented here; every actual send/read enters its owner.
enum AgentConversationSession {
    typealias Dispatch = @Sendable (String, [String: JSONValue]) async throws -> JSONValue

    static func dispatch(tool: String, input: [String: JSONValue], surface: String,
                         scope: String, dataRoot: URL, perform: Dispatch) async throws -> JSONValue {
        var args = input.filter { $0.value != .null }
        let label = string(args.removeValue(forKey: "conversation"))
        let historyBefore = string(args.removeValue(forKey: "history_before"))
        let historyExchange = string(args.removeValue(forKey: "history_exchange"))
        if historyBefore != nil || historyExchange != nil {
            guard tool == "agent_read", args["details"] != .bool(true), !agentIsBot(args),
                  historyBefore == nil || historyExchange == nil,
                  [historyBefore, historyExchange].compactMap({ $0 }).allSatisfy({ UUID(uuidString: $0) != nil }) else {
                throw AgentConversationStore.Failure(message: "Choose one offered session-history page or exchange. This only reads retained messages.")
            }
        }
        let freshValue = args.removeValue(forKey: "new_conversation")
        if let freshValue, case .bool = freshValue {} else if freshValue != nil {
            throw AgentConversationStore.Failure(message: "new_conversation must be true or false.")
        }
        let fresh = freshValue == .bool(true)
        guard var agent = string(args["agent"]) else { return try await perform(tool, args) }
        // A2A task-listing filters mean nothing to any other contact; history_length
        // on Grok Bot is "show me the recent talk", so it opens the conversation.
        let listing: Set<String> = ["page_size", "page_token", "context_id", "status", "history_length", "include_artifacts", "status_timestamp_after"]
        if args.keys.contains(where: listing.contains),
           (try? AgentPeerStore(dataRoot: dataRoot).list())?.first(where: { "peer:" + $0.id == agent })?.transport != .a2a {
            args = args.filter { !listing.contains($0.key) }
        }
        // limit/offset page nothing on a contact's route without an exact
        // message or task; they mean "show me the recent talk" (Grok Bot, 09-24).
        if agent.hasPrefix("peer:"), string(args["message_id"]) == nil, string(args["task_id"]) == nil {
            args.removeValue(forKey: "limit"); args.removeValue(forKey: "offset")
        }
        // Exact protocol calls remain available for diagnostics and existing clients.
        let advanced: Set<String> = ["conversation_id", "message_id", "task_id", "page_size", "page_token", "context_id", "status", "history_length", "include_artifacts", "status_timestamp_after", "limit", "offset"]
        if args.contains(where: { advanced.contains($0.key) && $0.value != .string("") }) {
            guard label == nil, !fresh, historyBefore == nil, historyExchange == nil else { throw AgentConversationStore.Failure(message: "Choose either a conversation name or exact protocol identifiers, not both.") }
            return try await perform(tool, args)
        }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        var peer = peers.first { "peer:" + $0.id == agent }
        // 2026-09-23: a contact removed and connected again gets a new id; its
        // older records and windows keep the old one under the same name. A READ
        // follows the one saved contact with that name. A send never routes by
        // name (another contact could share it): it is refused, naming the id.
        if agent.hasPrefix("peer:"), peer == nil,
           let name = (try? store.records())?.first(where: { $0.agent == agent })?.name {
            let same = peers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if same.count == 1, tool != "agent_read" {
                throw AgentConversationStore.Failure(message: "That contact's id changed; the current \(same[0].name) is peer:\(same[0].id); send to that.")
            }
            if same.count == 1 { peer = same[0]; agent = "peer:" + same[0].id; args["agent"] = .string(agent) }
        }
        if agent.hasPrefix("peer:"), peer == nil { throw AgentConversationStore.Failure(message: "This contact is no longer connected.") }
        let botName = try BotDefinitionStore(dataRoot: dataRoot).list().first {
            "bot:" + $0.id.uuidString.lowercased() == agent.lowercased()
        }?.name
        let name = peer?.name ?? botName ?? agent.capitalized
        let fingerprint = peer.map(AgentConversationStore.routeFingerprint)
        if fresh, agent.hasPrefix("bot:") || peer?.transport == .desktop || peer?.transport == .grokBot {
            return attention(name, label: label ?? "Main", "This contact owns one persistent conversation through its saved route. Continue that conversation; a separate thread is not supported by this adapter.")
        }
        if agent.hasPrefix("bot:"), let label, label != "Main" {
            return attention(name, label: label, "This helper has one continuous conversation. Omit the conversation label to continue it; a different label cannot create an independent discussion for this bot.")
        }
        var previous = try store.find(scopeSessionID: scope, agent: agent, label: label)
        if let row = previous, !AgentConversationStore.sameRoute(row.peerRouteFingerprint, peer) {
            guard tool == "agent_message", fresh else {
                return attention(name, label: row.label, "The contact's connection changed. Start a separate conversation explicitly; this conversation has been preserved.")
            }
        }
        if tool == "agent_read" {
            guard !fresh else { throw AgentConversationStore.Failure(message: "Start a new conversation by sending its first message.") }
            if agent.hasPrefix("bot:") {
                // Bots already own a durable conversation and shelf, even if
                // this Agent chat has never opened it. Always read the owner's
                // latest actual reply; exact message-ID reads still bypass
                // this facade above. Do not substitute an older cached ask.
                return try await perform(tool, args)
            }
            if ["codex", "claude", "omp"].contains(agent) {
                // The built-in lanes keep their own thread; the window shows
                // its recent exchanges, not one chat's retained receipt.
                if args["limit"] == nil, args["message_id"] == nil { args["limit"] = .int(6) }
                return try await perform(tool, args)
            }
            if peer?.transport == .grokBot, args["details"] != .bool(true), historyBefore == nil, historyExchange == nil {
                return try await routineRead(agent: agent, name: name, peer: peer, row: previous, store: store, args: args,
                                             dataRoot: dataRoot, perform: perform)
            }
            guard let row = previous else {
                return .object(["agent": .string(agent), "with": .string(name), "state": .string("not_opened"),
                    "detail": .string("No saved conversation in this chat. Send your first message to start one.")])
            }
            let refreshed = try await refresh(row, store: store, input: args, perform: perform)
            return view(refreshed, details: args["details"] == .bool(true), dataRoot: dataRoot,
                        historyBefore: historyBefore, historyExchange: historyExchange)
        }
        guard tool == "agent_message" else { return try await perform(tool, args) }
        // The existing callback owns built-in completion. Recover its exact
        // receipt when continuing, including the executor's eventual thread ID.
        if let row = previous, row.phase == "waiting", !fresh, !row.automaticRead, row.readInput != nil {
            previous = try await refresh(row, store: store, input: args, perform: perform)
        }
        // 2026-09-24 WHY: Grok Bot's accepted ask stays "waiting" until it answers
        // or its 10-minute window ends, so one unanswered ask held her next message
        // that long. After a short wait a new message supersedes it; a late answer
        // to the earlier one still arrives as its own turn in the chat that asked.
        var supersededAfter: TimeInterval?
        var handOffSettled = false
        if let row = previous, !fresh {
            if row.phase == "waiting", liveHandOff(row) {
                // Handed into the agent's live session: held until it answers in a
                // chat of its own or 30 minutes pass, so a resend doesn't duplicate work.
                guard settled(row, dataRoot: dataRoot) else {
                    return attention(name, label: row.label, "Your last message is in \(name)'s live session; the answer comes as a chat of its own. A new message can go once \(name) answers or 30 minutes pass; nothing was sent.")
                }
                handOffSettled = true
            } else if row.phase == "waiting", peer?.transport == .grokBot {
                let waited = max(0, Date().timeIntervalSince(row.operationStartedAt ?? row.updatedAt))
                guard waited >= 120 else {
                    return attention(name, label: row.label, "\(name) has not answered your last message yet (sent \(Int(waited)) seconds ago). Its answer arrives by itself as a turn in the chat that asked. A new message can go after two minutes; nothing was sent.")
                }
                supersededAfter = waited
            } else if ["sending", "waiting"].contains(row.phase) {
                return attention(name, label: row.label, "The previous message has not settled. NativeAgent is preserving its state; open this conversation to see its available reply. No new message was sent.")
            }
            // 2026-09-22 WHY: ACP and Muse reads return nothing_to_read, so one
            // timeout or approval card locked the thread for good. With a known
            // conversation id an explicit next message just continues it.
            // Grok can't start fresh, so an unanswered or unknown send must not strand it.
            // Nor can a desktop contact (one saved conversation): one unverified
            // typed send held the Grok app's thread for days (desk walk 09-24).
            if row.phase == "attention", !resumable(row, peer?.transport, dataRoot: dataRoot), !settledBotTurn(row), !confirmedNotSent(row) {
                return attention(name, label: row.label, "This conversation needs attention. Open it to see the retained result; no message was repeated.")
            }
            if row.conversationID == nil, row.receipt != nil, !confirmedNotSent(row),
               !agent.hasPrefix("bot:"), peer?.transport != .desktop, peer?.transport != .grokBot {
                return attention(name, label: row.label, "This contact did not confirm a resumable conversation. Start a separate conversation explicitly rather than silently losing its context.")
            }
        }
        let replyRoute = ChatToolSessionContext.replyRoute.map { route in
            ["surface": route.surface, "destinationId": route.destinationId,
             "threadId": route.threadId, "sourceKey": route.sourceKey,
             "replyTo": route.replyTo, "correlationId": route.correlationId].compactMapValues { $0 }
        }
        let row = try store.begin(scopeSessionID: scope, agent: agent, name: name, label: label,
                                  fresh: fresh, sourceSurface: surface, fingerprint: fingerprint, replyRoute: replyRoute,
                                  message: string(args["text"]),
                                  legacyFingerprint: peer.map(AgentConversationStore.legacyRouteFingerprint),
                                  personInitiated: PersonInitiatedSend.current?.matches(args) == true,
                                  supersedeWaiting: supersededAfter != nil || handOffSettled)
        // Grok's conversation is always the asking chat; a saved id from another chat is refused.
        if let conversation = row.conversationID, peer?.transport != .grokBot { args["conversation_id"] = .string(conversation) }
        if case .object(let receipt)? = row.receipt, receipt["needs_input"] == .bool(true),
           let task = receipt["task_id"] { args["task_id"] = task }
        do {
            let receipt = try await perform(tool, args)
            let saved = try record(receipt, for: row, store: store, peer: peer)
            let result = view(saved, details: false, dataRoot: dataRoot)
            guard let supersededAfter, case .object(var fields) = result else { return result }
            fields["earlier_message"] = .string("Your earlier message (sent \(Int(supersededAfter / 60)) min ago) was never answered. If \(name) answers it later, that answer still arrives in the chat that asked.")
            return .object(fields)
        } catch {
            // An exception may occur after dispatch. Keep the exact previous
            // binding and mark uncertainty; never synthesize a replacement send.
            _ = try? store.update(id: row.id, operationID: row.operationID) {
                $0.phase = "attention"
                $0.receipt = .object(["status": .string("outcome_unknown"),
                    "detail": .string("The send did not establish an outcome. The conversation was preserved; no message was resent.")])
            }
            throw error
        }
    }

    /// A routine (Grok Bot) answers as its own turn in the chat that asked,
    /// never in the send record. Its read carries both sides in time order:
    /// her asks from the record (any chat), its replies from those chats
    /// (HerScreen.routineReplies, matched by the request's run id).
    private static func routineRead(agent: String, name: String, peer: AgentPeerContact?, row: AgentConversationRecord?,
                                    store: AgentConversationStore, args: [String: JSONValue], dataRoot: URL,
                                    perform: Dispatch) async throws -> JSONValue {
        var result: JSONValue = .object(["agent": .string(agent), "with": .string(name), "state": .string("not_opened")])
        // A send that failed left no request id; Grok's read takes only one, so
        // refreshing would fail the whole read ("missing message_id").
        if let row { result = view(row.readInput == nil ? row : try await refresh(row, store: store, input: args, perform: perform), details: false, dataRoot: dataRoot) }
        let asks = ((try? store.records()) ?? []).filter { record in
            record.agent == agent || (record.agent.hasPrefix("peer:") && record.name.caseInsensitiveCompare(name) == .orderedSame)
        }.flatMap { record in (record.exchanges ?? []).compactMap { exchange in exchange.prompt.map { (exchange.sentAt as Date?, exchange.byPerson == true ? "the person" : "you", $0) } } }
        let replies = await HerScreen.routineReplies(dataRoot: dataRoot).map { ($0.at, name, $0.text) }
        let talk = (asks + replies).sorted { ($0.0 ?? .distantPast) < ($1.0 ?? .distantPast) }.suffix(8)
        guard case .object(var fields) = result, !talk.isEmpty else { return result }
        if !replies.isEmpty {
            // Its words are remote data: consumed now, unless its owner is trusted.
            if peer?.elevationAllowed != true { PeerDataTaint.markConsumed(peer: agent) }
            // The current ask's own state comes from its request id (refreshed
            // above). A late answer to a superseded ask shows here but never
            // reads as the answer to the one still waiting.
            if !["waiting", "sending"].contains(fields["state"].flatMap { if case .string(let v) = $0 { v } else { nil } } ?? "") {
                fields["state"] = .string("replied")
            }
            fields["untrusted_remote_data"] = .bool(true)
        }
        fields["conversation"] = .array(talk.map { at, from, text in
            .object(["at": at.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null, "from": .string(from),
                     "text": .string(HerScreen.clip(text, 800))])
        })
        fields["conversation_note"] = .string("Oldest first. Its replies arrive as their own turns in the chat that asked; these are them.")
        return .object(fields)
    }

    private static func refresh(_ row: AgentConversationRecord, store: AgentConversationStore,
                                input: [String: JSONValue], perform: Dispatch) async throws -> AgentConversationRecord {
        var read = row.readInput ?? ["agent": .string(row.agent)]
        read["details"] = .bool(true)
        for key in ["session_id", "__session_id"] { read[key] = input[key] }
        let receipt = try await perform("agent_read", read)
        // Synchronous command/ACP adapters do not expose a recovery endpoint.
        // Their gate still ran; show the clearly labelled retained last result.
        // A desktop contact's read is send-only ("read": false, "sent": false):
        // not an access refusal, just nothing to read there.
        if case .object(let value) = receipt, value["status"] == .string("nothing_to_read")
            || (value["operation"] == .string("read") && value["read"] == .bool(false) && value["error"] == nil) {
            return try store.update(id: row.id, operationID: row.operationID, touch: false) { $0.selected = true }
        }
        // A read that did not reach its owner cannot expose a cached reply.
        if isRefusal(receipt) { throw AgentConversationStore.Failure(message: "This conversation cannot be opened with the current access settings.") }
        // Without an exact locator this read was admission-only. An unscoped
        // recent listing cannot become evidence for the bookmarked exchange.
        if row.readInput == nil {
            return try store.update(id: row.id, operationID: row.operationID, touch: false) { $0.selected = true }
        }
        // A look is not news: the time moves only when the reply or state does.
        return try store.update(id: row.id, operationID: row.operationID, touch: false) {
            absorb(receipt, into: &$0)
            $0.selected = true
        }
    }

    private static func record(_ receipt: JSONValue, for row: AgentConversationRecord,
                               store: AgentConversationStore, peer: AgentPeerContact?) throws -> AgentConversationRecord {
        try store.update(id: row.id, operationID: row.operationID) {
            // Don't keep a previous request locator for a new uncertain send.
            $0.readInput = nil
            absorb(receipt, into: &$0)
            $0.automaticRead = $0.phase == "waiting" && $0.readInput != nil
                && (peer?.transport == .a2a || peer?.transport == .nativeAgent)
            $0.nextReadAt = $0.automaticRead ? Date() : nil
            if !isRefusal(receipt) { $0.selected = true }
        }
    }

    /// Shared by recovery: consume only identities/evidence supplied by owners.
    static func absorb(_ receipt: JSONValue, into row: inout AgentConversationRecord) {
        row.receipt = AgentConversationStore.cacheReceipt(receipt)
        guard case .object(let root) = receipt else { row.phase = "attention"; return }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        if let conversation = string(value["conversation_id"]) ?? string(value["conversationId"]) { row.conversationID = conversation }
        else if row.agent == "codex", let thread = string(value["thread_id"]) { row.conversationID = "codex:" + thread }
        if case .object(let action)? = root["read_with"], case .object(var read)? = action["input"] {
            read["details"] = .bool(true); row.readInput = read
        } else if let locator = AgentConversationRouting.readLocator(agent: row.agent,
            message: value["message_id"] ?? value["messageId"] ?? value["matched_message_id"],
            conversation: row.conversationID.map(JSONValue.string), task: value["task_id"]),
                  case .object(let action) = locator, case .object(var read)? = action["input"] {
            read["details"] = .bool(true); row.readInput = read
        }
        let state = string(value["run_status"]) ?? string(value["status"]) ?? string(value["state"]) ?? "unknown"
        if isRefusal(receipt) || ["failed", "interrupted", "waiting_approval", "waiting_for_approval", "waiting for approval", "waiting_on_you", "waiting_on_person", "waiting on you", "outcome_unknown", "unavailable", "cancelled", "canceled", "reconnect_required", "session_unavailable"].contains(state) {
            row.phase = "attention"
        } else if value["needs_input"] == .bool(true) || value["completed"] == .bool(true)
                    || value["terminal"] == .bool(true) || ["replied", "completed", "succeeded", "done", "answered", "sent"].contains(state) {
            row.phase = "ready"
        } else if ["enqueued", "queued", "running", "working", "submitted", "accepted", "delivering", "pending", "delivered_live"].contains(state) {
            // delivered_live: in the agent's live session; its answer is a chat of its own (`settled`).
            row.phase = "waiting"
        } else if reply(value) != nil {
            row.phase = "ready"
        } else { row.phase = "attention" }
        if row.phase != "waiting" { row.nextReadAt = nil; row.automaticRead = false }
    }

    static func view(_ row: AgentConversationRecord, details: Bool, dataRoot: URL,
                     historyBefore: String? = nil, historyExchange: String? = nil) -> JSONValue {
        let receipt = row.receipt ?? .object(["status": .string("unknown")])
        guard case .object(let root) = receipt else { return receipt }
        let peer = row.agent.hasPrefix("peer:") ? (try? AgentPeerStore(dataRoot: dataRoot).list())?.first { "peer:" + $0.id == row.agent } : nil
        // Cached reads retain peer provenance instead of laundering it through
        // this presentation layer. Elevation still comes from the current owner.
        if row.agent.hasPrefix("peer:"), root["untrusted_remote_data"] == .bool(true) || !(row.exchanges ?? []).isEmpty,
           peer?.elevationAllowed != true {
            PeerDataTaint.markConsumed(peer: row.agent)
        }
        if details { return receipt }
        return AgentConversationHistoryView.adding(to: conversationPresentation(row, transport: peer?.transport, dataRoot: dataRoot), row: row,
            before: historyBefore, exchange: historyExchange)
    }

    /// Compare routing-owner evidence locally without presenting cached text or
    /// treating the conversation list as consumption of a peer's reply.
    static func workspaceChangeObservation(_ row: AgentConversationRecord,
                                          location: AgentWorkspaceLocation,
                                          previous: AgentWorkspaceChanges.Stamp?) -> AgentWorkspaceChanges.Observation? {
        AgentWorkspaceChanges.evaluate(location: location, result: conversationPresentation(row), previous: previous)
    }

    /// An attention row the next explicit message may continue (the send path's rule).
    /// A built-in lane's job that ran to its end (omp's 403, a live hand-off)
    /// settled; every message there is a job of its own, never a replay.
    static func resumable(_ row: AgentConversationRecord, _ transport: AgentPeerTransport?, dataRoot: URL? = nil) -> Bool {
        if let job = builtInJob(row), job["stall_basis"] == .string("terminal") {
            return !liveHandOff(row) || settled(row, dataRoot: dataRoot)
        }
        return transport == .grokBot || transport == .desktop
            || row.conversationID != nil && (transport == .acp || transport == .desktopChat)
    }

    private static func builtInJob(_ row: AgentConversationRecord) -> [String: JSONValue]? {
        guard ["codex", "claude", "omp"].contains(row.agent), case .object(let root)? = row.receipt,
              case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] else { return nil }
        return job
    }

    /// Handed straight into the agent's live session (Claude): no reply comes
    /// back on the job; the agent answers in a bridge chat of its own.
    static func liveHandOff(_ row: AgentConversationRecord) -> Bool {
        guard let job = builtInJob(row) else { return false }
        return (job["run_status"] ?? job["status"]) == .string("delivered_live")
    }

    /// A live hand-off is settled once the agent has written in a chat since,
    /// or 30 minutes have passed (Sol, 09-25: a resend before then duplicates work).
    static func settled(_ row: AgentConversationRecord, dataRoot: URL?) -> Bool {
        let handed = row.operationStartedAt ?? row.updatedAt
        if Date().timeIntervalSince(handed) >= 30 * 60 { return true }
        guard let dataRoot else { return false }
        return HerScreen.bridgeChats(dataRoot: dataRoot).contains { $0.who == row.agent && ($0.heard ?? .distantPast) > handed }
    }

    private static func conversationPresentation(_ row: AgentConversationRecord, transport: AgentPeerTransport? = nil, dataRoot: URL? = nil) -> JSONValue {
        let receipt = row.receipt ?? .object(["status": .string("unknown")])
        guard case .object(let root) = receipt else { return receipt }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        let handOff = liveHandOff(row), handOffSettled = handOff && settled(row, dataRoot: dataRoot)
        var result: [String: JSONValue] = ["agent": .string(row.agent), "with": .string(row.name),
            "conversation": .string(row.label), "state": .string(row.phase),
            "can_reply": .bool((!["sending", "waiting"].contains(row.phase) || (row.phase == "waiting" && handOffSettled))
                && (row.phase != "attention" || resumable(row, transport, dataRoot: dataRoot) || settledBotTurn(row) || confirmedNotSent(row))),
            "status": value["run_status"] ?? value["status"] ?? .string(row.phase),
            "reply_with": .object(["tool": .string("agent_message"), "input": .object([
                "agent": .string(row.name), "conversation": .string(row.label), "text": .string("<your next message>")])]),
            "inspect_receipt": .object(["tool": .string("agent_read"), "input": .object([
                "agent": .string(row.name), "conversation": .string(row.label), "details": .bool(true)])])]
        if ["codex", "claude", "omp"].contains(row.agent), root["jobs"] != nil {
            let original = AgentConversationView.codingReply(value)
            if let text = original.text {
                result["reply"] = .string(text)
                result["reply_truncated"] = .bool(original.truncated)
                result["reply_state"] = .string("reply_received")
            } else {
                result["reply_state"] = .string("no_reply_observed")
                if (value["run_status"] ?? value["status"]) == .string("delivered_live") {
                    result["detail"] = .string("Delivered into \(row.name)'s live session; the answer comes as a chat of its own.")
                } else if row.phase == "ready" {
                    result["detail"] = .string("This saved record has delivery status but no original answer text. No message was resent.")
                }
            }
        } else if let text = reply(value) { result["reply"] = .string(text) }
        for key in ["untrusted_remote_data", "source_availability", "completed", "terminal", "needs_input", "needs_authentication", "sent", "reason", "error", "execution_error", "reply_truncated", "artifacts", "parts", "has_more"] {
            if let field = value[key] ?? root[key] { result[key] = field }
        }
        // delegation_status.detail is a format selector ("full"), not an
        // explanation of the selected exchange.
        if root["jobs"] == nil, let detail = value["detail"] { result["detail"] = detail }
        if row.phase == "waiting", handOff {
            result["detail"] = .string("Delivered into \(row.name)'s live session; the answer comes as a chat of its own."
                + (handOffSettled ? " A new message can go now." : " A new message can go once \(row.name) answers or 30 minutes pass."))
        } else if row.phase == "waiting" {
            let automatic = row.automaticRead || ["codex", "claude", "omp"].contains(row.agent)
            result["detail"] = .string(automatic
                ? "Waiting for \(row.name). NativeAgent will bring the answer back; no repeated checks or resend needed."
                : "Waiting for \(row.name)'s configured return connection. Do not resend this message.")
        } else if row.phase == "sending" {
            result["detail"] = .string("The previous send has not settled. It may have been interrupted; no message has been resent.")
        }
        if row.phase == "attention", let detail = row.deliveryState { result["detail"] = .string(detail) }
        if row.phase == "sending" {
            // The owner keeps the previous receipt for task-resumption routing
            // until dispatch settles. Never show its answer as this new turn.
            for key in ["reply", "completed", "terminal", "sent", "reply_truncated", "artifacts", "parts"] { result.removeValue(forKey: key) }
            result["status"] = .string("sending")
            result["reply_state"] = .string("no_reply_observed")
        }
        result["evidence"] = .string("Latest retained conversation result; an agent's answer is not independent verification of its work.")
        return .object(result)
    }

    private static func reply(_ row: [String: JSONValue]) -> String? {
        string(row["reply"]) ?? string(row["answer"]) ?? AgentConversationView.codingReply(row).text ?? string(row["findings"])
    }
    private static func settledBotTurn(_ row: AgentConversationRecord) -> Bool {
        guard row.agent.hasPrefix("bot:"), case .object(let receipt)? = row.receipt,
              string(receipt["entry_id"]) != nil || string(receipt["message_id"]) != nil else { return false }
        // A saved terminal bot turn permits a new explicit follow-up, including
        // after a partial answer. It is never an automatic retry of that turn.
        return ["failed", "interrupted", "waiting_approval", "waiting_on_you", "waiting_for_approval", "waiting_on_person", "waiting for approval", "waiting on you"].contains(
            string(receipt["run_status"]) ?? string(receipt["status"]) ?? "")
    }
    private static func confirmedNotSent(_ row: AgentConversationRecord) -> Bool {
        guard case .object(let receipt)? = row.receipt,
              receipt["sent"] == .bool(false) else { return false }
        // Only a new explicit message may try again after a pre-dispatch refusal.
        // Pending approvals and uncertain/accepted sends still require recovery;
        // the adapter rechecks current authority and connection on every attempt.
        return ["reconnect_required", "unavailable", "needs_setup", "no_outbound_route",
                "blocked", "denied", "blocked_by_trust", "busy"].contains(string(receipt["status"]) ?? "")
    }
    private static func isRefusal(_ receipt: JSONValue) -> Bool {
        guard case .object(let row) = receipt else { return true }
        return row["error"] != nil || row["sent"] == .bool(false)
            || ["blocked", "denied", "blocked_by_trust", "approval_required", "approval_filed", "needs_setup", "no_outbound_route"].contains(string(row["status"]) ?? "")
    }
    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }; return value
    }
    private static func agentIsBot(_ input: [String: JSONValue]) -> Bool {
        string(input["agent"])?.hasPrefix("bot:") == true
    }
    private static func attention(_ name: String, label: String, _ text: String) -> JSONValue {
        .object(["with": .string(name), "conversation": .string(label), "state": .string("attention"), "detail": .string(text), "sent": .bool(false)])
    }
}
